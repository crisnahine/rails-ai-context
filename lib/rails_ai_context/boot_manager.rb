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

    # An initializer calling exit() or abort(). A distinct class so the CLI's
    # degrade path can name the mode without parsing message text.
    class BootExitError < BootError; end

    DEFAULT_TIMEOUT = 60

    # Ruby quotes the method name differently across versions.
    CONFIGURE_WITHOUT_GEM = /undefined method .?configure.? for (module )?RailsAiContext/

    Result = Struct.new(:status, :error, keyword_init: true) do
      def booted?
        status == :booted
      end

      # Bundler::GemRequireError names the gem it failed to require and
      # nothing about why; the incompatibility that actually raised is in
      # `cause`. Walk to the deepest one, capped so a cycle cannot hang.
      def root_cause
        cause = error&.cause
        10.times do
          break unless cause&.cause

          cause = cause.cause
        end
        cause
      end

      # One-line summary safe to relay to an AI client or a terminal. It
      # carries the cause too: the footer this feeds is the only place most
      # callers ever see, and a gem name with no reason is not actionable.
      def failure_summary
        return nil if booted?

        summary = one_line(error)
        cause = root_cause
        cause ? "#{summary} (cause: #{one_line(cause)})" : summary
      end

      def one_line(e)
        "#{e.class}: #{e.message.to_s.lines.first&.strip}"
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
    # never raises for boot problems, including an initializer that exits.
    # This process belongs to the standalone binary, not to the app, and the
    # caller has a static tier to answer from - so an exit here is a boot
    # failure like any other. `guard` still lets the exit stand for callers
    # running inside the app's own process.
    def self.boot!(app_root: Dir.pwd, timeout: DEFAULT_TIMEOUT)
      environment_rb = File.join(app_root, "config", "environment.rb")
      unless File.exist?(environment_rb)
        return Result.new(
          status: :failed,
          error: BootError.new("No Rails app found in #{app_root} (missing config/environment.rb)")
        )
      end

      guard(timeout: timeout, announce_exit: false) { require environment_rb }
    rescue SystemExit => e
      Result.new(status: :failed, error: BootExitError.new("App called exit(#{e.status}) during boot"))
    end

    # The same three protections for callers that boot through their own
    # mechanism - the rake tasks go through Rake's environment task so app
    # hooks on it still run.
    def self.guard(timeout: DEFAULT_TIMEOUT, announce_exit: true)
      OutputGuard.quarantine_stdout do
        Timeout.timeout(timeout) { yield }
      end
      Result.new(status: :booted)
    rescue SystemExit => e
      # The exit stands for callers booting inside the app's own process (the
      # rake tasks), where it is an explicit process-level decision. Its own
      # message is already on stderr; without this line nothing says the call
      # came from here. `boot!` turns the exit into a boot failure and prints
      # that instead, so it asks for no notice rather than the same sentence
      # twice.
      $stderr.puts "[rails-ai-context] App called exit(#{e.status}) during boot." if announce_exit
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
