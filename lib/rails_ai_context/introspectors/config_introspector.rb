# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts application configuration: cache store, session store,
    # timezone, middleware stack, initializers, credentials status.
    class ConfigIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          cache_store: detect_cache_store,
          session_store: detect_session_store,
          timezone: app.config.time_zone.to_s,
          queue_adapter: detect_queue_adapter,
          mailer: detect_mailer_settings,
          middleware_stack: extract_middleware,
          initializers: extract_initializers,
          credentials_configured: credentials_configured?,
          current_attributes: detect_current_attributes
        }.compact
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def detect_cache_store
        store = app.config.cache_store
        case store
        when Symbol then store.to_s
        when Array then store.first.to_s
        else store.class.name
        end
      rescue => e
        $stderr.puts "[rails-ai-context] detect_cache_store failed: #{e.message}" if ENV["DEBUG"]
        "unknown"
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
        $stderr.puts "[rails-ai-context] detect_queue_adapter failed: #{e.message}" if ENV["DEBUG"]
        "unknown"
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
        $stderr.puts "[rails-ai-context] detect_mailer_settings failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def extract_middleware
        app.middleware.map { |m| m.name || m.klass.to_s }.uniq
      rescue => e
        $stderr.puts "[rails-ai-context] extract_middleware failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_initializers
        dir = File.join(root, "config/initializers")
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*.rb")).map { |f| File.basename(f) }.sort
      end

      # Returns whether credentials are configured (boolean).
      # Does NOT expose key names — those could reveal integrated services.
      def credentials_configured?
        creds = app.credentials
        creds.respond_to?(:config) && creds.config.keys.any?
      rescue => e
        $stderr.puts "[rails-ai-context] credentials_configured? failed: #{e.message}" if ENV["DEBUG"]
        false
      end

      def detect_current_attributes
        models_dir = File.join(root, "app/models")
        return [] unless Dir.exist?(models_dir)

        Dir.glob(File.join(models_dir, "**/*.rb")).filter_map do |path|
          content = File.read(path)
          if content.match?(/< ActiveSupport::CurrentAttributes|< Rails::CurrentAttributes/)
            File.basename(path, ".rb").camelize
          end
        rescue => e
          $stderr.puts "[rails-ai-context] detect_current_attributes failed: #{e.message}" if ENV["DEBUG"]
          nil
        end
      end
    end
  end
end
