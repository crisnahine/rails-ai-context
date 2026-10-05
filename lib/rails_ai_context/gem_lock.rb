# frozen_string_literal: true

require "set"
require_relative "safe_file"

module RailsAiContext
  # Which gems an app resolved, read once per lockfile, and the one answer
  # every caller gets: a gem is present by exact name, so `bugsnag` is not
  # `bugsnag-capistrano`, and a git or path gem counts like any other.
  # Bundler's own parser needs a Gemfile it can locate and raises without one,
  # which the standalone binary never has, so the spec-line grammar is read
  # here: a section header, a specs: line, then one four-space line per gem
  # with its version in parentheses.
  module GemLock
    MAX_SIZE = 5 * 1024 * 1024
    SPEC_LINE = /\A {4}(\S+) \(([^)]+)\)\s*\z/
    DEPENDENCY_LINE = /\A {2}(\S+?)!?(?: \(.*\))?\s*\z/
    # Bundler writes a non-CRuby engine after the version: "ruby 3.1.4p0 (jruby 9.4.8.0)".
    RUBY_LINE = /\A\s+ruby (\S+)(?: \((\S+) ([^)]+)\))?/
    REMOTE_LINE = /\A {2}remote: (.+?)\s*\z/
    GEMFILE_RUBY_LINE = /^\s*ruby\s+(["'])([^"']+)\1(.*)$/
    GEMFILE_ENGINE = /(?:\bengine:|:engine\s*=>)\s*["':]?([\w+]+)/
    GEMFILE_ENGINE_VERSION = /(?:\bengine_version:|:engine_version\s*=>)\s*["']([^"']+)/
    PLAIN_VERSION = /\A\d+(?:\.\d+)*\S*\z/
    TOOL_VERSIONS_RUBY = /^ruby[ \t]+(\S+)/
    # Version managers write another engine as "<engine>-<version>", as ruby-build names it.
    ENGINE_PREFIXED = /\A([a-z][a-z+]*)-(\d\S*)\z/
    ENGINE_NAMES = {
      "jruby" => "JRuby", "truffleruby" => "TruffleRuby", "truffleruby+graalvm" => "TruffleRuby+GraalVM",
      "mruby" => "mruby", "rbx" => "Rubinius"
    }.freeze
    # Bundler's order: what the lockfile resolved, what the Gemfile asked for, then the
    # version-manager files the shell picks when neither says.
    VERSION_FILES = [ ".ruby-version", ".tool-versions" ].freeze

    class Spec
      # `remote:` of each PATH section, as the lockfile writes it.
      # `ruby_engine` names a non-CRuby engine and its own version ("JRuby 9.4.8.0"), else nil.
      attr_reader :ruby_versions, :ruby_engine, :reason, :path_remotes

      def initialize(versions, ruby_versions: {}, ruby_engine: nil, reason: nil, absent: false, direct: nil, path_remotes: [])
        @versions = versions
        @path_remotes = path_remotes
        @ruby_versions = ruby_versions
        @ruby_engine = ruby_engine
        @reason = reason
        @absent = absent
        @direct = direct || Set.new
      end

      # Several files may name a version and they often disagree, so the source is kept too.
      def ruby_version
        @ruby_versions.values.first
      end

      def ruby_version_source
        @ruby_versions.keys.first
      end

      # No lockfile, and a lockfile that named no gem, are both "the app's
      # gems are unknown". Neither is an app that resolved no gems, and a
      # caller reading them that way answers that the app uses none of them.
      def missing?
        !@reason.nil?
      end

      # An app with no lockfile at all, as opposed to one whose lockfile
      # could not be read: the first is an absent source, the second a
      # failure, and a caller reporting them has to say which.
      def absent?
        @absent
      end

      def present?(name)
        @versions.key?(name.to_s)
      end

      def version(name)
        @versions[name.to_s]
      end

      # Named in the Gemfile, as opposed to resolved as some other gem's
      # dependency. Every Rails app resolves minitest through activesupport,
      # and reporting that as the app's test framework sent agents to a
      # `test/` directory that does not exist.
      def direct?(name)
        @direct.include?(name.to_s)
      end

      def any?(*names)
        names.flatten.any? { |name| present?(name) }
      end

      def names
        @versions.keys.sort
      end
    end

    MUTEX = Mutex.new
    CACHE = {}
    private_constant :MUTEX, :CACHE

    module_function

    # Bundler looks for gems.rb before Gemfile.
    def gemfile_name(root)
      File.file?(File.join(root.to_s, "gems.rb")) ? "gems.rb" : "Gemfile"
    end

    # gems.rb locks to gems.locked, Gemfile to Gemfile.lock.
    def lockfile_name(root)
      gemfile_name(root) == "gems.rb" ? "gems.locked" : "Gemfile.lock"
    end

    def for(root)
      root = root.to_s
      path = File.join(root, lockfile_name(root))
      gemfile = File.join(root, gemfile_name(root))
      stamp = [ path, gemfile, *VERSION_FILES.map { |name| File.join(root, name) } ].map { |file| mtime(file) }

      MUTEX.synchronize do
        cached = CACHE[path]
        return cached[:spec] if cached && cached[:stamp] == stamp

        # Which gems resolved and which Ruby the app declares are two facts,
        # and the Gemfile answers the second whether or not a lockfile answers
        # the first.
        spec = if stamp.first
          parse(path, gemfile, root)
        else
          Spec.new({}, **declared_ruby(nil, root), reason: "No #{File.basename(path)} found", absent: true)
        end
        CACHE[path] = { stamp: stamp, spec: spec }
        spec
      end
    end

    def mtime(path)
      File.mtime(path)
    rescue SystemCallError
      nil
    end
    private_class_method :mtime

    def parse(path, gemfile, root)
      content = SafeFile.read(path, max_size: MAX_SIZE)
      return Spec.new({}, reason: "#{File.basename(path)} could not be read") unless content

      versions = {}
      direct = Set.new
      ruby_version = nil
      in_specs = false
      in_dependencies = false
      in_path = false
      path_remotes = []
      specs_section = false
      content.each_line do |line|
        if line.match?(/\A\S/)
          in_specs = false
          in_dependencies = line.start_with?("DEPENDENCIES")
          in_path = line.strip == "PATH"
        elsif in_path && (match = line.match(REMOTE_LINE))
          path_remotes << match[1].strip
        elsif in_dependencies && (match = line.match(DEPENDENCY_LINE))
          direct << match[1]
        elsif line.strip == "specs:"
          in_specs = true
          specs_section = true
        elsif in_specs && (match = line.match(SPEC_LINE))
          # A platform-specific gem is "name (1.2.3-x86_64-linux)", one line
          # per platform. The text before the first hyphen is the version; a
          # prerelease tag ("1.70.0-beta1") is dropped along with the platform.
          versions[match[1]] ||= match[2].split("-", 2).first
        elsif (match = line.match(RUBY_LINE)) && match[1].match?(PLAIN_VERSION)
          ruby_version = [ match[1], engine_name(match[2], match[3]) ]
        end
      end
      # An empty Gemfile still locks to a file with a specs: section, so no
      # gems is an answer there. A file without one is not a lockfile at all,
      # and answering it as an app with no gems denies every gem it holds.
      return Spec.new({}, reason: "#{File.basename(path)} has no specs section") unless specs_section

      Spec.new(versions, **declared_ruby(ruby_version, root), direct: direct, path_remotes: path_remotes)
    end
    private_class_method :parse

    # A lockfile without a RUBY VERSION section leaves the Gemfile as the only
    # statement of the version. A requirement such as `ruby ">= 3.3.0"` names a
    # range, not a version, so it is left unanswered rather than reported as one.
    def gemfile_ruby(path)
      match = SafeFile.read(path, max_size: MAX_SIZE)&.match(GEMFILE_RUBY_LINE)
      return nil unless match && match[2].match?(PLAIN_VERSION)

      [ match[2], engine_name(match[3][GEMFILE_ENGINE, 1], match[3][GEMFILE_ENGINE_VERSION, 1]) ]
    end
    private_class_method :gemfile_ruby

    # Each source answers [version, engine]. The engine comes from the first
    # source that declares anything, the file that also decides the version.
    def declared_ruby(locked, root)
      declared = {
        lockfile_name(root) => locked,
        gemfile_name(root) => gemfile_ruby(File.join(root, gemfile_name(root))),
        ".ruby-version" => version_string(SafeFile.read(File.join(root, ".ruby-version"), max_size: MAX_SIZE)&.strip),
        ".tool-versions" => version_string(SafeFile.read(File.join(root, ".tool-versions"), max_size: MAX_SIZE)&.[](TOOL_VERSIONS_RUBY, 1))
      }.compact
      { ruby_versions: declared.transform_values(&:first).compact, ruby_engine: declared.values.first&.last }
    end
    private_class_method :declared_ruby

    # "3.4.9" and "ruby-3.4.9" are CRuby; "jruby-9.4.8.0" names an engine
    # version, not the Ruby version that engine implements.
    def version_string(declared)
      return nil if declared.nil?

      if (match = declared.match(ENGINE_PREFIXED)) && match[1] != "ruby"
        [ nil, engine_name(match[1], match[2]) ]
      else
        version = declared.sub(/\Aruby-/, "")
        [ version, nil ] if version.match?(PLAIN_VERSION)
      end
    end
    private_class_method :version_string

    def engine_name(engine, version)
      return nil if engine.nil? || engine == "ruby"

      [ ENGINE_NAMES.fetch(engine, engine), version ].compact.join(" ")
    end
    private_class_method :engine_name
  end
end
