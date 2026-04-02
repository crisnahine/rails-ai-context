# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers API layer setup: api_only mode, serializers, GraphQL,
    # versioning patterns, rate limiting.
    class ApiIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          api_only: app.config.api_only,
          serializers: detect_serializers,
          graphql: detect_graphql,
          api_versioning: detect_versioning,
          rate_limiting: detect_rate_limiting,
          openapi_spec: detect_openapi_specs,
          cors_config: detect_cors_config,
          api_client_generation: detect_api_client_generation
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def detect_serializers
        result = {}

        # Jbuilder templates
        views_dir = File.join(root, "app/views")
        if Dir.exist?(views_dir)
          jbuilder_files = Dir.glob(File.join(views_dir, "**/*.jbuilder"))
          result[:jbuilder] = jbuilder_files.size if jbuilder_files.any?
        end

        # Serializer classes (Alba, Blueprinter, JSONAPI, etc.)
        serializers_dir = File.join(root, "app/serializers")
        if Dir.exist?(serializers_dir)
          files = Dir.glob(File.join(serializers_dir, "**/*.rb"))
          result[:serializer_classes] = files.map { |f| f.sub("#{serializers_dir}/", "").sub(/\.rb\z/, "").camelize }.sort
        end

        result
      end

      def detect_graphql
        graphql_dir = File.join(root, "app/graphql")
        return nil unless Dir.exist?(graphql_dir)

        types = Dir.glob(File.join(graphql_dir, "types/**/*.rb")).size
        mutations = Dir.glob(File.join(graphql_dir, "mutations/**/*.rb")).size
        queries = Dir.glob(File.join(graphql_dir, "queries/**/*.rb")).size

        { types: types, mutations: mutations, queries: queries }
      end

      def detect_versioning
        controllers_dir = File.join(root, "app/controllers")
        return [] unless Dir.exist?(controllers_dir)

        Dir.glob(File.join(controllers_dir, "api/v*/")).filter_map do |path|
          File.basename(path)
        end.sort
      end

      def detect_openapi_specs
        globs = %w[
          openapi/**/*.json openapi/**/*.yaml openapi/**/*.yml
          swagger/**/*.json swagger/**/*.yaml swagger/**/*.yml
          public/api-docs/**/*
          docs/**/*.json docs/**/*.yaml docs/**/*.yml
        ]

        globs.flat_map { |pattern| Dir.glob(File.join(root, pattern)) }
             .select { |path| File.file?(path) }
             .map { |path| path.sub("#{root}/", "") }
             .sort
             .uniq
      rescue => e
        $stderr.puts "[rails-ai-context] detect_openapi_specs failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def detect_cors_config
        cors_path = File.join(root, "config/initializers/cors.rb")
        return nil unless File.exist?(cors_path)

        content = File.read(cors_path)
        origins = content.scan(/origins\s+(.+)$/).flatten.flat_map do |line|
          line.scan(/["']([^"']+)["']/).flatten
        end

        { file: "config/initializers/cors.rb", origins: origins }
      rescue => e
        $stderr.puts "[rails-ai-context] detect_cors_config failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_api_client_generation
        package_path = File.join(root, "package.json")
        return [] unless File.exist?(package_path)

        content = File.read(package_path, encoding: "bom|utf-8")
        codegen_tools = %w[openapi-typescript @graphql-codegen/cli orval]

        codegen_tools.select { |tool| content.include?(%("#{tool}")) }
      rescue => e
        $stderr.puts "[rails-ai-context] detect_api_client_generation failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def detect_rate_limiting
        # Rack::Attack
        init_path = File.join(root, "config/initializers/rack_attack.rb")
        return { rack_attack: true } if File.exist?(init_path)

        # Rails 8 rate limiting
        controllers_dir = File.join(root, "app/controllers")
        if Dir.exist?(controllers_dir)
          Dir.glob(File.join(controllers_dir, "**/*.rb")).each do |path|
            content = File.read(path)
            return { rails_rate_limiting: true } if content.match?(/rate_limit\b/)
          rescue => e
            $stderr.puts "[rails-ai-context] detect_rate_limiting failed: #{e.message}" if ENV["DEBUG"]
            next
          end
        end

        {}
      end
    end
  end
end
