# frozen_string_literal: true

require "uri"

module RailsAiContext
  module Introspectors
    # Discovers multi-database configuration: multiple databases, replicas,
    # sharding, and database-specific model assignments.
    class MultiDatabaseIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # @return [Hash] multi-database configuration
      def call
        dbs = discover_databases
        {
          databases: dbs,
          replicas: dbs.select { |d| d[:replica] }.map { |d| { name: d[:name], adapter: d[:adapter] } },
          sharding: detect_sharding,
          model_connections: detect_model_connections,
          multi_db: dbs.size > 1
        }.merge({ example_adapters: example_adapters }.compact)
      end

      private

      # Every app database; one the running environment does not configure names where it is configured.
      def discover_databases
        RailsAiContext::AppDatabases.for(root).map { |db| database_entry(db) }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "discover_databases")
      end

      # Adapters in the example database files of an app that commits none, read by line since
      # an example need not parse; a commented-out adapter does not count.
      def example_adapters
        return nil if File.exist?(File.join(root, "config/database.yml"))

        names = Dir.glob(File.join(root, "config/database.yml.*")).flat_map do |path|
          RailsAiContext::SafeFile.read(path).to_s.scan(/^\s*adapter:\s*["']?(\w+)["']?\s*(?:#.*)?$/).flatten
        end
        names.uniq.sort.presence
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "example_adapters")
      end

      def detect_sharding
        database_yml = File.join(root, "config/database.yml")
        return nil unless File.exist?(database_yml)

        content = RailsAiContext::SafeFile.read(database_yml)
        return nil unless content&.match?(/shard/i)

        result = { detected: true }
        # Extract shard names from database.yml (keep regex - YAML, not Ruby)
        shard_names = content.scan(/^\s{4,}(\w*shard\w*):/).flatten.uniq
        result[:shard_names] = shard_names if shard_names.any?

        # Extract shard config from model source via AST
        model_sources.each do |record|
          ast = SourceIntrospector.walk_source(record.source, {
            connects: -> { Listeners::GenericMacroListener.new(:connects_to) }
          })
          hit = ast[:connects].find { |h| h[:options][:shards].is_a?(Hash) }
          next unless hit

          shard_keys = hit[:options][:shards].keys.map(&:to_s)
          result[:shard_keys] = shard_keys if shard_keys.any?
          result[:shard_count] = shard_keys.size
          break
        end

        result
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "detect_sharding")
      end

      def detect_model_connections
        connections = []
        model_classes.each do |model_name, record|
          ast = SourceIntrospector.walk_source(record.source, {
            connects_to: -> { Listeners::ConditionalMacroListener.new(:connects_to) },
            connected_to: -> { Listeners::GenericMacroListener.new(:connected_to) }
          })

          if ast[:connects_to].any?
            hit = ast[:connects_to].first
            connects_to_text = hit[:options].map { |k, v| "#{k}: #{format_connects_value(v)}" }.join(", ")
            connections << { model: model_name, connects_to: connects_to_text, condition: hit[:condition] }.compact
          end

          if ast[:connected_to].any?
            connections << { model: model_name, uses_connected_to: true } unless connections.any? { |c| c[:model] == model_name }
          end
        rescue => e
          RailsAiContext.debug_fail(e, label: "detect_model_connections")
          next
        end

        connections.sort_by { |c| c[:model] }
      end

      def format_connects_value(value)
        case value
        when Hash
          "{ #{value.map { |k, v| "#{k}: #{format_connects_value(v)}" }.join(", ")} }"
        when Symbol
          ":#{value}"
        when Array
          "[#{value.map { |v| format_connects_value(v) }.join(", ")}]"
        else
          value.to_s
        end
      end

      def database_entry(db)
        info = { name: db.name, adapter: db.adapter }
        info[:adapter_default] = true if db.adapter_default
        database = db.config.database if db.config.respond_to?(:database)
        info[:database] = anonymize_db_name(database) if database
        info[:replica] = true if db.replica
        # Configured only in another environment, or only a committed dump names it.
        unless db.here
          db.environments.any? ? info[:environments] = db.environments : info[:dump_only] = true
        end
        info
      end

      def anonymize_db_name(name)
        return name unless name

        if name.start_with?("postgres://", "mysql://", "sqlite://")
          URI.parse(name).path.sub("/", "")
        else
          name
        end
      rescue => e
        RailsAiContext.debug_fail(e, "external", label: "anonymize_db_name")
      end
    end
  end
end
