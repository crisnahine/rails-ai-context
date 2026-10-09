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
    # What a reader runs for each job, as [standalone, in the app's bundle].
    COMMANDS = {
      context: [ "rails-ai-context context", "rails ai:context" ],
      install: [ "rails-ai-context init", "rails generate rails_ai_context:install" ],
      serve: [ "rails-ai-context serve", "rails ai:serve" ],
      tool: [ "rails-ai-context tool", "rails ai:tool" ]
    }.freeze

    module_function

    def command(job, standalone: standalone?)
      COMMANDS.fetch(job)[standalone ? 0 : 1]
    end

    # `root:` asks about one app, where the process's own bundle is beside the
    # point: a workspace sets up apps that are not the one it runs in.
    def standalone?(root: nil)
      root ||= if defined?(Bundler)
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
