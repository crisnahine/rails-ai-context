# frozen_string_literal: true

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
    RUBY_LINE = /\A\s+ruby (\S+)/
    GEMFILE_RUBY_LINE = /^\s*ruby\s+(["'])([^"']+)\1/
    PLAIN_VERSION = /\A\d+(?:\.\d+)*\S*\z/

    class Spec
      attr_reader :ruby_version, :reason

      def initialize(versions, ruby_version: nil, reason: nil)
        @versions = versions
        @ruby_version = ruby_version
        @reason = reason
      end

      # No lockfile, and a lockfile that named no gem, are both "the app's
      # gems are unknown". Neither is an app that resolved no gems, and a
      # caller reading them that way answers that the app uses none of them.
      def missing?
        !@reason.nil?
      end

      def present?(name)
        @versions.key?(name.to_s)
      end

      def version(name)
        @versions[name.to_s]
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

    def for(root)
      path = File.join(root.to_s, "Gemfile.lock")
      gemfile = File.join(root.to_s, "Gemfile")
      stamp = [ mtime(path), mtime(gemfile) ]

      MUTEX.synchronize do
        cached = CACHE[path]
        return cached[:spec] if cached && cached[:stamp] == stamp

        spec = stamp.first ? parse(path, gemfile) : Spec.new({}, reason: "No Gemfile.lock found")
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

    def parse(path, gemfile)
      content = SafeFile.read(path, max_size: MAX_SIZE)
      return Spec.new({}, reason: "Gemfile.lock could not be read") unless content

      versions = {}
      ruby_version = nil
      in_specs = false
      specs_section = false
      content.each_line do |line|
        if line.match?(/\A\S/)
          in_specs = false
        elsif line.strip == "specs:"
          in_specs = true
          specs_section = true
        elsif in_specs && (match = line.match(SPEC_LINE))
          # A platform-specific gem is "name (1.2.3-x86_64-linux)", one line
          # per platform. The text before the first hyphen is the version; a
          # prerelease tag ("1.70.0-beta1") is dropped along with the platform.
          versions[match[1]] ||= match[2].split("-", 2).first
        elsif (match = line.match(RUBY_LINE)) && match[1].match?(PLAIN_VERSION)
          ruby_version = match[1]
        end
      end
      # An empty Gemfile still locks to a file with a specs: section, so no
      # gems is an answer there. A file without one is not a lockfile at all,
      # and answering it as an app with no gems denies every gem it holds.
      return Spec.new({}, reason: "Gemfile.lock has no specs section") unless specs_section

      Spec.new(versions, ruby_version: ruby_version || gemfile_ruby_version(gemfile))
    end
    private_class_method :parse

    # A lockfile without a RUBY VERSION section leaves the Gemfile as the only
    # statement of the version. A requirement such as `ruby ">= 3.3.0"` names a
    # range, not a version, so it is left unanswered rather than reported as one.
    def gemfile_ruby_version(path)
      content = SafeFile.read(path, max_size: MAX_SIZE)
      return nil unless content

      declared = content[GEMFILE_RUBY_LINE, 2]
      declared if declared&.match?(PLAIN_VERSION)
    end
    private_class_method :gemfile_ruby_version
  end
end
