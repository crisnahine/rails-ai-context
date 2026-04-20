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

      # Collect warnings for introspectors that failed, so serializers can
      # render them and AI clients know which sections are missing.
      warnings = []
      config.introspectors.each do |name|
        data = context[name]
        if data.is_a?(Hash) && data[:error]
          warnings << { introspector: name.to_s, error: data[:error] }
        end
      end
      context[:_warnings] = warnings if warnings.any?

      context
    end

    # Single source of truth: symbol → introspector class.
    # Used by both the dispatcher below AND the Configuration presets validation,
    # so adding/renaming introspectors only requires one edit.
    INTROSPECTOR_MAP = {
      schema: Introspectors::SchemaIntrospector,
      models: Introspectors::ModelIntrospector,
      routes: Introspectors::RouteIntrospector,
      jobs: Introspectors::JobIntrospector,
      gems: Introspectors::GemIntrospector,
      conventions: Introspectors::ConventionIntrospector,
      stimulus: Introspectors::StimulusIntrospector,
      database_stats: Introspectors::DatabaseStatsIntrospector,
      controllers: Introspectors::ControllerIntrospector,
      views: Introspectors::ViewIntrospector,
      view_templates: Introspectors::ViewTemplateIntrospector,
      turbo: Introspectors::TurboIntrospector,
      i18n: Introspectors::I18nIntrospector,
      config: Introspectors::ConfigIntrospector,
      active_storage: Introspectors::ActiveStorageIntrospector,
      action_text: Introspectors::ActionTextIntrospector,
      auth: Introspectors::AuthIntrospector,
      api: Introspectors::ApiIntrospector,
      tests: Introspectors::TestIntrospector,
      rake_tasks: Introspectors::RakeTaskIntrospector,
      assets: Introspectors::AssetPipelineIntrospector,
      devops: Introspectors::DevOpsIntrospector,
      action_mailbox: Introspectors::ActionMailboxIntrospector,
      migrations: Introspectors::MigrationIntrospector,
      seeds: Introspectors::SeedsIntrospector,
      middleware: Introspectors::MiddlewareIntrospector,
      engines: Introspectors::EngineIntrospector,
      multi_database: Introspectors::MultiDatabaseIntrospector,
      components: Introspectors::ComponentIntrospector,
      performance: Introspectors::PerformanceIntrospector,
      frontend_frameworks: Introspectors::FrontendFrameworkIntrospector,
      initializers: Introspectors::InitializerIntrospector,
      autoload: Introspectors::AutoloadIntrospector,
      connection_pool: Introspectors::ConnectionPoolIntrospector,
      active_support: Introspectors::ActiveSupportIntrospector,
      credentials: Introspectors::CredentialsIntrospector,
      security: Introspectors::SecurityIntrospector,
      observability: Introspectors::ObservabilityIntrospector,
      env: Introspectors::EnvIntrospector
    }.freeze

    private

    def app_name
      if app.class.respond_to?(:module_parent_name)
        app.class.module_parent_name
      else
        app.class.name.deconstantize
      end
    end

    def resolve_introspector(name)
      klass = INTROSPECTOR_MAP[name] or raise ConfigurationError, "Unknown introspector: #{name}"
      klass.new(app)
    end
  end
end
