# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers API layer setup: api_only mode, serializers, GraphQL,
    # versioning patterns, rate limiting.
    class ApiIntrospector
      extend StaticTier
      static_tier :alternate_source

      attr_reader :app

      def initialize(app)
        @app = app
      end

      # Only the mode differs between the tiers: `config.api_only` is a
      # runtime read, and the assignment it comes from is in
      # config/application.rb, which is what AppKind reads.
      def static_call
        { api_only: AppKind.api_only?(app.root) }.merge(detections)
      rescue StandardError
        { unavailable: StaticTier.unavailable_reason }
      end

      def call
        { api_only: app.config.api_only }.merge(detections)
      rescue => e
        { error: e.message }
      end

      private

      def detections
        {
          serializers: detect_serializers,
          graphql: detect_graphql,
          api_versioning: detect_versioning,
          rate_limiting: detect_rate_limiting,
          openapi_spec: detect_openapi_specs,
          cors_config: detect_cors_config,
          api_client_generation: detect_api_client_generation,
          graphql_details: extract_graphql_details,
          pagination: detect_pagination
        }
      end

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
        RailsAiContext::PathResolver.controller_dirs(root).flat_map do |controllers_dir|
          Dir.glob(File.join(controllers_dir, "api/v*/")).map { |path| File.basename(path) }
        end.uniq.sort
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

        ast_data = SourceIntrospector.walk(cors_path, {
          origins: -> { Listeners::GenericMacroListener.new(:origins) }
        })

        origin_calls = ast_data[:origins]
        return nil if origin_calls.empty?

        origins = origin_calls.flat_map { |macro| macro[:values].flatten.map(&:to_s) }

        { file: "config/initializers/cors.rb", origins: origins }
      rescue => e
        $stderr.puts "[rails-ai-context] detect_cors_config failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_api_client_generation
        package_path = File.join(root, "package.json")
        return [] unless File.exist?(package_path)

        content = RailsAiContext::SafeFile.read(package_path)
        return [] unless content
        codegen_tools = %w[openapi-typescript @graphql-codegen/cli orval]

        codegen_tools.select { |tool| content.include?(%("#{tool}")) }
      rescue => e
        $stderr.puts "[rails-ai-context] detect_api_client_generation failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_graphql_details
        graphql_dir = File.join(app.root, "app", "graphql")
        return nil unless Dir.exist?(graphql_dir)

        details = {}
        details[:resolvers] = Dir.glob(File.join(graphql_dir, "**", "*resolver*")).map { |f| File.basename(f, ".rb").camelize }
        details[:subscriptions] = Dir.glob(File.join(graphql_dir, "**", "subscriptions", "*.rb")).map { |f| File.basename(f, ".rb").camelize }
        details[:dataloaders] = Dir.glob(File.join(graphql_dir, "**", "{loaders,dataloaders}", "*.rb")).map { |f| File.basename(f, ".rb").camelize }
        details.reject { |_, v| v.empty? }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_graphql_details failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_pagination
        lock = RailsAiContext::GemLock.for(app.root)
        return nil if lock.missing?

        strategies = []
        strategies << "pagy" if lock.present?("pagy")
        strategies << "kaminari" if lock.present?("kaminari")
        strategies << "will_paginate" if lock.present?("will_paginate")
        strategies << "cursor" if lock.present?("graphql-pro") # cursor-based pagination
        strategies.empty? ? nil : strategies
      rescue => e
        $stderr.puts "[rails-ai-context] detect_pagination failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_rate_limiting
        # Rack::Attack
        init_path = File.join(root, "config/initializers/rack_attack.rb")
        return { rack_attack: true } if File.exist?(init_path)

        # Rails 8 rate limiting - use AST to detect rate_limit macro calls
        SourceScan.each(root, kind: "app/controllers").each do |record|
          ast_data = SourceIntrospector.walk_source(record.source, {
            rate_limit: -> { Listeners::GenericMacroListener.new(:rate_limit) }
          })
          return { rails_rate_limiting: true } if ast_data[:rate_limit].any?
        end

        {}
      end
    end
  end
end
