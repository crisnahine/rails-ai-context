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
        jbuilder = PathResolver.view_dirs(root).sum { |dir| Dir.glob(File.join(dir, "**/*.jbuilder")).size }
        result[:jbuilder] = jbuilder if jbuilder > 0

        # Serializer classes (Alba, Blueprinter, JSONAPI, etc.). Named by the
        # class each file declares: camelizing the path asks the global
        # inflector, which the static tier never loaded the app's acronyms into.
        # A file that declares no class (a mixin, or one that did not parse) is
        # still a serializer file, so it keeps the name its path spells.
        names = SourceScan.each(root, kind: "app/serializers")
          .map { |record| DeclaredConstant.resolve(record.source, record.path_name) }.uniq.sort
        result[:serializer_classes] = names if names.any?

        # An app that keeps its own serializer layer somewhere else still has
        # one, and "none detected" pushed an agent to add jbuilder or a second
        # layer under app/serializers.
        other = other_serializer_dirs
        result[:serializer_dirs] = other if other.any?

        result
      end

      # Any `serializers` directory under app/ other than app/serializers
      # itself: `app/services/serializers/...` is the shape this missed.
      def other_serializer_dirs
        Dir.glob(File.join(root, "app", "**", "serializers"))
          .select { |path| File.directory?(path) }
          .map { |path| path.sub("#{root}/", "") }
          .reject { |relative| relative == "app/serializers" }
          .sort
          .map { |relative| { path: relative, files: Dir.glob(File.join(root, relative, "**", "*.rb")).size } }
          .reject { |entry| entry[:files].zero? }
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [], label: "other_serializer_dirs")
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
        RailsAiContext.debug_fail(e, [], label: "detect_openapi_specs")
      end

      # Per `allow` block, because that is the unit rack-cors applies: one
      # flat origin list read as though every origin reached every resource,
      # and an environment branch read as though all of its arms were live at
      # once.
      def detect_cors_config
        cors_path = File.join(root, "config/initializers/cors.rb")
        return nil unless File.exist?(cors_path)

        source = RailsAiContext::SafeFile.read(cors_path)
        node = source && AstCache.parse_string(source)&.value
        return nil unless node

        allows = []
        collect_allow_blocks(node, allows)
        origins = allows.flat_map { |allow| allow[:origins].map { |o| o[:value] } }.uniq
        return nil if origins.empty?

        { file: "config/initializers/cors.rb", origins: origins, allows: allows }
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "detect_cors_config")
      end

      def collect_allow_blocks(node, found)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::CallNode) && node.name == :allow && node.block
          entry = { origins: [], resources: [] }
          collect_cors_calls(node.block, entry, nil)
          found << entry if entry[:origins].any? || entry[:resources].any?
          return
        end

        node.compact_child_nodes.each { |child| collect_allow_blocks(child, found) }
      end

      def collect_cors_calls(node, entry, condition)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::IfNode
          predicate = one_line_source(node.predicate)
          collect_cors_calls(node.statements, entry, predicate)
          collect_cors_calls(node.subsequent, entry, "else #{predicate}")
          return
        when Prism::UnlessNode
          predicate = "not #{one_line_source(node.predicate)}"
          collect_cors_calls(node.statements, entry, predicate)
          collect_cors_calls(node.else_clause, entry, "else #{predicate}")
          return
        when Prism::CallNode
          if node.receiver.nil? && %i[origins resource].include?(node.name)
            values = Array(node.arguments&.arguments).flat_map { |arg| literal_strings(arg) }
            if node.name == :origins
              values.each { |value| entry[:origins] << { value: value, condition: condition }.compact }
            else
              entry[:resources] << values.first if values.first
            end
          end
        end

        node.compact_child_nodes.each { |child| collect_cors_calls(child, entry, condition) }
      end

      def literal_strings(node)
        case node
        when Prism::StringNode then [ node.unescaped ]
        when Prism::SymbolNode then [ node.value.to_s ]
        when Prism::ArrayNode  then node.elements.flat_map { |element| literal_strings(element) }
        else []
        end
      end

      def one_line_source(node)
        node ? node.slice.gsub(/\s+/, " ").strip : nil
      end

      def detect_api_client_generation
        package_path = File.join(root, "package.json")
        return [] unless File.exist?(package_path)

        codegen_tools = %w[openapi-typescript @graphql-codegen/cli orval]

        codegen_tools.select { |tool| RailsAiContext::PackageJson.present?(root, tool) }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_api_client_generation")
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
        RailsAiContext.debug_fail(e, nil, label: "extract_graphql_details")
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
        RailsAiContext.debug_fail(e, nil, label: "detect_pagination")
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
