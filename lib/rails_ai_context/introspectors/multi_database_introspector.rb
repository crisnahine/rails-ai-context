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

        content = File.read(database_yml)
        { detected: true, note: "Sharding configuration found in database.yml" } if content.match?(/shard/i)
      rescue => e
        $stderr.puts "[rails-ai-context] detect_sharding failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_model_connections
        models_dir = File.join(root, "app/models")
        return [] unless Dir.exist?(models_dir)

        connections = []
        Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
          content = File.read(path)
          model_name = File.basename(path, ".rb").camelize

          if (match = content.match(/connects_to\s+(.*?\n(?:\s+.*\n)*)/m))
            connects_to_text = match[1].strip.gsub(/\s+/, " ")
            connections << {
              model: model_name,
              connects_to: connects_to_text
            }
          end

          if content.match?(/connected_to\b/)
            connections << { model: model_name, uses_connected_to: true } unless connections.any? { |c| c[:model] == model_name }
          end
        rescue => e
          $stderr.puts "[rails-ai-context] detect_model_connections failed: #{e.message}" if ENV["DEBUG"]
          next
        end

        connections.sort_by { |c| c[:model] }
      end

      def parse_database_yml
        path = File.join(root, "config/database.yml")
        return [] unless File.exist?(path)

        content = File.read(path)
        databases = []
        current_env = defined?(Rails) ? Rails.env : "development"
        in_env = false
        skip_keys = %w[adapter database host port username password encoding pool timeout socket url]

        content.each_line do |line|
          if line.match?(/\A#{current_env}:/)
            in_env = true
            next
          elsif line.match?(/\A\w+:/) && in_env
            break
          end

          next unless in_env

          if line.match?(/\A\s{2}(\w+):/) && !line.include?("<<")
            db_name = line.strip.chomp(":")
            databases << { name: db_name } unless skip_keys.include?(db_name)
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
