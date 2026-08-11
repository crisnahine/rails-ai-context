# frozen_string_literal: true

module RailsAiContext
  # Re-runs Rails' own code reloader so a long-lived process sees files written
  # after it booted.
  #
  # Clearing the gem's caches is not enough on its own. Introspectors reach the
  # app through constants, and the eager loading they trigger
  # (`Zeitwerk::Loader#eager_load_dir`) is idempotent per process - a directory
  # already loaded is never re-scanned, so a model added after boot stays
  # invisible for the life of the server. Routes never had the problem because
  # RouteIntrospector asks `routes_reloader.execute_if_updated` every call.
  module CodeReloader
    module_function

    # Reload the app's autoloaded code. Returns whether a reload actually ran,
    # so callers can say what they did instead of guessing.
    def reload!
      return false unless reloadable?

      Rails.application.reloader.reload!
      true
    rescue StandardError, ScriptError => e
      # A broken file mid-edit is the common case. Zeitwerk reloads by
      # unload-then-setup, so a raise can leave constants already unloaded -
      # they re-autoload lazily on next reference. Either way a running server
      # must survive it.
      $stderr.puts "[rails-ai-context] code reload failed: #{e.class}: #{e.message}" if ENV["DEBUG"]
      false
    end

    # Run a block with the sharing lock held, so a reload cannot unload
    # constants underneath it.
    #
    # `Reloader#class_unload!` takes the unload lock through
    # ActiveSupport::Dependencies.interlock, but that only blocks threads
    # holding the sharing lock - which is acquired inside `executor.wrap`.
    # Nothing here wrapped anything, so the Listen thread could clear
    # DescendantsTracker while a tool call was midway through reading
    # `ActiveRecord::Base.descendants`, returning a short list with no
    # exception for the per-section rescue to notice.
    #
    # Only taken when a reload could actually happen; everywhere else this is
    # a plain yield.
    def with_app_code
      return yield unless reloadable?

      app = Rails.application
      return yield unless app.respond_to?(:executor)

      app.executor.wrap { yield }
    end

    # `enable_reloading` is the flag that decides whether Rails unloads
    # anything: with it off, the finisher registers no class_unload callback,
    # so `reload!` runs the prepare callbacks and returns having reloaded
    # nothing. Gating on `eager_load` instead reported success for every
    # eager_load=false + cache_classes=true environment (stock `test`, a
    # cache-classes staging container) - a reload that never happened,
    # announced as one.
    def reloadable?
      return false if RailsAiContext.static_tier?
      return false unless defined?(Rails) && Rails.respond_to?(:application)

      app = Rails.application
      return false unless app.respond_to?(:reloader) && app.respond_to?(:config)

      config = app.config
      # Rails 7.1+ names it enable_reloading; older releases only have
      # cache_classes, which is its inverse.
      return config.enable_reloading if config.respond_to?(:enable_reloading)
      return !config.cache_classes if config.respond_to?(:cache_classes)

      false
    rescue StandardError
      false
    end
  end
end
