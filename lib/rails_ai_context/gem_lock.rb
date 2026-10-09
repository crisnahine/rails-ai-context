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
    MISE_TOOLS = /^[ \t]*\[tools\][ \t]*$(.*?)(?=^[ \t]*\[|\z)/m
    # ruby = "3.3.6", ruby = ["3.3.6", ...] or ruby = { version = "3.3.6" }
    MISE_RUBY = /^[ \t]*["']?ruby["']?[ \t]*=[ \t]*(?:\[[ \t]*|\{[^}\n]*?version[ \t]*=[ \t]*)?["']([^"'\n]+)["']/

    class Spec
      # `ruby_engine` is a non-CRuby engine with its own version ("JRuby 9.4.8.0"); `outside_gemfile` is never read.
      attr_reader :ruby_versions, :ruby_engine, :reason, :path_remotes, :outside_gemfile
      # With no lockfile, the gems the Gemfile names; nil when it names only some of them.
      attr_reader :gemfile_gems

      def initialize(versions, ruby_versions: {}, ruby_engine: nil, reason: nil, absent: false, direct: nil, path_remotes: [],
                     outside_gemfile: nil, no_repo: false, gemfile_gems: nil)
        @versions = versions
        @gemfile_gems = gemfile_gems
        @outside_gemfile = outside_gemfile
        @no_repo = no_repo
        @path_remotes = path_remotes
        @ruby_versions = ruby_versions
        @ruby_engine = ruby_engine
        @reason = reason
        @absent = absent
        @direct = direct || Set.new
      end

      # Why the bundle config/boot.rb names went unread, worded the same by every tool.
      def unread_bundle
        GemLock.unread_bundle(@outside_gemfile, @no_repo) if @outside_gemfile
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
    # inside; `outside` names a bundle config/boot.rb points at that is never read, `no_repo` says no git repository holds the app.
    Bundle = Data.define(:lockfile, :gemfile, :lock_label, :gemfile_label, :dir, :trusted, :outside, :no_repo)

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
                *VERSION_FILES.map { |name| File.join(root, name) } ].map { |file| file && mtime(file) } << loaded?
      stamp << Introspectors::GemfileGems.stamps(bundle) if loaded?

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
                       lock_label: lockfile_name(root), gemfile_label: gemfile_name(root), dir: root, trusted: root, outside: nil, no_repo: false)
      return own if File.file?(own.lockfile)

      boot_bundle(root, own) || own
    end

    # Read only inside the app's git repository, the trust its own Gemfile.lock has; anything else is named and left unread.
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
        return own.with(lockfile: nil, outside: label.(gemfile), no_repo: repo.nil?)
      end

      Bundle.new(lockfile: inside_file(dir, lockfile), gemfile: inside_file(dir, gemfile), lock_label: label.(lockfile),
                 gemfile_label: label.(gemfile), dir: File.realpath(dir), trusted: repo, outside: nil, no_repo: false)
    rescue SystemCallError
      nil
    end
    private_class_method :boot_bundle

    # The BUNDLE_GEMFILE config/boot.rb sets, when it is outside the app root:
    # the Gemfile the app boots against when nothing else names one, which a
    # caller may name whether or not it is in a repository this reads.
    def boot_gemfile(root)
      real_root = File.realpath(root)
      real = File.realpath(File.join(real_root, "config/boot.rb"))
      return nil unless SafePath.contained?(real, real_root)

      result = ruby_parse(real) or return nil
      relative, anchor = Introspectors::AstWalk.each(result.value).lazy.filter_map { |node| bundle_gemfile_path(node) }.first
      return nil unless relative

      # Relative to __FILE__ the path starts from boot.rb itself, one level below __dir__.
      target = File.expand_path(relative, anchor == :file ? real : File.dirname(real))
      target unless target.start_with?(SafePath.dir_prefix(real_root))
    rescue SystemCallError
      nil
    end

    # `ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)`, the line `rails new`
    # and `rails plugin new` write, with `=` or `__FILE__` as older templates do.
    def bundle_gemfile_path(node)
      value = case node
      when Prism::IndexOrWriteNode then node.value if env_index?(node.receiver, node.arguments&.arguments)
      when Prism::CallNode then node.arguments&.arguments&.last if node.name == :[]= && env_index?(node.receiver, node.arguments&.arguments&.first(1))
      end
      return nil unless value.is_a?(Prism::CallNode) && value.name == :expand_path && value.receiver.is_a?(Prism::ConstantReadNode) &&
                        value.receiver.name == :File

      path, anchor = value.arguments&.arguments
      return nil unless path.is_a?(Prism::StringNode) && value.arguments.arguments.size == 2

      if anchor.is_a?(Prism::SourceFileNode) then [ path.unescaped, :file ]
      elsif anchor.is_a?(Prism::CallNode) && anchor.name == :__dir__ && anchor.receiver.nil? then [ path.unescaped, :dir ]
      end
    end
    private_class_method :bundle_gemfile_path

    def env_index?(receiver, arguments)
      receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :ENV && arguments&.size == 1 && literal(arguments.first) == "BUNDLE_GEMFILE"
    end
    private_class_method :env_index?

    # The file's real path when it exists and does not link out of its directory.
    def inside_file(dir, name)
      real = File.realpath(File.join(dir, name))
      real if SafePath.contained?(real, File.realpath(dir))
    rescue SystemCallError
      nil
    end
    private_class_method :inside_file

    def unread_bundle(outside, no_repo)
      where = no_repo ? "and the app is in no git repository" : "outside the app's git repository"
      "config/boot.rb points Bundler at `#{outside}`, #{where}"
    end

    def absent_spec(root, bundle)
      reason = if bundle.outside
        "No #{lockfile_name(root)} in the app; #{unread_bundle(bundle.outside, bundle.no_repo)}, so that bundle is not read"
      else
        "No #{bundle.lock_label} found"
      end
      facts = gemfile(bundle)
      Spec.new({}, **declared_ruby(nil, root, bundle, facts), reason: reason, absent: true, outside_gemfile: bundle.outside,
               no_repo: bundle.no_repo, gemfile_gems: facts[:gems])
    end
    private_class_method :absent_spec

    def mtime(path)
      File.mtime(path)
    rescue SystemCallError
      nil
    end

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

      facts = gemfile(bundle)
      Spec.new(versions, **declared_ruby(ruby_version, root, bundle, facts), direct: direct, path_remotes: path_remotes)
    end
    private_class_method :parse

    # `gems` is nil when a call adds gems the Gemfile does not name (gemspec, a gem
    # or eval_gemfile whose argument is not a literal, a file left unread).
    def gemfile(bundle)
      entries = gemfile_entries(bundle) or return { ruby: nil, gems: nil }

      ruby = entries.find { |entry| entry[:type] == :ruby }
      gems = entries.filter_map { |entry| entry[:name] if entry[:type] == :gem }.uniq unless entries.any? { |entry| entry[:type] == :unknown_gems }
      { ruby: ruby && gemfile_ruby(ruby), gems: gems }
    end
    private_class_method :gemfile

    # Before the gem loads, a plain walk of the one Gemfile; eval_gemfile is left unread.
    def gemfile_entries(bundle)
      return Introspectors::GemfileGems.read_bundle(bundle) if loaded?

      result = ruby_parse(bundle.gemfile) or return nil
      Introspectors::AstWalk.each(result.value).filter_map do |node|
        next unless node.is_a?(Prism::CallNode) && node.receiver.nil?

        args = node.arguments&.arguments || []
        case node.name
        when :ruby
          options = args.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode).to_h { |pair| [ literal(pair.key), literal(pair.value) ] }
          { type: :ruby, version: literal(args.first), engine: options["engine"], engine_version: options["engine_version"] }
        when :gem then args.first.is_a?(Prism::StringNode) ? { type: :gem, name: args.first.unescaped } : { type: :unknown_gems }
        when :gemspec, :eval_gemfile then { type: :unknown_gems }
        end
      end
    end
    private_class_method :gemfile_entries

    def loaded?
      defined?(Introspectors::GemfileGems) ? true : false
    end
    private_class_method :loaded?

    # AstCache once the gem is loaded; before the boot Prism alone, as AstCache's
    # concurrent-ruby would load ahead of the app's bundle.
    def ruby_parse(path)
      return nil unless path
      return AstCache.parse(File.realpath(path)) if loaded?

      require "prism"
      require_relative "introspectors/ast_walk"
      content = SafeFile.read(path, max_size: MAX_SIZE)
      content && Prism.parse(content)
    rescue SystemCallError, ArgumentError, LoadError
      nil
    end
    private_class_method :ruby_parse

    # A requirement such as `ruby ">= 3.3.0"` names a range, not a version, so it is left unanswered.
    def gemfile_ruby(entry)
      version = entry[:version]
      [ version, engine_name(entry[:engine], entry[:engine_version]) ] if version&.match?(PLAIN_VERSION)
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
        ".ruby-version" => version_string(read_inside(root, ".ruby-version")&.strip),
        ".tool-versions" => version_string(read_inside(root, ".tool-versions")&.[](TOOL_VERSIONS_RUBY, 1)),
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
