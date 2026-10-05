# frozen_string_literal: true

require "json"

module RailsAiContext
  module Introspectors
    # Discovers API layer setup: api_only mode, serializers, GraphQL,
    # versioning patterns, rate limiting.
    class ApiIntrospector < Base
      extend StaticTier
      static_tier :alternate_source

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
      end

      # Whether the app configures CORS, as the cors_config entry decides it:
      # a commented-out initializer or a CORS-named file with no allow block does not.
      def cors_configured?
        config = detect_cors_config
        !config.nil? && !config[:commented_out]
      end

      private

      def detections
        {
          serializers: detect_serializers,
          graphql: detect_graphql,
          api_versioning: detect_versioning,
          api_versioning_dirs: version_dirs,
          rate_limiting: detect_rate_limiting,
          openapi_spec: detect_openapi_specs,
          cors_config: detect_cors_config,
          api_client_generation: detect_api_client_generation,
          graphql_details: extract_graphql_details,
          pagination: detect_pagination
        }
      end

      def detect_serializers
        result = {}

        PathResolver.view_dirs(root).each do |dir|
          { jbuilder: "**/*.jbuilder", rabl: "**/*.rabl" }.each do |key, pattern|
            count = Dir.glob(File.join(dir, pattern)).size
            result[key] = result.fetch(key, 0) + count if count > 0
          end
        end

        names = serializer_class_names
        result[:serializer_classes] = names if names.any?

        # An app that keeps its own serializer layer somewhere else still has
        # one, and "none detected" pushed an agent to add jbuilder or a second
        # layer under app/serializers.
        other = other_serializer_dirs
        result[:serializer_dirs] = other if other.any?

        result
      end

      # Where Blueprinter's generator and Alba's README put their classes; jsonapi-resources
      # uses app/resources too. A class there counts by what it is, since app/resources
      # is also a common home for unrelated code.
      SERIALIZER_KINDS = %w[app/serializers app/blueprints app/resources].freeze
      SERIALIZER_BASES = %w[
        Blueprinter::Base ActiveModel::Serializer Panko::Serializer JSONAPI::Resource
        JSONAPI::Serializable::Resource
      ].freeze
      SERIALIZER_MIXINS = %w[Alba::Resource JSONAPI::Serializer FastJsonapi::ObjectSerializer].freeze
      # Active Job's argument serializers live in app/serializers by the guide's own advice.
      JOB_ARGUMENT_SERIALIZER = "ActiveJob::Serializers::"

      # Named by the class each file declares: camelizing the path asks the global
      # inflector, which the static tier never loaded the app's acronyms into. A file
      # that declares no class (a mixin, or one that did not parse) is still a
      # serializer file in app/serializers, so it keeps the name its path spells.
      def serializer_class_names
        classes = SERIALIZER_KINDS.flat_map do |kind|
          SourceScan.each(root, kind: kind).map { |record| serializer_candidate(kind, record) }
        end
        framework = descendants_of(classes) do |c|
          SERIALIZER_BASES.include?(c[:superclass]) || (c[:includes] & SERIALIZER_MIXINS).any?
        end
        job_arguments = descendants_of(classes) { |c| c[:superclass].to_s.start_with?(JOB_ARGUMENT_SERIALIZER) }

        classes.filter_map { |c|
          next if job_arguments.include?(c[:name])

          c[:name] if c[:kind] == "app/serializers" || framework.include?(c[:name])
        }.uniq.sort
      end

      def serializer_candidate(kind, record)
        name = DeclaredConstant.resolve(record.source, record.path_name)
        own = DeclaredConstant.declarations(record.source).find { |d| d.name == name }
        includes = SourceIntrospector.walk_source(record.source, {
          includes: -> { Listeners::GenericMacroListener.new(:include) }
        })[:includes].flat_map { |hit| hit[:values].map { |v| v.to_s.delete_prefix("::") } }
        { kind: kind, name: name, superclass: own&.superclass&.delete_prefix("::"), includes: includes }
      end

      # The names the block picks, and every class that inherits one of them.
      def descendants_of(classes, &picks)
        found = classes.select(&picks).map { |c| c[:name] }.to_set
        loop do
          added = classes.select { |c| !found.include?(c[:name]) && found.include?(c[:superclass]) }
          break if added.empty?

          added.each { |c| found << c[:name] }
        end
        found
      end

      # Any `serializers` directory in any app tree the app has, other than
      # the `app/serializers` the classes above already came from.
      def other_serializer_dirs
        PathResolver.dirs_for(root, "app")
          .flat_map { |tree| Dir.glob(File.join(tree, "**", "serializers")) }
          .select { |path| File.directory?(path) }
          .map { |path| path.sub("#{root}/", "") }
          .reject { |relative| PathResolver.dirs_for(root, "app/serializers").include?(File.join(root, relative)) }
          .uniq
          .sort
          .map { |relative| { path: relative, files: serializer_files(relative).size } }
          .reject { |entry| entry[:files].zero? }
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [], label: "other_serializer_dirs")
      end

      # A directory named serializers also holds ActiveRecord attribute coders,
      # which serialize one column rather than a response.
      CODER_METHODS = %w[dump load].freeze

      def serializer_files(relative)
        Dir.glob(File.join(root, relative, "**", "*.rb")).reject { |path| attribute_coder?(path) }
      end

      def attribute_coder?(path)
        names = SourceIntrospector.walk(path, {
          methods: -> { Listeners::MethodsListener.new }
        })[:methods].map { |method| method[:name] }
        (CODER_METHODS - names).empty?
      rescue => e
        RailsAiContext.debug_fail(e, false, label: "attribute_coder?")
      end

      def detect_graphql
        graphql_dir = File.join(root, "app/graphql")
        return nil unless Dir.exist?(graphql_dir)

        result = { types: concrete_graphql_files(graphql_dir, "types"),
                   mutations: concrete_graphql_files(graphql_dir, "mutations") }
        result[:queries] = concrete_graphql_files(graphql_dir, "queries") if Dir.exist?(File.join(graphql_dir, "queries"))
        query_type = Dir.glob(File.join(graphql_dir, "**", "query_type.rb")).min
        query_root = query_type && query_root_fields(query_type)
        result[:query_root] = query_root if query_root
        result
      end

      # A class that names itself in the schema is part of it; any other inherited class
      # named like a base, or subclassing graphql-ruby itself, is the app's base.
      def concrete_graphql_files(graphql_dir, kind)
        declared = Dir.glob(File.join(graphql_dir, kind, "**", "*.rb")).to_h do |path|
          declarations = DeclaredConstant.declarations(RailsAiContext::SafeFile.read(path).to_s)
          [ path, DeclaredConstant.declaration_for(declarations, File.basename(path, ".rb").camelize) ]
        end
        inherited = declared.values.compact.filter_map { |d| d.superclass&.split("::")&.last }.uniq

        declared.count { |path, declaration| declaration.nil? || !base_class?(path, declaration, inherited) }
      end

      # What a class puts in the schema. Only `graphql_name` says the class is
      # itself a member: a base declares shared fields and arguments too.
      SCHEMA_MACROS = %i[graphql_name field value argument].freeze

      def base_class?(path, declaration, inherited)
        segment = declaration.name.split("::").last
        macros = schema_macros(path, segment)
        return false if macros.include?(:graphql_name)

        named_like_a_base = SuperclassChain.abstract_base_name?(segment)
        graphql_base = declaration.superclass.to_s.start_with?("GraphQL::")
        return named_like_a_base || graphql_base if inherited.include?(segment)

        # Nothing inherits it: a base is one that puts nothing in the schema.
        named_like_a_base && graphql_base && macros.empty?
      end

      # Read off the one class, not the file: a mutation base declares enums
      # of its own beside it, and their `graphql_name` is not the base's.
      def schema_macros(path, segment)
        calls = class_body_calls(AstCache.parse(path)&.value, segment)
        calls.map(&:name) & SCHEMA_MACROS
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "schema_macros")
      end

      # An app with no queries/ directory declares them on the query root, and
      # a macro there declares fields no static reader can count.
      def query_root_fields(path)
        calls = class_body_calls(AstCache.parse(path)&.value)
        fields = calls.count { |call| call.name == :field }

        entry = { file: path.sub("#{root}/", ""), fields: fields }
        entry[:macro_declared] = true if fields.zero? && calls.any? { |call| names_a_field?(call) }
        entry
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "query_root_fields")
      end

      # The class body's own calls, where `field` and app macros that declare several live.
      # `name` picks the class out of a multi-class file; without it, the first class.
      def class_body_calls(node, name = nil)
        return [] unless node.is_a?(Prism::Node)

        klass = find_class_node(node, name) or return []
        Array(klass.body&.body).select { |child| child.is_a?(Prism::CallNode) && child.receiver.nil? }
      end

      def find_class_node(node, name = nil)
        return node if node.is_a?(Prism::ClassNode) && (name.nil? || node.constant_path.slice.split("::").last == name)

        node.compact_child_nodes.filter_map { |child| find_class_node(child, name) }.first
      end

      # A macro that takes a field name, `collection_and_object_by_id_fields
      # :budget` and the like, rather than `include` or `extend`.
      def names_a_field?(call)
        Array(call.arguments&.arguments).first.is_a?(Prism::SymbolNode)
      end

      def detect_versioning
        version_dirs.map { |path| File.basename(path) }.uniq.sort
      end

      # A Grape app keeps its versions outside app/controllers (lib/api/v3, app/api/v1).
      def version_dirs
        dirs = RailsAiContext::PathResolver.controller_dirs(root)
          .flat_map { |controllers_dir| Dir.glob(File.join(controllers_dir, "api/v*/")) }
        dirs += Dir.glob(File.join(root, "{app,lib}/api/v*/"))
        dirs.map { |path| path.chomp("/").sub("#{root}/", "") }.uniq.sort
      end

      # Where apps keep a spec: rswag's swagger/, a docs site, public/ for a served spec,
      # and app/ beside a Grape or versioned API.
      OPENAPI_GLOBS = %w[
        *.{json,yaml,yml} {openapi,swagger,doc,docs,public,app,config}/**/*.{json,yaml,yml}
      ].freeze
      OPENAPI_YAML_KEY = /^["']?(?:openapi|swagger)["']?[ \t]*:/
      OPENAPI_SKIP = %r{(?:\A|/)(?:node_modules|packs|assets|vite)/}

      # A file is a spec by its top-level `openapi` or `swagger` key, never by where it is.
      def detect_openapi_specs
        OPENAPI_GLOBS.flat_map { |pattern| Dir.glob(pattern, base: root.to_s) }
          .uniq.reject { |relative| relative.match?(OPENAPI_SKIP) }
          .select { |relative| openapi_document?(relative) }
          .sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_openapi_specs")
      end

      def openapi_document?(relative)
        source = SafePath.read(relative, under: root.to_s).first
        return false unless source&.match?(/openapi|swagger/)
        return source.match?(OPENAPI_YAML_KEY) unless relative.end_with?(".json")

        parsed = JSON.parse(source)
        parsed.is_a?(Hash) && (parsed.key?("openapi") || parsed.key?("swagger"))
      rescue JSON::ParserError
        false
      end

      # Per `allow` block, because that is the unit rack-cors applies: one
      # flat origin list read as though every origin reached every resource,
      # and an environment branch read as though all of its arms were live at
      # once.
      def detect_cors_config
        cors_path = PathResolver.initializer_files(root, "cors").first
        return nil unless cors_path

        source = RailsAiContext::SafeFile.read(cors_path)
        parsed = source && AstCache.parse_string(source)
        node = parsed&.value
        return nil unless node

        allows = []
        inserts = []
        collect_allow_blocks(node, allows, inserts)
        origins = allows.flat_map { |allow| allow[:origins].map { |o| o[:value] } }.uniq

        # The name match is a CORS config only when it configures CORS: a block,
        # an inserted middleware, or either of those left commented out.
        commented_out = allows.empty? && inserts.empty? && node.statements.body.empty? &&
                        commented_cors?(parsed.comments)
        return nil if allows.empty? && inserts.empty? && !commented_out

        entry = { file: cors_path.sub("#{root}/", ""), origins: origins, allows: allows }
        entry[:inserts] = inserts.uniq if inserts.any?
        entry[:commented_out] = true if commented_out
        entry
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "detect_cors_config")
      end

      # Vocabulary regex over comment text: the generated file arrives fully
      # commented out, and so does one whose allow block is switched off.
      def commented_cors?(comments)
        comments.any? { |comment| comment.slice.match?(/Rack::Cors|allow do/) }
      end

      # An app can do CORS from this file with a middleware of its own rather
      # than a rack-cors `allow` block.
      MIDDLEWARE_INSERTS = %i[use insert insert_before insert_after unshift swap].freeze

      def collect_allow_blocks(node, found, inserts)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::CallNode) && node.name == :allow && node.block
          entry = { origins: [], resources: [] }
          collect_cors_calls(node.block, entry, nil)
          found << entry if entry[:origins].any? || entry[:resources].any?
          return
        end

        inserts << inserted_middleware(node) if middleware_insert?(node)
        node.compact_child_nodes.each { |child| collect_allow_blocks(child, found, inserts) }
      end

      def middleware_insert?(node)
        node.is_a?(Prism::CallNode) && MIDDLEWARE_INSERTS.include?(node.name) &&
          node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :middleware &&
          inserted_middleware(node)
      end

      # The stack position comes first and the middleware last, in every verb
      # that takes both.
      def inserted_middleware(node)
        constant = Array(node.arguments&.arguments).select { |arg| arg.is_a?(Prism::ConstantReadNode) || arg.is_a?(Prism::ConstantPathNode) }.last
        constant && one_line_source(constant)
      end

      def collect_cors_calls(node, entry, condition)
        return unless node.is_a?(Prism::Node)

        case node
        # An `else` is the branch none of the conditions picked, however many
        # `elsif`s came before it; an `elsif` names its own condition.
        when Prism::IfNode
          collect_cors_calls(node.statements, entry, one_line_source(node.predicate))
          collect_cors_calls(node.subsequent, entry, :otherwise)
          return
        when Prism::UnlessNode
          collect_cors_calls(node.statements, entry, "not #{one_line_source(node.predicate)}")
          collect_cors_calls(node.else_clause, entry, :otherwise)
          return
        when Prism::CallNode
          if node.receiver.nil? && %i[origins resource].include?(node.name)
            args = Array(node.arguments&.arguments)
            if node.name == :origins
              origin_entries(node, args).each { |origin| entry[:origins] << with_condition(origin, condition) }
            else
              value = args.flat_map { |arg| literal_values(arg) }.first || one_line_source(args.first)
              entry[:resources] << value if value
            end
          end
        end

        node.compact_child_nodes.each { |child| collect_cors_calls(child, entry, condition) }
      end

      def with_condition(origin, condition)
        return origin.merge(otherwise: true) if condition == :otherwise

        origin.merge({ condition: condition }.compact)
      end

      # An origin list the file computes - a block rack-cors calls per request,
      # or an expression read at boot - is still a configured list.
      def origin_entries(node, args)
        if node.block
          return [ { value: "a block", computed: true,
                     echoes_request_origin: echoes_request_origin?(node.block) }.compact ]
        end

        args.flat_map do |arg|
          values = literal_values(arg)
          values.any? ? values.map { |value| { value: value } } : [ { value: one_line_source(arg), computed: true } ]
        end
      end

      # `origins { |source, _env| source }` allows every origin.
      def echoes_request_origin?(block)
        return false unless block.is_a?(Prism::BlockNode)

        first_param = block.parameters&.parameters&.requireds&.first
        return false unless first_param.respond_to?(:name)

        # The whole body, not its last line: a block that filters first and
        # echoes second allows the origins it let through, not every origin.
        body = Array(block.body&.body)
        body.size == 1 && body.first.is_a?(Prism::LocalVariableReadNode) && body.first.name == first_param.name
      end

      def literal_values(node)
        case node
        when Prism::StringNode, Prism::SymbolNode then [ node.unescaped ]
        when Prism::ArrayNode then node.elements.flat_map { |element| literal_values(element) }
        else []
        end
      end

      def one_line_source(node)
        node ? NodeSource.text(node).gsub(/\s+/, " ").strip : nil
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
        init_path = PathResolver.initializer_files(root, "rack_attack").first
        return { rack_attack: true, file: init_path.sub("#{root}/", "") } if init_path

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
