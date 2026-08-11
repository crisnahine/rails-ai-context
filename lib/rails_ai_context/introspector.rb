# frozen_string_literal: true

require "time"

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
        rails_version: rails_version,
        environment: environment_name,
        generated_at: Time.now.utc.iso8601,
        generator: "rails-ai-context v#{RailsAiContext::VERSION}"
      }

      config.introspectors.each do |name|
        introspector = resolve_introspector(name)
        context[name] = run_introspector(introspector)
      rescue StandardError, ScriptError => e
        # ScriptError included: a syntax-broken app file surfacing through
        # eager loading must cost one section, not the whole process (the
        # MCP server would otherwise die mid-session).
        context[name] = { error: e.message }
        RailsAiContext.log_warn "[rails-ai-context] #{name} introspection failed: #{e.message}"
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

      resolve_schema_adapter(context)

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
      env_config: Introspectors::EnvConfigIntrospector,
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

    # `SchemaIntrospector` writes `static_parse` when it read a dump instead of
    # the connection, and every surface that rendered the section raw named a
    # database that does not exist. Fixing that one surface at a time meant
    # `.ai-context.json` and `rails://schema` still disagreed with the
    # multi_database section of the same file. Resolving it here means the
    # context never carries the placeholder, so nothing downstream has to
    # remember. The raw observation stays under `adapter_source` for a reader
    # that needs to know the schema was parsed rather than observed.
    #
    # Runs after the loop: the answer comes from the database config and gem
    # list, which are sections of this same context.
    #
    # Rescued for the same reason the loop above is: this reads two other
    # sections, and a malformed one raising here would cost the whole context
    # rather than one entry. The placeholder surviving is the honest failure.
    def resolve_schema_adapter(context)
      schema = context[:schema]
      return unless schema.is_a?(Hash) && !schema[:error]
      # Only correct a claim that was made. A missing or nil adapter said
      # nothing about the database, and answering for it would be the
      # fabrication this method exists to remove.
      return if schema[:adapter].nil?
      return unless SchemaAdapter.placeholder?(schema[:adapter])

      # "unknown" is a placeholder too. Swapping one for another buys nothing
      # and would bury the parse mode that at least says how the schema was read.
      resolved = SchemaAdapter.label(context)
      return if SchemaAdapter.placeholder?(resolved)

      schema[:adapter_source] = schema[:adapter]
      schema[:adapter] = resolved
    rescue StandardError => e
      RailsAiContext.log_warn "[rails-ai-context] schema adapter resolution failed: #{e.message}"
    end

    def app_name
      return File.basename(app.root.to_s) if app.is_a?(RailsAiContext::StaticApp)

      if app.class.respond_to?(:module_parent_name)
        app.class.module_parent_name
      else
        app.class.name.deconstantize
      end
    end

    # Static tier: what an introspector answers is what it declared, so a
    # section is either real data or an honest refusal, never a guess.
    def run_introspector(introspector)
      return introspector.call unless RailsAiContext.static_tier?

      case introspector.class.static_tier
      when Introspectors::StaticTier::FILES_ONLY       then introspector.call
      when Introspectors::StaticTier::ALTERNATE_SOURCE then introspector.static_call
      else { unavailable: unavailable_reason }
      end
    end

    def unavailable_reason
      Introspectors::StaticTier.unavailable_reason
    end

    def rails_version
      return Rails.version if defined?(Rails) && Rails.respond_to?(:version) && !RailsAiContext.static_tier?

      Confidence.unavailable("app not booted")
    end

    def environment_name
      if defined?(Rails) && Rails.respond_to?(:env) && !RailsAiContext.static_tier?
        Rails.env
      else
        ENV["RAILS_ENV"] || "development"
      end
    end

    def resolve_introspector(name)
      klass = INTROSPECTOR_MAP[name] or raise ConfigurationError, "Unknown introspector: #{name}"
      klass.new(app)
    end
  end
end
