# frozen_string_literal: true

module RailsAiContext
  # Orchestrates all sub-introspectors to build a complete
  # picture of the Rails application for AI consumption.
  class Introspector
    attr_reader :app, :config

    def initialize(app)
      @app    = app
      @config = RailsAiContext.configuration
    end

    # Run all configured introspectors and return unified context hash
    #
    # @return [Hash] complete application context
    def call
      context = {
        app_name: app_name,
        ruby_version: RUBY_VERSION,
        rails_version: Rails.version,
        environment: Rails.env,
        generated_at: Time.current.iso8601,
        generator: "rails-ai-context v#{RailsAiContext::VERSION}"
      }

      config.introspectors.each do |name|
        introspector = resolve_introspector(name)
        context[name] = introspector.call
      rescue => e
        context[name] = { error: e.message }
        Rails.logger.warn "[rails-ai-context] #{name} introspection failed: #{e.message}"
      end

      context
    end

    private

    def app_name
      if app.class.respond_to?(:module_parent_name)
        app.class.module_parent_name
      else
        app.class.name.deconstantize
      end
    end

    def resolve_introspector(name)
      case name
      when :schema      then Introspectors::SchemaIntrospector.new(app)
      when :models      then Introspectors::ModelIntrospector.new(app)
      when :routes      then Introspectors::RouteIntrospector.new(app)
      when :jobs        then Introspectors::JobIntrospector.new(app)
      when :gems        then Introspectors::GemIntrospector.new(app)
      when :conventions then Introspectors::ConventionDetector.new(app)
      when :stimulus       then Introspectors::StimulusIntrospector.new(app)
      when :database_stats then Introspectors::DatabaseStatsIntrospector.new(app)
      when :controllers    then Introspectors::ControllerIntrospector.new(app)
      when :views          then Introspectors::ViewIntrospector.new(app)
      when :view_templates then Introspectors::ViewTemplateIntrospector.new(app)
      when :design_tokens  then Introspectors::DesignTokenIntrospector.new(app)
      when :turbo          then Introspectors::TurboIntrospector.new(app)
      when :i18n           then Introspectors::I18nIntrospector.new(app)
      when :config         then Introspectors::ConfigIntrospector.new(app)
      when :active_storage then Introspectors::ActiveStorageIntrospector.new(app)
      when :action_text    then Introspectors::ActionTextIntrospector.new(app)
      when :auth           then Introspectors::AuthIntrospector.new(app)
      when :api            then Introspectors::ApiIntrospector.new(app)
      when :tests          then Introspectors::TestIntrospector.new(app)
      when :rake_tasks     then Introspectors::RakeTaskIntrospector.new(app)
      when :assets         then Introspectors::AssetPipelineIntrospector.new(app)
      when :devops         then Introspectors::DevOpsIntrospector.new(app)
      when :action_mailbox then Introspectors::ActionMailboxIntrospector.new(app)
      when :migrations      then Introspectors::MigrationIntrospector.new(app)
      when :seeds           then Introspectors::SeedsIntrospector.new(app)
      when :middleware       then Introspectors::MiddlewareIntrospector.new(app)
      when :engines         then Introspectors::EngineIntrospector.new(app)
      when :multi_database  then Introspectors::MultiDatabaseIntrospector.new(app)
      else
        raise ConfigurationError, "Unknown introspector: #{name}"
      end
    end
  end
end
