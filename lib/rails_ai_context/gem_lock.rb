# frozen_string_literal: true

require "set"
require "pathname"
require_relative "safe_file"
require_relative "safe_path"
require_relative "polyfill/data"

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
    PLAIN_VERSION = /\A\d+(?:\.\d+)*\S*\z/
    TOOL_VERSIONS_RUBY = /^ruby[ \t]+(\S+)/
    # Version managers write another engine as "<engine>-<version>", as ruby-build names it.
    ENGINE_PREFIXED = /\A([a-z][a-z+]*)-(\d\S*)\z/
    ENGINE_NAMES = {
      "jruby" => "JRuby", "truffleruby" => "TruffleRuby", "truffleruby+graalvm" => "TruffleRuby+GraalVM",
      "mruby" => "mruby", "rbx" => "Rubinius"
    }.freeze
    # mise's project files, highest precedence first (mise docs, configuration).
    MISE_FILES = [ "mise.local.toml", "mise.toml", ".mise.toml", "mise/config.toml", ".mise/config.toml", ".config/mise.toml",
                   ".config/mise/config.toml" ].freeze
    VERSION_FILES = [ ".ruby-version", ".tool-versions", *MISE_FILES ].freeze
    # The line `rails new` and `rails plugin new` write into config/boot.rb.
    BOOT_GEMFILE = /^\s*ENV\[["']BUNDLE_GEMFILE["']\]\s*(?:\|\|)?=\s*File\.expand_path\(\s*["']([^"']+)["']\s*,\s*(__dir__|__FILE__)\s*\)/
    MISE_TOOLS = /^[ \t]*\[tools\][ \t]*$(.*?)(?=^[ \t]*\[|\z)/m
    # ruby = "3.3.6", ruby = ["3.3.6", ...] or ruby = { version = "3.3.6" }
    MISE_RUBY = /^[ \t]*["']?ruby["']?[ \t]*=[ \t]*(?:\[[ \t]*|\{[^}\n]*?version[ \t]*=[ \t]*)?["']([^"'\n]+)["']/

    class Spec
      # `ruby_engine` is a non-CRuby engine with its own version ("JRuby 9.4.8.0"); `outside_gemfile` is never read.
      attr_reader :ruby_versions, :ruby_engine, :reason, :path_remotes, :outside_gemfile
      # With no lockfile, the gems the Gemfile names; nil when it names only some of them.
      attr_reader :gemfile_gems

      def initialize(versions, ruby_versions: {}, ruby_engine: nil, reason: nil, absent: false, direct: nil, path_remotes: [],
                     outside_gemfile: nil, gemfile_gems: nil)
        @versions = versions
        @gemfile_gems = gemfile_gems
        @outside_gemfile = outside_gemfile
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

    # `dir` holds the Gemfile and lockfile; `trusted` is the tree a path gem of theirs must stay
    # inside; `outside` names a bundle config/boot.rb points at that is never read.
    Bundle = Data.define(:lockfile, :gemfile, :lock_label, :gemfile_label, :dir, :trusted, :outside)

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
      bundle = bundle(root)
      stamp = [ bundle.lockfile, bundle.gemfile, File.join(root, "config/boot.rb"),
                *VERSION_FILES.map { |name| File.join(root, name) } ].map { |file| file && mtime(file) }

      MUTEX.synchronize do
        cached = CACHE[root]
        return cached[:spec] if cached && cached[:stamp] == stamp

        # Which gems resolved and which Ruby the app declares are two facts,
        # and the Gemfile answers the second whether or not a lockfile answers
        # the first.
        spec = if stamp.first
          parse(bundle, root)
        else
          absent_spec(root, bundle)
        end
        CACHE[root] = { stamp: stamp, spec: spec }
        spec
      end
    end

    # The app's own Gemfile and lockfile, or, with no lockfile of its own, the
    # bundle config/boot.rb points Bundler at (an engine's test/dummy).
    def bundle(root)
      root = root.to_s
      own = Bundle.new(lockfile: File.join(root, lockfile_name(root)), gemfile: File.join(root, gemfile_name(root)),
                       lock_label: lockfile_name(root), gemfile_label: gemfile_name(root), dir: root, trusted: root, outside: nil)
      return own if File.file?(own.lockfile)

      boot_bundle(root, own) || own
    end

    # Read only inside the app's git repository: that bundle is the app's
    # declared one, the same trust as its own Gemfile.lock. Anything else is
    # named as outside and left unread.
    def boot_bundle(root, own)
      target = boot_gemfile(root)
      return nil unless target

      real_root = File.realpath(root)
      dir = File.dirname(target)
      label = ->(file) { Pathname.new(File.join(dir, file)).relative_path_from(Pathname.new(real_root)).to_s }
      gemfile = File.basename(target)
      lockfile = gemfile == "gems.rb" ? "gems.locked" : "#{gemfile}.lock"
      repo = SafePath.git_root(real_root)
      unless repo && File.directory?(dir) && SafePath.contained?(File.realpath(dir), repo)
        return own.with(lockfile: nil, outside: label.(gemfile))
      end

      Bundle.new(lockfile: inside_file(dir, lockfile), gemfile: inside_file(dir, gemfile), lock_label: label.(lockfile),
                 gemfile_label: label.(gemfile), dir: File.realpath(dir), trusted: repo, outside: nil)
    rescue SystemCallError
      nil
    end
    private_class_method :boot_bundle

    # The BUNDLE_GEMFILE config/boot.rb sets, when it is outside the app root.
    def boot_gemfile(root)
      match = read_inside(root, "config/boot.rb")&.match(BOOT_GEMFILE)
      return nil unless match

      real_root = File.realpath(root)
      # Relative to __FILE__ the path starts from boot.rb itself, one level below __dir__.
      base = match[2] == "__FILE__" ? File.join(real_root, "config", "boot.rb") : File.join(real_root, "config")
      target = File.expand_path(match[1], base)
      target unless target.start_with?(SafePath.dir_prefix(real_root))
    end
    private_class_method :boot_gemfile

    # The file's real path when it exists and does not link out of its directory.
    def inside_file(dir, name)
      real = File.realpath(File.join(dir, name))
      real if SafePath.contained?(real, File.realpath(dir))
    rescue SystemCallError
      nil
    end
    private_class_method :inside_file

    def absent_spec(root, bundle)
      outside = bundle.outside
      reason = if outside
        "No #{lockfile_name(root)} in the app; config/boot.rb points Bundler at #{outside}, outside the app's git repository, which is not read"
      else
        "No #{bundle.lock_label} found"
      end
      facts = bundle.gemfile ? gemfile(bundle.gemfile) : { gems: nil }
      Spec.new({}, **declared_ruby(nil, root, bundle, facts), reason: reason, absent: true, outside_gemfile: outside,
               gemfile_gems: facts[:gems])
    end
    private_class_method :absent_spec

    def mtime(path)
      File.mtime(path)
    rescue SystemCallError
      nil
    end
    private_class_method :mtime

    def parse(bundle, root)
      path = bundle.lockfile
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

      facts = bundle.gemfile ? gemfile(bundle.gemfile) : {}
      Spec.new(versions, **declared_ruby(ruby_version, root, bundle, facts), direct: direct, path_remotes: path_remotes)
    end
    private_class_method :parse

    # `gems` is nil when `gemspec` or `eval_gemfile` adds gems the file does not name.
    def gemfile(path)
      result = gemfile_parse(path) or return { ruby: nil, gems: nil }

      facts = { ruby: nil, gems: [] }
      pending = [ result.value ]
      while (node = pending.shift)
        pending.concat(node.compact_child_nodes)
        next unless node.is_a?(Prism::CallNode) && node.receiver.nil?

        case node.name
        when :ruby then facts[:ruby] ||= gemfile_ruby(node)
        when :gem then (name = literal(node.arguments&.arguments&.first)) && facts[:gems]&.push(name)
        when :gemspec, :eval_gemfile then facts[:gems] = nil
        end
      end
      facts
    end

    # AstCache once the gem is loaded, so GemfileGems' walk shares the parse; before the boot, Prism alone.
    def gemfile_parse(path)
      return AstCache.parse(File.realpath(path)) if defined?(AstCache)

      require "prism"
      content = SafeFile.read(path, max_size: MAX_SIZE)
      content && Prism.parse(content)
    rescue SystemCallError, ArgumentError, LoadError
      nil
    end
    private_class_method :gemfile_parse

    # A requirement such as `ruby ">= 3.3.0"` names a range, not a version, so it is left unanswered.
    def gemfile_ruby(node)
      args = node.arguments&.arguments || []
      version = literal(args.first)
      return nil unless version&.match?(PLAIN_VERSION)

      options = args.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode).to_h { |pair| [ literal(pair.key), literal(pair.value) ] }
      [ version, engine_name(options["engine"], options["engine_version"]) ]
    end
    private_class_method :gemfile_ruby

    def literal(node)
      node.unescaped if node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)
    end
    private_class_method :literal

    # Sources in Bundler's order; an engine's Ruby version comes only from its own source (JRuby 9.4 runs Ruby 3.1).
    def declared_ruby(locked, root, bundle, facts)
      declared = {
        bundle.lock_label => locked,
        bundle.gemfile_label => facts[:ruby],
        ".ruby-version" => version_string(SafeFile.read(File.join(root, ".ruby-version"), max_size: MAX_SIZE)&.strip),
        ".tool-versions" => version_string(SafeFile.read(File.join(root, ".tool-versions"), max_size: MAX_SIZE)&.[](TOOL_VERSIONS_RUBY, 1)),
        **mise_ruby(root)
      }.compact
      engine = declared.values.first&.last
      declared = declared.first(1).to_h if engine
      { ruby_versions: declared.transform_values(&:first).compact, ruby_engine: engine }
    end
    private_class_method :declared_ruby

    # SafePath's containment without its sensitive-pattern check, which needs
    # the configuration: the CLI reads GemLock before loading it.
    def read_inside(root, relative)
      real = File.realpath(File.join(root, relative))
      SafeFile.read(real, max_size: MAX_SIZE) if SafePath.contained?(real, File.realpath(root))
    rescue SystemCallError
      nil
    end
    private_class_method :read_inside

    # The ruby tool of the mise file that wins, keyed by that file's name.
    def mise_ruby(root)
      MISE_FILES.each do |name|
        content = read_inside(root, name)
        tools = content&.[](MISE_TOOLS, 1)
        declared = version_string(tools&.[](MISE_RUBY, 1))
        return { name => declared } if declared
      end
      {}
    end
    private_class_method :mise_ruby

    # "3.4.9" and "ruby-3.4.9" are CRuby; "jruby-9.4.8.0" names an engine
    # version, not the Ruby version that engine implements, and a bare "jruby" its latest.
    def version_string(declared)
      return nil if declared.nil?

      if (match = declared.match(ENGINE_PREFIXED)) && match[1] != "ruby"
        [ nil, engine_name(match[1], match[2]) ]
      elsif ENGINE_NAMES.key?(declared)
        [ nil, engine_name(declared, nil) ]
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
