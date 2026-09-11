# frozen_string_literal: true

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

      # The MCP SDK reads these from Gem.loaded_specs at tool-call time
      # (Gem.loaded_specs["json-schema"].full_gem_path); Bundler.setup strips
      # them in a standalone install, so they are captured before boot and
      # re-registered after.
      STANDALONE_REQUIRED_GEMS = %w[mcp json-schema addressable public_suffix].freeze

      NO_APP_HINT = "Run this command from your Rails app root directory (or pass --app-path)."

      class << self
        # Framework specs the binary stripped from $LOAD_PATH before anything
        # loaded. App-less entries splice them back by hand.
        attr_accessor :stripped_framework_specs
      end
      self.stripped_framework_specs = {}

      # The boot tier needs config/environment.rb. The static tier only needs
      # source: an engine keeps its dummy app under spec/dummy, so its root
      # has app/ and no config/, and it is a real target.
      def self.app_present?(root, allow_source_only: false)
        return true if File.exist?(File.join(root, "config", "environment.rb"))
        return false unless allow_source_only

        File.exist?(File.join(root, "config", "application.rb")) ||
          Dir.glob(File.join(root, "app", "**", "*.rb")).any?
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

          return enter_static("no config/environment.rb in #{root}", :source_only, root, messages)
        end

        # Bundler.setup (in config/boot.rb) strips $LOAD_PATH and the spec
        # registry to Gemfile-resolved gems; in a standalone install that
        # removes this gem and its MCP deps, so both are captured first.
        pre_boot_paths = $LOAD_PATH.dup
        pre_boot_specs = capture_standalone_specs
        drop_conflicting_gem_activations!(messages)

        timeout = BootManager.env_timeout
        result = BootManager.boot!(app_root: root, timeout: timeout)

        unless result.booted?
          return boot_failed(result, root, timeout, messages) unless allow_static

          messages << "[rails-ai-context] App boot failed: #{result.failure_summary}"
          if result.error.is_a?(BootManager::BootTimeoutError)
            messages << "[rails-ai-context]   If the app is healthy but slow, raise RAILS_AI_CONTEXT_BOOT_TIMEOUT (seconds, current: #{timeout})."
          end
          result.configure_hint.each { |line| messages << "[rails-ai-context]   #{line}" }
          messages << "[rails-ai-context] Serving static analysis; runtime-only data is marked [UNAVAILABLE]."
          messages << "[rails-ai-context] Run `rails-ai-context doctor` for boot diagnostics."
          restore_standalone_environment!(pre_boot_paths, pre_boot_specs, messages)
          return enter_static(result.failure_summary, :boot_failed, root, messages)
        end

        restore_standalone_environment!(pre_boot_paths, pre_boot_specs, messages)
        require "rails_ai_context"

        if defined?(::Rails::VERSION::MAJOR) && ::Rails::VERSION::MAJOR >= 9
          messages << "[rails-ai-context] WARNING: Rails #{::Rails.version} is newer than this gem supports (< 9.0)."
          messages << "[rails-ai-context]   Introspection is untested on this version and may be wrong or incomplete."
          messages << "[rails-ai-context]   Check for a newer rails-ai-context release."
        end

        Configuration.auto_load!
        Outcome.new(tier: :booted, reason: nil, messages: messages)
      end

      # Loads the gem with no booted app. Framework gems whose load paths the
      # binary stripped are spliced back from the stashed specs - except any
      # gem a completed Bundler.setup already resolved, whose pinned paths
      # must keep winning over the newest installed version.
      def self.require_gem_without_app!
        stripped_framework_specs.each do |name, spec|
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
        messages << "  #{result.failure_summary}"
        if ENV["DEBUG"]
          Array(result.error.backtrace).first(15).each { |line| messages << "    #{line}" }
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
        RailsAiContext.static_reason = reason
        RailsAiContext.static_kind = kind
        RailsAiContext.configuration.app_root = root
        Configuration.auto_load!(root)
        messages << "[rails-ai-context] static tier active: #{reason}"
        Outcome.new(tier: :static, reason: reason, kind: kind, messages: messages)
      rescue StandardError, ScriptError => e
        messages << "Error: #{e.message}"
        # `reason` on an :absent outcome means the app's own boot failed, which
        # is what the binary hangs the doctor hint on. A --no-boot run booted
        # nothing, so its failure here carries none.
        Outcome.new(tier: :absent, reason: kind == :boot_failed ? reason : nil, messages: messages)
      end
      private_class_method :enter_static

      # Gem::Specification.find_by_name only sees Gemfile-resolved gems once
      # Bundler.setup has run, so the specs are looked up before boot.
      def self.capture_standalone_specs
        return {} unless defined?(Gem) && Gem.respond_to?(:loaded_specs)

        STANDALONE_REQUIRED_GEMS.each_with_object({}) do |gem_name, acc|
          spec = Gem::Specification.find_by_name(gem_name)
          acc[gem_name] = spec if spec
        rescue Gem::MissingSpecError, Gem::LoadError
          # Not installed at all; the downstream require gives the clearer error.
          next
        end
      end
      private_class_method :capture_standalone_specs

      # The binary pre-activates stdlib gems (psych via yaml, date) before the
      # app's Bundler.setup runs, and a different pin raises `Gem::LoadError:
      # already activated psych 5.4.0`. Dropping every registration except
      # bundler's lets the app activate what it resolves; loaded code stays
      # (require is idempotent). No-op under `bundle exec`, where Bundler
      # already governs activation.
      def self.drop_conflicting_gem_activations!(messages)
        return if ENV["BUNDLE_BIN_PATH"]
        return unless defined?(Gem) && Gem.respond_to?(:loaded_specs)

        Gem.loaded_specs.delete_if { |name, _| name != "bundler" }
      rescue => e
        messages << "[rails-ai-context] drop_conflicting_gem_activations! failed: #{e.message}" if ENV["DEBUG"]
      end
      private_class_method :drop_conflicting_gem_activations!

      def self.restore_standalone_environment!(pre_boot_paths, pre_boot_specs, messages)
        (pre_boot_paths - $LOAD_PATH).each { |p| $LOAD_PATH << p }
        pre_boot_specs.each { |name, spec| Gem.loaded_specs[name] ||= spec }

        missing = STANDALONE_REQUIRED_GEMS.reject { |g| Gem.loaded_specs.key?(g) }
        return if missing.none? || ENV["BUNDLE_BIN_PATH"]

        messages << "[rails-ai-context] WARNING: standalone CLI could not restore gemspec(s): #{missing.join(', ')}."
        messages << "[rails-ai-context]   Tool calls may crash with `undefined method 'full_gem_path' for nil`."
        messages << "[rails-ai-context]   Try `gem install rails-ai-context` to ensure all transitive deps are installed."
      end
      private_class_method :restore_standalone_environment!
    end
  end
end
