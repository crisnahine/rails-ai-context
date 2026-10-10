# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects `scope :name, -> { ... }` declarations via Prism AST.
      class ScopesListener < BaseListener
        include WithOptionsScope
        include OwnerScope

        # `scope :x, lambda { ... }` and `scope :x do ... end` hold their body
        # in a block, not in a LambdaNode.
        LAMBDA_METHODS = %i[lambda proc].to_set.freeze

        # A block these run once per element of the list they are sent to.
        LOOPS = %i[each each_with_index].to_set.freeze

        def initialize
          super
          @lists = {}
          @loops = []
        end

        def on_call_node_enter(node)
          enter_loop(node)
          return record_default_scope(node) if node.name == :default_scope && in_scope?(node)
          return unless node.name == :scope && in_scope?(node)

          name = extract_first_symbol(node)
          names = name == "[INFERRED]" ? loop_names(node.arguments&.arguments&.first) : [ name ]
          return unless names

          callable = scope_body_node(node)
          body = callable ? lambda_body_source(callable) : nil

          names.each do |scope_name|
            @results << {
              name:            scope_name.to_s,
              body:            body,
              required_params: callable ? lambda_required_params(callable) : [],
              location:        node.location.start_line,
              # A lambda body sliced verbatim from source IS the scope's ground
              # truth; only scopes whose body can't be extracted (block form,
              # metaprogrammed) are heuristic, and so is a name a loop gives.
              confidence:      body && name != "[INFERRED]" ? Confidence::VERIFIED : Confidence::INFERRED,
              owner:           @owner_stack.dup
            }
          end
        end

        def on_call_node_leave(node)
          @loops.pop if @loops.last && @loops.last[:node].equal?(node)
          super if defined?(super)
        end

        # A list a loop below can name by its constant.
        def on_constant_write_node_enter(node)
          values = literal_list(node.value)
          @lists[node.name] = values if values
          super
        end

        # Rails calls a `def self.default_scope` the model defines, as it does the macro's lambda.
        def on_def_node_enter(node)
          own = node.receiver.is_a?(Prism::SelfNode) || (node.receiver.nil? && @singleton_depth.to_i.positive?)
          if own && node.name == :default_scope && node.body
            @results << { name: "default_scope", default: true, body: one_line_source(node.body),
                          location: node.location.start_line, confidence: Confidence::VERIFIED, owner: @owner_stack.dup }
          end
          super if defined?(super)
        end

        def on_singleton_class_node_enter(_node)
          @singleton_depth = @singleton_depth.to_i + 1
        end

        def on_singleton_class_node_leave(_node)
          @singleton_depth -= 1
        end

        private

        # `KINDS.each { |kind| scope kind, -> { where(kind: kind) } }` declares a
        # scope per element. Over a literal list - written inline, or a constant
        # this file assigns one - the names are known before anything runs.
        def enter_loop(node)
          return unless LOOPS.include?(node.name) && node.arguments.nil? && node.block.is_a?(Prism::BlockNode)

          param = node.block.parameters&.parameters&.requireds&.first
          return unless param.is_a?(Prism::RequiredParameterNode)

          receiver = node.receiver
          values = receiver.is_a?(Prism::ConstantReadNode) ? @lists[receiver.name] : literal_list(receiver)
          @loops.push({ node: node, param: param.name, values: values }) if values
        end

        # `%w[a b]`, `%i[a b]` or `[:a, "b"]`, frozen or not; nil for anything else.
        def literal_list(node)
          node = node.receiver while node.is_a?(Prism::CallNode) && node.name == :freeze && node.arguments.nil? && node.receiver
          return nil unless node.is_a?(Prism::ArrayNode)

          values = node.elements.map { |element| literal_string(element) }
          values unless values.any?(&:nil?)
        end

        # One name per element of the innermost loop the name reads, or nil when it reads none.
        def loop_names(arg)
          @loops.reverse_each do |loop|
            names = loop[:values].map { |value| loop_name(arg, loop[:param], value) }
            return names.uniq unless names.any?(&:nil?)
          end
          nil
        end

        # The name an element gives: the block's variable as written, `.to_sym`'d,
        # or interpolated into a symbol or a string.
        def loop_name(arg, param, value)
          case arg
          when Prism::LocalVariableReadNode
            value if arg.name == param
          when Prism::CallNode
            loop_name(arg.receiver, param, value) if %i[to_sym to_s intern].include?(arg.name) && arg.arguments.nil?
          when Prism::InterpolatedSymbolNode, Prism::InterpolatedStringNode
            parts = arg.parts.map do |part|
              next part.unescaped if part.is_a?(Prism::StringNode)

              statements = part.statements&.body if part.is_a?(Prism::EmbeddedStatementsNode)
              loop_name(statements.first, param, value) if statements&.size == 1
            end
            parts.join unless parts.any?(&:nil?)
          end
        end

        # Named `default_scope` and marked `default`: it is no method to call,
        # and Rails stacks every one onto each query the model runs.
        def record_default_scope(node)
          callable = scope_body_node(node)
          body = callable ? lambda_body_source(callable) : nil
          all_queries = extract_keyword_sources(node)[:all_queries]

          @results << {
            name:        "default_scope",
            default:     true,
            body:        body,
            all_queries: all_queries,
            location:    node.location.start_line,
            confidence:  body ? Confidence::VERIFIED : Confidence::INFERRED,
            owner:       @owner_stack.dup
          }.compact
        end

        # A stabby lambda, a `lambda`/`proc` call's block, or the scope's own block only when
        # the call passes no body (otherwise that block is an extension block).
        def scope_body_node(node)
          args = (node.arguments&.arguments || []).reject { |a| a.is_a?(Prism::KeywordHashNode) }
          positional = args.reject { |a| a.is_a?(Prism::SymbolNode) || a.is_a?(Prism::StringNode) }
          args.find { |a| a.is_a?(Prism::LambdaNode) } ||
            args.find { |a| a.is_a?(Prism::CallNode) && LAMBDA_METHODS.include?(a.name) }&.block ||
            (node.block if positional.empty?)
        end

        def lambda_body_source(node)
          body = node.body
          return nil unless body

          one_line_source(body)
        rescue StandardError
          nil
        end

        # Required parameter names of the scope lambda. A scope with required
        # params cannot be called bare (`Model.scope_name` raises ArgumentError),
        # which consumers like generate_test need to know.
        def lambda_required_params(node)
          params = node.parameters
          params = params.parameters if params.respond_to?(:parameters) && params.parameters
          return [] unless params.respond_to?(:requireds)

          params.requireds.map { |p| p.respond_to?(:name) ? p.name.to_s : p.slice }
        rescue StandardError
          []
        end
      end
    end
  end
end
