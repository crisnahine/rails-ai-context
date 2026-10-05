# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts application configuration: cache store, session store,
    # timezone, middleware stack, initializers, credentials status.
    class ConfigIntrospector < Base
      extend StaticTier
      static_tier :runtime_only

      ERROR_MONITORS = {
        "sentry" => %w[sentry-ruby sentry-rails],
        "bugsnag" => %w[bugsnag],
        "honeybadger" => %w[honeybadger],
        "rollbar" => %w[rollbar],
        "airbrake" => %w[airbrake],
        "appsignal" => %w[appsignal]
      }.freeze
      private_constant :ERROR_MONITORS

      def call
        result = {
          cache_store: detect_cache_store,
          session_store: detect_session_store,
          timezone: app.config.time_zone.to_s,
          queue_adapter: detect_queue_adapter,
          mailer: detect_mailer_settings,
          middleware_stack: extract_middleware,
          initializers: extract_initializers,
          credentials_configured: credentials_configured?,
          current_attributes: current_attributes.keys,
          current_attribute_details: current_attributes.presence,
          error_monitoring: detect_error_monitoring
        }

        # Extract cache store options when configured as an Array
        if app.config.cache_store.is_a?(Array) && app.config.cache_store.size > 1
          opts = app.config.cache_store[1..]
          cache_opts = opts.last.is_a?(Hash) ? opts.last.keys.map(&:to_s) : []
          result[:cache_store_options] = cache_opts if cache_opts.any?
        end

        result.compact
      end

      private

      def detect_cache_store
        store = app.config.cache_store
        case store
        when Symbol then store.to_s
        when Array then store.first.to_s
        else store.class.name
        end
      rescue => e
        RailsAiContext.debug_fail(e, "unknown", label: "detect_cache_store")
      end

      def detect_session_store
        app.config.session_store&.name rescue "unknown"
      end

      def detect_queue_adapter
        adapter = app.config.active_job.queue_adapter
        case adapter
        when Symbol then adapter.to_s
        when Class then adapter.name
        else adapter.to_s
        end
      rescue => e
        RailsAiContext.debug_fail(e, "unknown", label: "detect_queue_adapter")
      end

      def detect_mailer_settings
        mailer_config = app.config.action_mailer
        settings = {}

        if mailer_config.respond_to?(:delivery_method) && mailer_config.delivery_method
          settings[:delivery_method] = mailer_config.delivery_method.to_s
        end

        if mailer_config.respond_to?(:default_options) && mailer_config.default_options.is_a?(Hash)
          from = mailer_config.default_options[:from]
          settings[:default_from] = from if from
        end

        if mailer_config.respond_to?(:default_url_options) && mailer_config.default_url_options.is_a?(Hash)
          host = mailer_config.default_url_options[:host]
          settings[:default_url_host] = host if host
        end

        settings.empty? ? nil : settings
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "detect_mailer_settings")
      end

      def extract_middleware
        app.middleware.map { |m| m.name || m.klass.to_s }.uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_middleware")
      end

      def extract_initializers
        dir = File.join(root, "config/initializers/")
        PathResolver.initializer_paths(root).map { |path| path.delete_prefix(dir) }
      end

      # Returns whether credentials are configured (boolean).
      # Does NOT expose key names - those could reveal integrated services.
      def credentials_configured?
        creds = app.credentials
        creds.respond_to?(:config) && creds.config.keys.any?
      rescue => e
        RailsAiContext.debug_fail(e, false, label: "credentials_configured?")
      end

      CURRENT_ATTRIBUTE_BASES = %w[ActiveSupport::CurrentAttributes Rails::CurrentAttributes].freeze
      RESET_HOOKS = %i[resets after_reset before_reset].freeze

      # class name => the attributes it declares and its reset hooks.
      def current_attributes
        @current_attributes ||= SourceScan.classes(root, kind: :models).filter_map do |name, record|
          declared = DeclaredConstant.declarations(record.source).first
          [ name, current_attribute_detail(record.source) ] if declared && CURRENT_ATTRIBUTE_BASES.include?(declared.superclass)
        end.to_h
      end

      def current_attribute_detail(source)
        calls = SourceIntrospector.walk_source(source, {
          calls: -> { Listeners::GenericMacroListener.new(:attribute, *RESET_HOOKS) }
        })[:calls]
        attributes = calls.select { |call| call[:macro] == :attribute }.flat_map do |call|
          default = call[:option_nodes][:default]&.slice
          call[:args].map { |name| default ? { name: name.to_s, default: default } : { name: name.to_s } }
        end
        { attributes: attributes, hooks: calls.map { |call| call[:macro].to_s }.reject { |m| m == "attribute" }.uniq }
      end

      def detect_error_monitoring
        lock = RailsAiContext::GemLock.for(app.root)
        return nil if lock.missing?

        tools = ERROR_MONITORS.filter_map { |tool, gems| tool if lock.any?(*gems) }
        tools.empty? ? nil : tools
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "detect_error_monitoring")
      end
    end
  end
end
