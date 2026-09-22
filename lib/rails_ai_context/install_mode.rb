# frozen_string_literal: true

require_relative "gem_lock"

module RailsAiContext
  # Detects how the gem is installed into the current app so user-facing copy
  # can advertise invocation forms that actually exist.
  #
  # A standalone install runs the gem via its own CLI binary (`gem install
  # rails-ai-context` + `rails-ai-context init`) rather than through the host
  # app's Bundler group, so none of the rake tasks this gem ships (`rails
  # ai:*`) are available - only the `rails-ai-context` binary works. Detected
  # by scanning the resolved Gemfile.lock for a rails-ai-context spec line.
  # Falls back to treating the install as in-Gemfile (the common case) when
  # the lock file can't be read.
  module InstallMode
    module_function

    def standalone?
      root = if defined?(Bundler)
        Bundler.root.to_s
      elsif defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.to_s
      else
        Dir.pwd
      end

      lock = RailsAiContext::GemLock.for(root)
      lock.missing? ? false : !lock.present?("rails-ai-context")
    rescue => e
      RailsAiContext.debug_fail(e, false, label: "standalone install detection")
    end
  end
end
