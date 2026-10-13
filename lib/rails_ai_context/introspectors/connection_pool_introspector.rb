# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts ActiveRecord connection pool & adapter configuration per
    # database: pool size, checkout timeout, reaping, prepared_statements,
    # advisory_locks, read-replica flag. Covers RAILS_NERVOUS_SYSTEM.md
    # §10 (ActiveRecord - Connections & Adapters).
    class ConnectionPoolIntrospector < Base
      extend StaticTier
      static_tier :runtime_only

      def call
        return { skipped: true, reason: "ActiveRecord not available" } unless defined?(ActiveRecord::Base)

        {
          databases: extract_databases,
          pool_handlers: detect_pool_handlers,
          automatic_shard_selector: detect_automatic_shard_selector
        }
      end

      private

      def extract_databases
        RailsAiContext::AppDatabases.for(root).here.map do |db|
          cfg = db.config
          entry = { name: db.name, adapter: db.adapter, replica: db.replica }
          entry[:role]    = cfg.role.to_s if cfg.respond_to?(:role) && cfg.role

          pool_config = extract_pool_config(db.settings)
          entry[:pool_config] = pool_config if pool_config.any?

          adapter_opts = extract_adapter_options(db.settings)
          entry[:adapter_options] = adapter_opts if adapter_opts.any?
          entry
        rescue => e
          RailsAiContext.debug_fail(e, { name: db.name, error: e.message }, label: "extract_databases entry")
        end
      end

      POOL_KEYS = %w[pool checkout_timeout idle_timeout reaping_frequency].freeze
      ADAPTER_KEYS = %w[
        prepared_statements advisory_locks
        variables schema_search_path min_messages
        read_timeout write_timeout connect_timeout
        sslmode encoding collation timezone
      ].freeze

      def extract_pool_config(hash)
        POOL_KEYS.each_with_object({}) do |key, out|
          out[key.to_sym] = hash[key] if hash.key?(key)
        end
      end

      def extract_adapter_options(hash)
        ADAPTER_KEYS.each_with_object({}) do |key, out|
          next unless hash.key?(key)
          out[key.to_sym] = serializable(hash[key])
        end
      end

      def serializable(value)
        case value
        when Hash then value.transform_keys(&:to_s)
        when Array then value.map(&:to_s)
        when Symbol then value.to_s
        else value
        end
      end

      # Rails 6.1+ splits connection handling into the ConnectionHandler
      # registry. Report which roles have a handler registered.
      def detect_pool_handlers
        return [] unless ActiveRecord::Base.respond_to?(:connection_handler)
        handler = ActiveRecord::Base.connection_handler
        return [] unless handler.respond_to?(:connection_pool_list)

        %w[writing reading].filter_map do |role|
          { role: role, pool_count: handler.connection_pool_list(role.to_sym).size }
        rescue StandardError
          nil
        end
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_pool_handlers")
      end

      # Rails 7.1+ introduced ActiveRecord::Middleware::ShardSelector.
      # Detect via the middleware stack + initializer references.
      def detect_automatic_shard_selector
        return true if app.middleware.any? { |m| (m.name || m.klass.to_s).include?("ShardSelector") }
        PathResolver.initializer_paths(root).any? do |path|
          content = RailsAiContext::SafeFile.read(path) or next false
          content.include?("ShardSelector") || content.include?("connected_to role:")
        end
      rescue => e
        RailsAiContext.debug_fail(e, false, label: "detect_automatic_shard_selector")
      end
    end
  end
end
