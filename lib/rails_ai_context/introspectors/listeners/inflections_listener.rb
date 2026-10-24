# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # The rules an app gives ActiveSupport's inflector: each directive called
      # on the object `ActiveSupport::Inflector.inflections(locale)` yields,
      # whatever the block names it, or on that call's own result.
      #
      # Each hit carries `values` (a literal or the argument's source), its
      # `locale`, and `literals`, the arguments as Ruby values or nil when one is computed.
      class InflectionsListener < BaseListener
        DIRECTIVES = %i[acronym plural singular irregular uncountable human].to_set.freeze
        COMPUTED = Object.new.freeze
        private_constant :COMPUTED

        def initialize
          super
          @blocks = []
          @variables = {}
        end

        def on_call_node_enter(node)
          if inflections_block?(node)
            @blocks << { parameter: block_parameter(node.block), locale: locale(node) }
          elsif evaluated_block?(node)
            @blocks << { parameter: :self, locale: locale(node.receiver) }
          elsif DIRECTIVES.include?(node.name) && (scope = scope_of(node.receiver))
            @results << {
              method:   node.name.to_s,
              values:   extract_arg_values(node),
              literals: literals(node),
              locale:   scope[:locale],
              location: node.location.start_line
            }
          end
        end

        def on_call_node_leave(node)
          @blocks.pop if inflections_block?(node) || evaluated_block?(node)
        end

        # `inflect = ActiveSupport::Inflector.inflections(:en)`
        def on_local_variable_write_node_enter(node)
          @variables[node.name] = { locale: locale(node.value) } if inflections_call?(node.value) && node.value.block.nil?
        end

        private

        def inflections_call?(node)
          return false unless node.is_a?(Prism::CallNode) && node.name == :inflections

          receiver = node.receiver
          (receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)) &&
            %w[ActiveSupport::Inflector Inflector].include?(constant_path_string(receiver))
        end

        def inflections_block?(node)
          inflections_call?(node) && node.block.is_a?(Prism::BlockNode)
        end

        # `inflections(:en).instance_eval { acronym "PDF" }`
        def evaluated_block?(node)
          %i[instance_eval instance_exec].include?(node.name) && node.block.is_a?(Prism::BlockNode) &&
            inflections_call?(node.receiver) && node.receiver.block.nil?
        end

        def scope_of(receiver)
          return { locale: locale(receiver) } if inflections_call?(receiver) && receiver.block.nil?

          name = variable_name(receiver)
          name && (@blocks.reverse.find { |block| block[:parameter] == name } || @variables[name])
        end

        def variable_name(node)
          case node
          when nil, Prism::SelfNode then :self
          when Prism::LocalVariableReadNode then node.name
          when Prism::ItLocalVariableReadNode then :it
          end
        end

        def block_parameter(block)
          case (parameters = block.parameters)
          when Prism::BlockParametersNode
            required = parameters.parameters&.requireds&.first
            required.name if required.is_a?(Prism::RequiredParameterNode)
          when Prism::NumberedParametersNode then :_1
          when Prism::ItParametersNode then :it
          end
        end

        def locale(node)
          argument = node.arguments&.arguments&.first
          argument ? literal_string(argument)&.to_sym : :en
        end

        def literals(node)
          values = (node.arguments&.arguments || []).map { |argument| literal(argument) }
          values unless values.include?(COMPUTED)
        end

        def literal(node)
          case node
          when Prism::StringNode, Prism::SymbolNode then node.unescaped
          when Prism::RegularExpressionNode then Regexp.new(node.unescaped, regexp_options(node))
          when Prism::ArrayNode
            elements = node.elements.map { |element| literal(element) }
            elements.include?(COMPUTED) ? COMPUTED : elements
          else COMPUTED
          end
        rescue RegexpError
          COMPUTED
        end

        def regexp_options(node)
          (node.ignore_case? ? Regexp::IGNORECASE : 0) | (node.extended? ? Regexp::EXTENDED : 0) |
            (node.multi_line? ? Regexp::MULTILINE : 0)
        end
      end
    end
  end
end
