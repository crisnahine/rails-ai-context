# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Class-body macros that define a constructor: T::Struct's const/prop,
      # Dry::Struct's attribute, dry-initializer's param/option and the
      # attr_extras initializers. Each record carries the parameters the macro
      # adds, as [kind, name, default source], and the class it is written in.
      # Whether the macro is that library's is the consumer's call: `attribute`
      # is also ActiveModel's.
      class ConstructorMacroListener < GenericMacroListener
        include OwnerScope

        STRUCT_MACROS = %i[const prop attribute attribute?].freeze
        DRY_INITIALIZER_MACROS = %i[param option].freeze
        ATTR_EXTRAS_MACROS = %i[
          attr_initialize pattr_initialize vattr_initialize rattr_initialize aattr_initialize
          attr_private_initialize attr_value_initialize attr_reader_initialize attr_accessor_initialize
          method_object static_facade
        ].freeze

        def initialize
          super(STRUCT_MACROS + DRY_INITIALIZER_MACROS + ATTR_EXTRAS_MACROS + %i[extend])
        end

        def on_call_node_enter(node)
          count = @results.size
          super
          @results[count..].each do |record|
            record[:owner] = @owner_stack.dup
            record[:source] = one_line_source(node)
            record[:params] = params_for(node)
          end
        end

        private

        def params_for(node)
          args = Array(node.arguments&.arguments)
          case node.name
          when :const, :prop then struct_param(args)
          when :attribute, :attribute? then dry_struct_param(node.name, args)
          when :param, :option then dry_initializer_param(node.name, args)
          when :extend then []
          else attr_extras_params(node.name == :static_facade ? args.drop(1) : args)
          end
        end

        # A T::Struct prop is optional with a default, a factory, or a nilable type.
        def struct_param(args)
          name = literal_string(args.first) or return []
          options = keyword_nodes(args)
          default = options[:default] || options[:factory]
          return [ [ :key, name, default_text(default) ] ] if default
          return [ [ :key, name, "nil" ] ] if args[1] && !args[1].is_a?(Prism::KeywordHashNode) && args[1].slice.start_with?("T.nilable(")

          [ [ :keyreq, name, nil ] ]
        end

        def dry_struct_param(macro, args)
          name = literal_string(args.first) or return []
          return [ [ :key, name, "nil" ] ] if macro == :attribute?

          default = type_default(args[1])
          default ? [ [ :key, name, default ] ] : [ [ :keyreq, name, nil ] ]
        end

        # `Types::String.default("USD")`, anywhere in the type's call chain.
        def type_default(node)
          while node.is_a?(Prism::CallNode)
            return default_text(node.arguments&.arguments&.first) || "..." if node.name == :default

            node = node.receiver
          end
          nil
        end

        def dry_initializer_param(macro, args)
          name = literal_string(args.first) or return []
          options = keyword_nodes(args)
          default = (default_text(options[:default]) if options[:default]) ||
                    ("nil" if options[:optional].is_a?(Prism::TrueNode))
          positional = macro == :param
          kind = positional ? (default ? :opt : :req) : (default ? :key : :keyreq)
          [ [ kind, name, default ] ]
        end

        # Symbols are positional; an array holds keywords, `name!` required.
        def attr_extras_params(args)
          args.flat_map do |arg|
            if arg.is_a?(Prism::ArrayNode)
              arg.elements.flat_map { |element| attr_extras_keywords(element) }
            else
              name = literal_string(arg)
              name ? [ [ :req, name, nil ] ] : []
            end
          end
        end

        def attr_extras_keywords(element)
          if element.is_a?(Prism::KeywordHashNode) || element.is_a?(Prism::HashNode)
            return element.elements.grep(Prism::AssocNode).filter_map do |assoc|
              key = literal_string(assoc.key)
              [ :key, key, assoc.value.slice ] if key
            end
          end

          name = literal_string(element) or return []
          name.end_with?("!") ? [ [ :keyreq, name.delete_suffix("!"), nil ] ] : [ [ :key, name, "nil" ] ]
        end

        def keyword_nodes(args)
          args.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
              .each_with_object({}) { |assoc, found| found[extract_key(assoc.key)] = assoc.value }
        end

        # A lambda default reads as the value it returns.
        def default_text(node)
          return nil unless node

          body = node.body if node.is_a?(Prism::LambdaNode)
          body = node.block.body if node.is_a?(Prism::CallNode) && %i[lambda proc].include?(node.name) && node.block.is_a?(Prism::BlockNode)
          statements = body.is_a?(Prism::StatementsNode) ? body.body : []
          statements.size == 1 ? statements.first.slice : node.slice
        end
      end
    end
  end
end
