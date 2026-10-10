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
  # With no lockfile yet (a fresh clone), the Gemfile decides: a Gemfile that
  # does not name the gem, and pulls in no other file that might, cannot be
  # serving it. Falls back to treating the install as in-Gemfile (the common
  # case) when neither can be read in full.
  module InstallMode
    # What a reader runs for each job, as [standalone, in the app's bundle].
    # A full-mode run: the binary takes context_mode from the config, which
    # is how a standalone app is in full mode at all; the rake task takes
    # it from the environment for one run, as `ai:context:full` would, but
    # for the selected AI tools only.
    COMMANDS = {
      context: [ "rails-ai-context context", "rails ai:context" ],
      context_full: [ "rails-ai-context context", "CONTEXT_MODE=full rails ai:context" ],
      install: [ "rails-ai-context init", "rails generate rails_ai_context:install" ],
      serve: [ "rails-ai-context serve", "rails ai:serve" ],
      tool: [ "rails-ai-context tool", "rails ai:tool" ]
    }.freeze

    module_function

    def command(job, standalone: standalone?)
      COMMANDS.fetch(job)[standalone ? 0 : 1]
    end

    # `root:` asks about one app; without it, the app under analysis. Either
    # way the app's own bundle decides, never the process's: under bundle
    # exec that can be another app's (`init --app-path ../b` run from a), and
    # a workspace sets up apps that are not the one it runs in.
    def standalone?(root: nil)
      lock = RailsAiContext::GemLock.for(root || app_root)
      return !lock.present?("rails-ai-context") unless lock.missing?

      # nil when the Gemfile cannot be read in full: missing, unparseable, or
      # pulling gems in from files a pre-boot read does not follow
      # (eval_gemfile, gemspec).
      gems = lock.gemfile_gems
      gems.nil? ? false : !gems.include?("rails-ai-context")
    rescue => e
      RailsAiContext.debug_fail(e, false, label: "standalone install detection")
    end

    # Found the way the app's selection is: the root the CLI set, else
    # Rails', else the directory the binary moved into, which is the app's.
    def app_root
      configured = RailsAiContext.configuration.app_root if RailsAiContext.respond_to?(:configuration)
      return configured.to_s if configured
      return Rails.root.to_s if defined?(Rails) && Rails.respond_to?(:root) && Rails.root

      Dir.pwd
    end
  end
end
