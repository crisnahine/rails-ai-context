# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers multi-database configuration: multiple databases, replicas,
    # sharding, and database-specific model assignments.
    class MultiDatabaseIntrospector < Base
      extend StaticTier
      static_tier :files_only

      ERB_SENTINEL = RailsAiContext::DatabaseYml::ERB_SENTINEL

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

      def discover_databases
        booted = booted_databases
        # A boot that failed leaves the handlers empty without raising, and an
        # app that declares two databases is not an app with none.
        booted.any? ? booted : file_databases
      rescue => e
        RailsAiContext.debug_fail(e, file_databases, label: "discover_databases")
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
        SourceScan.each(root, kind: "app/models").each do |record|
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
        SourceScan.classes(root, kind: "app/models").each do |model_name, record|
          ast = SourceIntrospector.walk_source(record.source, {
            connects_to: -> { Listeners::GenericMacroListener.new(:connects_to) },
            connected_to: -> { Listeners::GenericMacroListener.new(:connected_to) }
          })

          if ast[:connects_to].any?
            hit = ast[:connects_to].first
            connects_to_text = hit[:options].map { |k, v| "#{k}: #{format_connects_value(v)}" }.join(", ")
            connections << { model: model_name, connects_to: connects_to_text }
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

      def booted_databases
        return [] unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, include_hidden: true).map do |config|
          info = { name: config.name, adapter: config.adapter }
          info[:database] = anonymize_db_name(config.database) if config.database
          info[:replica] = true if config.respond_to?(:replica?) && config.replica?
          info
        end
      end

      # Read as YAML so anchors, merge keys and comments follow the file format itself.
      def file_databases
        config = database_yml_env
        return [] unless config.is_a?(Hash) && config.any?

        # Rails' own rule: an env whose values are all Hashes names one
        # database per key, anything else is a single primary config.
        if config.values.all? { |value| value.is_a?(Hash) }
          config.map { |name, entry| database_entry(name, entry) }
        else
          [ database_entry("primary", config) ]
        end
      end

      def database_entry(name, entry)
        adapter, from_default = adapter_value(entry["adapter"])
        info = { name: name.to_s, adapter: adapter }
        info[:adapter_default] = true if from_default
        info[:replica] = true if entry["replica"] == true
        info
      end

      # An ERB-computed value is unknown, unless the whole value is one tag carrying its own
      # literal default, which the sentinel keeps; two tags compose into something neither said.
      def adapter_value(value)
        return [ nil, false ] if value.nil?

        text = value.to_s
        return [ text, false ] unless text.include?(ERB_SENTINEL)
        return [ nil, false ] unless text.start_with?(ERB_SENTINEL) && text.scan(ERB_SENTINEL).size == 1

        literal = text.delete_prefix(ERB_SENTINEL)
        literal.empty? ? [ nil, false ] : [ literal, true ]
      end

      def database_yml_env
        RailsAiContext::DatabaseYml.env(root)
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
