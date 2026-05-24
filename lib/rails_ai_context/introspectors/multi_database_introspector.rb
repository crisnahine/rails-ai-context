# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers multi-database configuration: multiple databases, replicas,
    # sharding, and database-specific model assignments.
    class MultiDatabaseIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] multi-database configuration
      def call
        dbs = discover_databases
        {
          databases: dbs,
          replicas: discover_replicas,
          sharding: detect_sharding,
          model_connections: detect_model_connections,
          multi_db: dbs.size > 1
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def discover_databases
        if defined?(ActiveRecord::Base)
          configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
          configs.map do |config|
            info = { name: config.name, adapter: config.adapter }
            info[:database] = anonymize_db_name(config.database) if config.database
            info[:replica] = true if config.respond_to?(:replica?) && config.replica?
            info
          end
        else
          parse_database_yml
        end
      rescue => e
        $stderr.puts "[rails-ai-context] discover_databases failed: #{e.message}" if ENV["DEBUG"]
        parse_database_yml
      end

      def discover_replicas
        if defined?(ActiveRecord::Base)
          configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
          configs.select { |c| c.respond_to?(:replica?) && c.replica? }.map do |config|
            { name: config.name, adapter: config.adapter }
          end
        else
          []
        end
      rescue => e
        $stderr.puts "[rails-ai-context] discover_replicas failed: #{e.message}" if ENV["DEBUG"]
        []
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
        models_dir = File.join(root, "app/models")
        if Dir.exist?(models_dir)
          Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
            ast = SourceIntrospector.walk(path, {
              connects: -> { Listeners::GenericMacroListener.new(:connects_to) }
            })
            hit = ast[:connects].find { |h| h[:options][:shards].is_a?(Hash) }
            next unless hit

            shard_keys = hit[:options][:shards].keys.map(&:to_s)
            result[:shard_keys] = shard_keys if shard_keys.any?
            result[:shard_count] = shard_keys.size
            break
          end
        end

        result
      rescue => e
        $stderr.puts "[rails-ai-context] detect_sharding failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_model_connections
        models_dir = File.join(root, "app/models")
        return [] unless Dir.exist?(models_dir)

        connections = []
        Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
          model_name = File.basename(path, ".rb").camelize

          ast = SourceIntrospector.walk(path, {
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
          $stderr.puts "[rails-ai-context] detect_model_connections failed: #{e.message}" if ENV["DEBUG"]
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

      def parse_database_yml
        path = File.join(root, "config/database.yml")
        return [] unless File.exist?(path)

        content = RailsAiContext::SafeFile.read(path)
        return [] unless content
        databases = []
        current_env = defined?(Rails) ? Rails.env : "development"
        in_env = false
        skip_keys = %w[adapter database host port username password encoding pool timeout socket url replica]
        current_db = nil

        content.each_line do |line|
          if line.match?(/\A#{Regexp.escape(current_env)}:/)
            in_env = true
            next
          elsif line.match?(/\A\w+:/) && in_env
            break
          end

          next unless in_env

          # 2-space indent = database name (primary, cache, etc.) or flat config key
          if (match = line.match(/\A\s{2}(\w+):\s*(.*)/)) && !line.include?("<<")
            key = match[1]
            value = match[2].strip
            if skip_keys.include?(key)
              # Flat config (single-db): extract adapter/database inline
              if key == "adapter" && databases.empty?
                databases << { name: "primary", adapter: value }
              end
            else
              # This is a named database (multi-db config)
              current_db = { name: key }
              databases << current_db
            end
          # 4-space indent = settings under a named database
          elsif current_db && (match = line.match(/\A\s{4}(\w+):\s*(.*)/))
            key = match[1]
            value = match[2].strip
            current_db[:adapter] = value if key == "adapter"
            current_db[:replica] = true if key == "replica" && value == "true"
          end
        end

        databases
      rescue => e
        $stderr.puts "[rails-ai-context] parse_database_yml failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def anonymize_db_name(name)
        return name unless name

        if name.start_with?("postgres://", "mysql://", "sqlite://")
          URI.parse(name).path.sub("/", "")
        else
          name
        end
      rescue => e
        $stderr.puts "[rails-ai-context] anonymize_db_name failed: #{e.message}" if ENV["DEBUG"]
        "external"
      end
    end
  end
end
