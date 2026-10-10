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

    # @param standalone [Boolean, nil] the standalone answer the caller
    #   already has; nil asks the root's own form
    # @param form [Symbol, nil] :standalone, :bundled or :tasks (see #form)
    def command(job, standalone: nil, form: nil)
      form ||= standalone.nil? ? self.form : (standalone ? :standalone : :tasks)
      standalone_form, task_form = COMMANDS.fetch(job)
      case form
      when :standalone then standalone_form
      # The generator runs at an engine's root as it does in an app.
      when :bundled then job == :install ? task_form : "bundle exec #{standalone_form}"
      else task_form
      end
    end

    # One tool's command, `short` being its name without the rails_ /
    # rails_get_ prefix (`schema`), in the form `form` runs it.
    def tool_command(short, form: self.form)
      case form
      when :standalone then "rails-ai-context tool #{short}"
      when :bundled then "bundle exec rails-ai-context tool #{short}"
      else "rails 'ai:tool[#{short}]'"
      end
    end

    # How a reader at the root runs this gem:
    #   :standalone - the installed binary; the app's bundle lacks the gem.
    #   :bundled    - the binary in the root's own bundle. The bundle has the
    #                 gem but the root is a gem's, with no app for the rake
    #                 tasks to load: a mountable engine's root, whose tasks
    #                 run in its dummy app as app:ai:*.
    #   :tasks      - the app's rake tasks.
    def form(root: nil)
      root ||= app_root
      return :standalone if standalone?(root: root)

      gem_root?(root) ? :bundled : :tasks
    end

    def gem_root?(root)
      !File.exist?(File.join(root.to_s, "config", "application.rb")) &&
        Dir.glob(File.join(root.to_s, "*.gemspec")).any?
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
