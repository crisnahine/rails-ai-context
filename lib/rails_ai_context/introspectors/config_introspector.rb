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
        result = {
          cache_store: detect_cache_store,
          session_store: detect_session_store,
          timezone: app.config.time_zone.to_s,
          queue_adapter: detect_queue_adapter,
          mailer: detect_mailer_settings,
          middleware_stack: extract_middleware,
          initializers: extract_initializers,
          credentials_configured: credentials_configured?,
          current_attributes: detect_current_attributes,
          error_monitoring: detect_error_monitoring,
          job_processor: detect_job_processor_config
        }

        # Extract cache store options when configured as an Array
        if app.config.cache_store.is_a?(Array) && app.config.cache_store.size > 1
          opts = app.config.cache_store[1..]
          cache_opts = opts.last.is_a?(Hash) ? opts.last.keys.map(&:to_s) : []
          result[:cache_store_options] = cache_opts if cache_opts.any?
        end

        result.compact
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
      # Does NOT expose key names - those could reveal integrated services.
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

        target_bases = %w[ActiveSupport::CurrentAttributes Rails::CurrentAttributes]

        Dir.glob(File.join(models_dir, "**/*.rb")).filter_map do |path|
          parse_result = AstCache.parse(path)
          class_node = find_first_class_node(parse_result.value)
          next unless class_node&.superclass

          superclass_name = constant_path_to_string(class_node.superclass)
          if target_bases.include?(superclass_name)
            File.basename(path, ".rb").camelize
          end
        rescue => _e
          next
        end
      end

      def find_first_class_node(node)
        return node if node.is_a?(Prism::ClassNode)
        node.child_nodes.compact.each do |child|
          found = find_first_class_node(child)
          return found if found
        end
        nil
      end

      def constant_path_to_string(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          parts.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
          parts.join("::")
        else
          nil
        end
      end

      def detect_error_monitoring
        gemfile_lock = File.join(app.root, "Gemfile.lock")
        return nil unless File.exist?(gemfile_lock)
        content = RailsAiContext::SafeFile.read(gemfile_lock)
        return nil unless content

        tools = []
        tools << "sentry" if content.include?("sentry-ruby") || content.include?("sentry-rails")
        tools << "bugsnag" if content.include?("bugsnag")
        tools << "honeybadger" if content.include?("honeybadger")
        tools << "rollbar" if content.include?("rollbar")
        tools << "airbrake" if content.include?("airbrake")
        tools << "appsignal" if content.include?("appsignal")
        tools.empty? ? nil : tools
      rescue => e
        $stderr.puts "[rails-ai-context] detect_error_monitoring failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_job_processor_config
        config = {}
        sidekiq_path = File.join(app.root, "config", "sidekiq.yml")
        if File.exist?(sidekiq_path)
          content = RailsAiContext::SafeFile.read(sidekiq_path)
          if content
            config[:processor] = "sidekiq"
            config[:concurrency] = $1.to_i if content.match(/concurrency:\s*(\d+)/)
            config[:queues] = content.scan(/-\s+(\w+)/).flatten.uniq
          end
        end
        config.empty? ? nil : config
      rescue => e
        $stderr.puts "[rails-ai-context] detect_job_processor_config failed: #{e.message}" if ENV["DEBUG"]
        nil
      end
    end
  end
end
