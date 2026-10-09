# frozen_string_literal: true

require "find"
require "rbconfig"
require_relative "../boot_manager"

module RailsAiContext
  module CLI
    # How the standalone binary enters the gem: boot the app, serve the static
    # tier, or refuse. Never prints and never exits; the Outcome carries the
    # tier and the lines the binary relays. Stdlib only, like boot_manager -
    # this is the file that decides whether the gem entry may load, so it
    # cannot depend on it.
    module EntryBoot
      # tier is :booted, :static or :absent. kind names why the static tier
      # is active - :requested, :source_only or :boot_failed - so consumers
      # branch on a fact instead of parsing the reason text.
      Outcome = Struct.new(:tier, :reason, :kind, :messages, keyword_init: true)

      NO_APP_HINT = "Run this command inside a Rails app or a folder holding one (or pass --app-path)."

      # A restored gem path must land ahead of these, or a gem with a
      # default-gem twin (prism, json) loads half from Ruby and half from itself.
      RUBY_OWN_DIRS = %w[
        rubylibdir rubyarchdir sitelibdir sitearchdir vendorlibdir vendorarchdir
      ].filter_map { |key| RbConfig::CONFIG[key] }.freeze

      class << self
        # Every gem the binstub activated, stashed by the binary before it
        # cleared the registry. Nothing else can re-add their load paths.
        attr_accessor :preboot_gem_specs

        # Their specs stay unregistered: that is how an app-less entry knows to
        # splice their load paths back.
        attr_accessor :preboot_framework_names
      end
      self.preboot_gem_specs = {}
      self.preboot_framework_names = []

      # The boot tier needs config/environment.rb. The static tier only needs
      # source: an engine keeps its dummy app under spec/dummy, so its root
      # has app/ and no config/, and it is a real target.
      def self.app_present?(root, allow_source_only: false)
        return false if other_framework?(root)
        return true if File.exist?(File.join(root, "config", "environment.rb"))
        return false unless allow_source_only
        return true if File.exist?(File.join(root, "config", "application.rb"))

        source_file?(File.join(root, "app"))
      end

      # Whether app/ holds a Ruby file, as app/**/*.rb would match one: the
      # first answers, where a glob lists the whole tree before it yields, and
      # hidden entries are passed over as the glob passes them.
      def self.source_file?(dir)
        return false unless File.directory?(dir)

        # The trailing separator walks into app/ when it is a link.
        start = File.join(dir, "")
        Find.find(start) do |path|
          next if path == start

          Find.prune if File.basename(path).start_with?(".")
          return true if path.end_with?(".rb") && File.file?(path)
        end
        false
      end
      private_class_method :source_file?

      # Sinatra MVC trees have config/environment.rb too; without application.rb the lockfile, else the Gemfile, decides.
      def self.other_framework?(root)
        return false if File.exist?(File.join(root, "config", "application.rb"))

        require_relative "../gem_lock"
        lock = GemLock.for(root)
        return !lock.any?("rails", "railties") unless lock.missing?

        names = lock.gemfile_gems
        !names.nil? && (names & %w[rails railties]).empty?
      end

      def self.call(root:, allow_static:, no_boot: false, allow_source_only: false, command: nil)
        messages = []

        if allow_static && no_boot
          return absent(root, messages, command: command) unless app_present?(root, allow_source_only: true)

          return enter_static("static mode requested with --no-boot", :requested, root, messages)
        end

        return absent(root, messages, command: command) unless app_present?(root, allow_source_only: allow_source_only)

        # No boot can succeed without config/environment.rb, so a source-only
        # tree answers now rather than printing a failure that was certain.
        unless app_present?(root)
          return absent(root, messages, command: command) unless allow_static

          return enter_static("no config/environment.rb in the app root", :source_only, root, messages)
        end

        # Bundler.setup (in config/boot.rb) strips $LOAD_PATH and the spec
        # registry to Gemfile-resolved gems; in a standalone install that
        # removes this gem and its MCP deps, so both are captured first and
        # always restored: every branch below needs the gem loadable.
        pre_boot_paths = $LOAD_PATH.dup
        pre_boot_specs = preboot_gem_specs.reject { |name, _| preboot_framework_names.include?(name) }
        timeout = BootManager.env_timeout
        begin
          drop_conflicting_gem_activations!(messages)
          result = BootManager.boot!(app_root: root, timeout: timeout)
        ensure
          restore_standalone_environment!(pre_boot_paths, pre_boot_specs, messages)
        end

        unless result.booted?
          return boot_failed(result, root, timeout, messages) unless allow_static

          messages << "[rails-ai-context] App boot failed: #{result.failure_summary}"
          if result.error.is_a?(BootManager::BootTimeoutError)
            messages << "[rails-ai-context]   If the app is healthy but slow, raise RAILS_AI_CONTEXT_BOOT_TIMEOUT (seconds, current: #{timeout})."
          end
          result.configure_hint.each { |line| messages << "[rails-ai-context]   #{line}" }
          messages << "[rails-ai-context] Serving static analysis; runtime-only data is marked [UNAVAILABLE]."
          messages << "[rails-ai-context] Run `rails-ai-context doctor` for boot diagnostics."
          return enter_static(result.failure_summary, :boot_failed, root, messages)
        end

        require "rails_ai_context"

        if defined?(::Rails::VERSION::MAJOR) && ::Rails::VERSION::MAJOR >= 9
          messages << "[rails-ai-context] WARNING: Rails #{::Rails.version} is newer than this gem supports (< 9.0)."
          messages << "[rails-ai-context]   Introspection is untested on this version and may be wrong or incomplete."
          messages << "[rails-ai-context]   Check for a newer rails-ai-context release."
        end

        Configuration.auto_load!
        Outcome.new(tier: :booted, reason: nil, messages: messages)
      end

      # Splices the stripped load paths back, minus what a completed Bundler.setup pinned.
      def self.require_gem_without_app!
        preboot_gem_specs.each do |name, spec|
          next if Gem.loaded_specs.key?(name)

          spec.full_require_paths.each { |p| $LOAD_PATH.unshift(p) unless $LOAD_PATH.include?(p) }
        end
        require "rails_ai_context"
      end

      # A tree with app source but no config/environment.rb is an app that
      # cannot boot, not a wrong directory: sending its owner to the app root
      # they are already standing in is the wrong diagnosis.
      def self.absent(root, messages, command: nil)
        if app_present?(root, allow_source_only: true)
          messages << "Error: #{command || 'this command'} needs a bootable app: no config/environment.rb in #{root}"
        else
          messages << "Error: No Rails app found in #{root}"
          messages << NO_APP_HINT
        end
        Outcome.new(tier: :absent, reason: nil, messages: messages)
      end
      private_class_method :absent

      def self.boot_failed(result, root, timeout, messages)
        messages << "Error: Rails app failed to boot in #{root}"
        messages << "  #{result.failure_summary(full: true)}"
        if ENV["DEBUG"]
          Array(result.error.backtrace).first(15).each { |line| messages << "    #{line}" }
          # The wrapper's frames stop at the require; the frames that name the
          # incompatible call are the cause's.
          if (cause = result.root_cause)
            messages << "  Raised by:"
            Array(cause.backtrace).first(15).each { |line| messages << "    #{line}" }
          end
        else
          messages << "  Run with DEBUG=1 for the full backtrace."
        end

        hint = result.configure_hint
        if result.error.is_a?(BootManager::BootTimeoutError)
          messages << "  The app took longer than #{timeout}s to boot. Raise the limit with"
          messages << "  RAILS_AI_CONTEXT_BOOT_TIMEOUT=<seconds> (current: #{timeout}s)."
        elsif hint.any?
          hint.each { |line| messages << "  #{line}" }
        else
          messages << "  Common causes: missing ENV vars or credentials, an initializer"
          messages << "  that needs a service (database, Redis), or a syntax error."
          messages << "  If the app is healthy but slow to boot, raise RAILS_AI_CONTEXT_BOOT_TIMEOUT (seconds, default 60)."
        end
        Outcome.new(tier: :absent, reason: result.failure_summary, messages: messages)
      end
      private_class_method :boot_failed

      # Static tier: the gem loads with no app constants, introspection runs
      # against the filesystem, and every tool response carries the tier banner.
      # A broken install cannot load the gem either; the lines collected so
      # far still go out with the error.
      def self.enter_static(reason, kind, root, messages)
        require_gem_without_app!
        RailsAiContext.tier = :static
        # Every tool response carries this in its footer, so an absolute path in a boot error goes root-relative.
        RailsAiContext.static_reason = RailsAiContext::PortablePath.relativize_text(reason, root)
        RailsAiContext.static_kind = kind
        RailsAiContext.configuration.app_root = root
        Configuration.auto_load!(root)
        # A failed boot's reason is already the line above.
        messages << "[rails-ai-context] static tier active#{": #{reason}" unless kind == :boot_failed}"
        Outcome.new(tier: :static, reason: reason, kind: kind, messages: messages)
      rescue StandardError, ScriptError => e
        messages << "Error: #{e.message}"
        # `reason` on an :absent outcome means the app's own boot failed, which
        # is what the binary hangs the doctor hint on. A --no-boot run booted
        # nothing, so its failure here carries none.
        Outcome.new(tier: :absent, reason: kind == :boot_failed ? reason : nil, messages: messages)
      end
      private_class_method :enter_static

      # The binary pre-activates stdlib gems (psych via yaml, date) before the
      # app's Bundler.setup runs, and a different pin raises `Gem::LoadError:
      # already activated psych 5.4.0`. Dropping every registration except
      # bundler's lets the app activate what it resolves; loaded code stays
      # (require is idempotent). No-op under `bundle exec`, where Bundler
      # already governs activation.
      #
      # Their $LOAD_PATH entries go with them: Bundler adds its own paths
      # behind these, so they would answer `require` ahead of the app's pins.
      def self.drop_conflicting_gem_activations!(messages)
        return if ENV["BUNDLE_BIN_PATH"]
        return unless defined?(Gem) && Gem.respond_to?(:loaded_specs)

        preboot_gem_specs.each do |name, spec|
          next if name == "bundler"

          spec.full_require_paths.each { |path| $LOAD_PATH.delete(path) }
        end
        Gem.loaded_specs.delete_if { |name, _| name != "bundler" }
      rescue => e
        messages << "[rails-ai-context] drop_conflicting_gem_activations! failed: #{e.message}" if ENV["DEBUG"]
      end
      private_class_method :drop_conflicting_gem_activations!

      # Once the app's bundle is on the load path its gems may be loaded, so it keeps
      # the front and this gem's paths go behind it; else the pre-boot order returns whole.
      def self.restore_standalone_environment!(pre_boot_paths, pre_boot_specs, messages)
        if ($LOAD_PATH - pre_boot_paths).any?
          splice_before_ruby_dirs!(pre_boot_paths - $LOAD_PATH)
        else
          $LOAD_PATH.replace(pre_boot_paths)
        end
        pre_boot_specs.each { |name, spec| Gem.loaded_specs[name] ||= spec }
        warn_unsupported_app_versions(pre_boot_specs, messages)

        missing = pre_boot_specs.keys.reject { |name| Gem.loaded_specs.key?(name) }
        return if missing.none? || ENV["BUNDLE_BIN_PATH"]

        messages << "[rails-ai-context] WARNING: standalone CLI could not restore gemspec(s): #{missing.join(', ')}."
        messages << "[rails-ai-context]   Tool calls may crash with `undefined method 'full_gem_path' for nil`."
        messages << "[rails-ai-context]   Try `gem install rails-ai-context` to ensure all transitive deps are installed."
      end
      private_class_method :restore_standalone_environment!

      # The app's copy of a dependency stays in use, since two copies in one process
      # is a mixed load; it is named when outside what the gemspec supports.
      def self.warn_unsupported_app_versions(pre_boot_specs, messages)
        own = pre_boot_specs["rails-ai-context"] or return

        own.runtime_dependencies.each do |dep|
          app = Gem.loaded_specs[dep.name]
          next if app.nil? || app.equal?(pre_boot_specs[dep.name]) || dep.requirement.satisfied_by?(app.version)

          messages << "[rails-ai-context] WARNING: the app locks #{dep.name} #{app.version}; " \
                      "this gem needs #{dep.name} #{dep.requirement}. Tools that use it may fail."
        end
      end
      private_class_method :warn_unsupported_app_versions

      def self.splice_before_ruby_dirs!(paths)
        return if paths.empty?

        index = $LOAD_PATH.index { |path| RUBY_OWN_DIRS.include?(path) } || $LOAD_PATH.size
        $LOAD_PATH.insert(index, *paths)
      end
      private_class_method :splice_before_ruby_dirs!
    end
  end
end
