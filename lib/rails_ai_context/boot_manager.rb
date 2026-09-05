# frozen_string_literal: true

require "timeout"
require_relative "output_guard"

module RailsAiContext
  # Boots the host Rails app by requiring config/environment.rb, with three
  # protections a bare require lacks:
  #
  #   1. stdout quarantine - boot output goes to stderr so the stdio MCP
  #      protocol channel stays clean.
  #   2. a timeout - initializers that block on unreachable services (a
  #      database, Redis) fail loudly instead of hanging the server forever.
  #   3. a broad rescue - real-world boot failures are ScriptError
  #      (SyntaxError, LoadError) at least as often as StandardError; both
  #      become a structured Result instead of a raw crash.
  #
  # Dependency-free on purpose: standalone mode loads this file before the
  # host app's Bundler.setup runs, so it must not pull in the rest of the gem.
  module BootManager
    class BootError < StandardError; end

    # A dedicated subclass for the timeout case lets callers (the CLI's
    # failure branch) distinguish "boot never finished" from other boot
    # failures without parsing error message text.
    class BootTimeoutError < BootError; end

    DEFAULT_TIMEOUT = 60

    # Ruby quotes the method name differently across versions.
    CONFIGURE_WITHOUT_GEM = /undefined method .?configure.? for (module )?RailsAiContext/

    Result = Struct.new(:status, :error, keyword_init: true) do
      def booted?
        status == :booted
      end

      # One-line summary safe to relay to an AI client or a terminal.
      def failure_summary
        return nil if booted?

        "#{error.class}: #{error.message.to_s.lines.first&.strip}"
      end

      # An unguarded `RailsAiContext.configure` in config/initializers has
      # nothing to call where the gem is not loaded, and the bare
      # NoMethodError does not say what to do about it. Every surface that
      # relays a boot failure relays these lines with it.
      def configure_hint
        return [] unless failure_summary.to_s.match?(CONFIGURE_WITHOUT_GEM)

        [
          "config/initializers calls RailsAiContext.configure, but the app does not bundle the gem.",
          "Either `bundle add rails-ai-context --group development`, or move those",
          "settings into .rails-ai-context.yml, which standalone mode reads."
        ]
      end
    end

    # Attempts to boot the Rails app rooted at app_root. Returns a Result;
    # never raises for boot problems. SystemExit passes through, announced on
    # stderr - an initializer calling exit() is an explicit process-level
    # decision.
    def self.boot!(app_root: Dir.pwd, timeout: DEFAULT_TIMEOUT)
      environment_rb = File.join(app_root, "config", "environment.rb")
      unless File.exist?(environment_rb)
        return Result.new(
          status: :failed,
          error: BootError.new("No Rails app found in #{app_root} (missing config/environment.rb)")
        )
      end

      guard(timeout: timeout) { require environment_rb }
    end

    # The same three protections for callers that boot through their own
    # mechanism - the rake tasks go through Rake's environment task so app
    # hooks on it still run.
    def self.guard(timeout: DEFAULT_TIMEOUT)
      OutputGuard.quarantine_stdout do
        Timeout.timeout(timeout) { yield }
      end
      Result.new(status: :booted)
    rescue SystemExit => e
      # The exit stands: an initializer calling exit() is an explicit
      # process-level decision, and its own message is already on stderr.
      # Without this line nothing says the call came from here, or that the
      # static tier answers it without booting.
      $stderr.puts "[rails-ai-context] App exited during boot (status #{e.status}); rerun with --no-boot for the static tier."
      raise
    rescue Timeout::Error
      # Timeout::Error's own message ("execution expired") names neither the
      # app nor the configured limit - wrap it so a slow-booting app produces
      # actionable guidance instead of a cryptic stdlib message.
      Result.new(status: :failed, error: BootTimeoutError.new("Boot did not finish within #{timeout}s"))
    rescue StandardError, ScriptError => e
      Result.new(status: :failed, error: e)
    end

    # One parse of RAILS_AI_CONTEXT_BOOT_TIMEOUT for every boot surface, so a
    # bad value degrades the same way everywhere.
    def self.env_timeout
      Integer(ENV.fetch("RAILS_AI_CONTEXT_BOOT_TIMEOUT", DEFAULT_TIMEOUT))
    rescue ArgumentError
      $stderr.puts "[rails-ai-context] WARNING: RAILS_AI_CONTEXT_BOOT_TIMEOUT=#{ENV['RAILS_AI_CONTEXT_BOOT_TIMEOUT']} is not a number - using #{DEFAULT_TIMEOUT}s"
      DEFAULT_TIMEOUT
    end
  end
end
