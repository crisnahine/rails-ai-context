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
      # A broken file mid-edit is the common case here, and it must not take a
      # running server down: the caller keeps the constants it already had,
      # which is stale but alive.
      $stderr.puts "[rails-ai-context] code reload failed: #{e.class}: #{e.message}" if ENV["DEBUG"]
      false
    end

    # Only a booted, non-eager-loading app has anything to reload. Eager loading
    # is the deploy-time posture: constants are all resolved and reloading is
    # both pointless and unsafe.
    def reloadable?
      return false if RailsAiContext.static_tier?
      return false unless defined?(Rails) && Rails.respond_to?(:application)

      app = Rails.application
      return false unless app.respond_to?(:reloader) && app.respond_to?(:config)
      return false if app.config.eager_load

      true
    rescue StandardError
      false
    end
  end
end
