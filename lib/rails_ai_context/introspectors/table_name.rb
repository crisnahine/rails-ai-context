# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The table a model reads, for the static tier and for every reader that
    # only has a model name in hand.
    #
    # Rails builds it as prefix + demodulized name + suffix, unless the class
    # assigns one itself or inherits its parent's table as an STI child. The
    # prefix and the suffix are declared by an enclosing module, in a file that
    # is not the model's, so reading them takes a second source. This module
    # reads those declarations and holds the two derivations; who walks the
    # namespace and the superclass chain is the caller's business, because only
    # it knows the other files.
    #
    # It reads table_name, table_name_prefix, table_name_suffix,
    # pluralize_table_names and a literal `self.primary_key =`.
    module TableName
      module_function

      NONE = { table_name: nil, table_name_prefix: nil, table_name_suffix: nil, pluralize_table_names: nil, primary_key: nil }.freeze

      PREFIX_INDEX = Concurrent::Map.new
      AR_SETTINGS = Concurrent::Map.new

      # {"RssPolling" => "rss_polling_"}: the engine prefix no model file says.
      # ponytail: reads `lib/**/engine.rb` only; walk lib wholesale if an app needs more.
      def namespace_prefixes(root)
        root = File.expand_path(root.to_s)
        PREFIX_INDEX.compute_if_absent(root) { read_namespace_prefixes(root) }
      end

      # A table an option writes as that source (a habtm join_table), read the
      # way a table_name assignment is; nil for any other expression.
      def affixed(expression, own, root)
        statements = AstCache.parse_string(expression.to_s)&.value&.statements&.body
        statements&.size == 1 ? affixed_node(statements.first, own, root) : nil
      end

      def clear_namespace_prefixes
        PREFIX_INDEX.clear
        AR_SETTINGS.clear
      end

      # {table_name_prefix: "op_", schema_format: :sql}: what the app's config and initializers set on Active Record.
      def active_record_settings(root)
        return {} unless root

        root = File.expand_path(root.to_s)
        AR_SETTINGS.compute_if_absent(root) { read_active_record_settings(root) }
      end

      # All four declarations of one class body, read in one walk.
      #
      # @param source [String] the file's source
      # @param name [String] the qualified name of the class or module
      # @return [Hash] the four, each nil when this scope declares none
      # @param root [String, nil] the app, whose configured affixes a table
      #   name interpolating table_name_prefix or table_name_suffix reads
      def declarations(source, name, root = nil)
        read(source, name) do |body|
          own = { table_name_prefix: affix(body, :table_name_prefix), table_name_suffix: affix(body, :table_name_suffix) }
          { table_name: assigned(body, :table_name=) || interpolated(body, own, root) }.merge(own)
            .merge(pluralize_table_names: boolean_assigned(body, :pluralize_table_names=), primary_key: primary_key_assigned(body))
        end || NONE
      end

      # @return [String, nil] the table the class assigns itself, nil when it
      #   assigns none or computes one
      def explicit(source, class_name, root = nil)
        declarations(source, class_name, root)[:table_name]
      end

      # Rails derives the table through the app's own inflector, and the file's
      # name already carries that inflection - Zeitwerk resolved the constant
      # from it. Underscoring the constant instead turns OAuthClientConfig into
      # o_auth_client_configs, a table no app has.
      def stem(path, pluralize = true)
        base = File.basename(path.to_s, ".rb")
        pluralize ? base.pluralize : base
      end

      # The table a model name alone implies. The namespace is not part of it:
      # Rails demodulizes the name and lets table_name_prefix carry the
      # namespace, so `Admin::ActionLog` is `action_logs` until a prefix says
      # otherwise - never `admin/action_logs`.
      def derive(model_name)
        model_name.to_s.split("::").last.to_s.underscore.pluralize
      end

      # The class an association names, read as Rails' compute_type reads it:
      # a leading `::` is top level; otherwise the owner's own namespace, each
      # enclosing one, then top level. The block answers a candidate with the
      # model's spelling, or nil when no model has that name.
      def resolve_class(candidate, owner)
        name = candidate.to_s.delete_prefix("::")
        scope = candidate.to_s.start_with?("::") ? [] : owner.to_s.split("::")
        until scope.empty?
          hit = yield("#{scope.join('::')}::#{name}")
          return hit if hit

          scope.pop
        end
        yield(name) || name
      end

      # The model a derived name means, spelled the way the model set spells
      # it: `AiBuyerMatch` from a name is `AIBuyerMatch` where the app declares
      # the acronym. Nil when no model answers.
      def model_for(candidate, owner, models)
        index = models.keys.to_h { |key| [ key.to_s.downcase, key.to_s ] }
        found = resolve_class(candidate, owner) { |name| index[name.downcase] }
        found if index.key?(found.to_s.downcase)
      end

      # The table a caller's model name refers to: the one the model tier
      # recorded, which already knows the prefix and the STI parent, and the
      # convention only when no model answers to that name.
      #
      # @param models [Hash] the payload's models section
      def for_model_name(name, models = {})
        recorded = models.find do |model_name, details|
          model_name.to_s.casecmp?(name.to_s) && details.is_a?(Hash) && details[:table_name]
        end

        recorded ? recorded.last[:table_name] : derive(name)
      end

      def read_namespace_prefixes(root)
        engine_files(root).each_with_object({}) do |path, found|
          source = SafeFile.read(path, max_size: RailsAiContext.configuration.max_file_size)
          next unless source&.include?("isolate_namespace")

          isolated_namespaces(source).each do |namespace|
            found[namespace] ||= declarations(source, namespace)[:table_name_prefix] ||
                                 "#{namespace.underscore.tr('/', '_')}_"
          end
        end
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, {}, label: "namespace_prefixes")
      end

      SETTINGS = { table_name_prefix: String, table_name_suffix: String, pluralize_table_names: [ true, false ], schema_format: %i[ruby sql] }.freeze
      # ActiveRecord::Base's class attributes, ActiveRecord's module ones (schema_format), and self in the base's load hook.
      BASE_ROOTS = %w[ActiveRecord::Base ActiveRecord on_load(:active_record)].freeze

      # Rails reads config/application.rb, then the environment's file, then each initializer;
      # the last assignment wins, on config.active_record or on Active Record itself.
      def read_active_record_settings(root)
        files = [ File.join(root, "config", "application.rb"), File.join(root, "config", "environments", "#{RailsAiContext.environment_name}.rb") ]
        files = files.select { |path| File.file?(path) } + PathResolver.initializer_paths(root)
        listeners = { config: -> { Listeners::ConfigAssignmentListener.new }, base: -> { Listeners::ConfigAssignmentListener.new(BASE_ROOTS) } }
        files.each_with_object({}) do |file, found|
          walked = SourceIntrospector.walk(file, listeners)
          settings = Array(walked[:config]).filter_map { |entry| [ entry, entry[:path].last ] if entry[:path].size == 2 && entry[:path].first == :active_record } +
                     Array(walked[:base]).filter_map { |entry| [ entry, entry[:path].first ] if entry[:path].size == 1 }
          settings.sort_by { |entry, _| entry[:location] }.each do |entry, name|
            allowed = SETTINGS[name]
            next unless entry[:assignment] && allowed

            value = entry[:value]
            found[name] = value if allowed.is_a?(Array) ? allowed.include?(value) : value.is_a?(allowed)
          end
        end
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, {}, label: "active_record_settings")
      end

      def engine_files(root)
        roots = [ root ] + PathResolver.code_roots(root)
        roots.flat_map { |dir| Dir.glob(File.join(dir, "lib", "**", "engine.rb")) }.uniq.sort
      end

      # Every `isolate_namespace Foo::Bar` in the file, by the constant's own
      # spelling. A computed argument names nothing readable and is skipped.
      def isolated_namespaces(source)
        root = AstCache.parse_string(source)&.value
        return [] unless root

        calls = []
        collect_isolate_calls(root, calls)
        calls
      end

      def collect_isolate_calls(node, found)
        if node.is_a?(Prism::CallNode) && node.name == :isolate_namespace
          argument = node.arguments&.arguments&.first
          if argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)
            found << argument.slice.delete_prefix("::")
          end
        end
        node.child_nodes.compact.each { |child| collect_isolate_calls(child, found) }
      end

      def affix(body, name)
        assigned(body, :"#{name}=") || returned(body, name)
      end

      def read(source, name)
        return nil unless source && name

        root = AstCache.parse_string(source)&.value
        return nil unless root

        body = body_of(root, [], name.to_s)
        body && yield(body)
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, nil, label: "TableName")
      end

      # The statements of the class or module declared under this exact
      # qualified name, nil when the file declares no such scope.
      def body_of(node, scope, name)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          qualified = (scope + [ segment(node) ]).join("::")
          return statements(node) if qualified == name

          descend(node, scope + [ segment(node) ], name)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
          written = node.is_a?(Prism::ConstantWriteNode) ? node.name.to_s : node.target.slice.delete_prefix("::")
          return built_body(node.value) if (scope + [ written ]).join("::") == name

          descend(node, scope, name)
        else
          descend(node, scope, name)
        end
      end

      # `Name = Class.new(Base) do ... end` runs the block as Name's body.
      def built_body(value)
        return [] unless value.is_a?(Prism::CallNode) && value.name == :new && value.receiver&.slice == "Class"

        block = value.block
        block.is_a?(Prism::BlockNode) && block.body.is_a?(Prism::StatementsNode) ? block.body.body : []
      end

      def descend(node, scope, name)
        node.child_nodes.compact.each do |child|
          found = body_of(child, scope, name)
          return found if found
        end
        nil
      end

      def statements(node)
        node.body.is_a?(Prism::StatementsNode) ? node.body.body : []
      end

      def segment(node)
        node.constant_path.slice.delete_prefix("::")
      end

      # `self.table_name = "x"`, only in this scope's own body.
      def assigned(body, name)
        call = body.find do |node|
          node.is_a?(Prism::CallNode) && node.name == name && node.receiver.is_a?(Prism::SelfNode)
        end
        call && literal(call.arguments&.arguments)
      end

      # A name, or a composite key's names; nil for anything computed.
      def primary_key_assigned(body)
        call = body.find { |node| node.is_a?(Prism::CallNode) && node.name == :primary_key= && node.receiver.is_a?(Prism::SelfNode) }
        args = call&.arguments&.arguments
        return literal(args) unless args&.size == 1 && args.first.is_a?(Prism::ArrayNode)

        names = args.first.elements.map { |element| literal([ element ]) }
        names if names.all?
      end

      def boolean_assigned(body, name)
        call = body.find do |node|
          node.is_a?(Prism::CallNode) && node.name == name && node.receiver.is_a?(Prism::SelfNode)
        end
        args = call&.arguments&.arguments
        return nil unless args&.size == 1

        { Prism::TrueNode => true, Prism::FalseNode => false }[args.first.class]
      end

      # `self.table_name = "#{table_name_prefix}users#{table_name_suffix}"`: the class's
      # own affix, else the app's configured one.
      def interpolated(body, own, root)
        call = body.find do |node|
          node.is_a?(Prism::CallNode) && node.name == :table_name= && node.receiver.is_a?(Prism::SelfNode)
        end
        args = call&.arguments&.arguments
        args&.size == 1 ? affixed_node(args.first, own, root) : nil
      end

      def affixed_node(string, own, root)
        return nil unless string.is_a?(Prism::InterpolatedStringNode)

        string.parts.map do |part|
          next part.unescaped if part.is_a?(Prism::StringNode)

          key = affix_read(part) or return nil
          own[key] || active_record_settings(root)[key] || ""
        end.join
      end

      def affix_read(part)
        return nil unless part.is_a?(Prism::EmbeddedStatementsNode) && part.statements&.body&.size == 1

        call = part.statements.body.first
        return nil unless call.is_a?(Prism::CallNode) && call.arguments.nil? && call.block.nil?
        return nil unless call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode)

        call.name if %i[table_name_prefix table_name_suffix].include?(call.name)
      end

      # `def self.table_name_prefix; "x"; end` - the form Rails documents and
      # the one apps write. A method that computes its value answers nothing.
      def returned(body, name)
        node = body.find do |child|
          child.is_a?(Prism::DefNode) && child.name == name && child.receiver.is_a?(Prism::SelfNode)
        end
        node && literal(node.body.is_a?(Prism::StatementsNode) ? node.body.body : nil)
      end

      def literal(nodes)
        return nil unless nodes.is_a?(Array) && nodes.size == 1

        case (node = nodes.first)
        when Prism::StringNode, Prism::SymbolNode then node.unescaped
        end
      end

      private_class_method :affix, :read, :body_of, :built_body, :descend, :statements, :segment,
                           :assigned, :boolean_assigned, :primary_key_assigned, :returned, :literal, :read_namespace_prefixes, :read_active_record_settings,
                           :interpolated, :affixed_node, :affix_read,
                           :engine_files, :collect_isolate_calls
    end
  end
end
