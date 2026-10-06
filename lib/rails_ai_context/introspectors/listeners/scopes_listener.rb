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

        def on_call_node_enter(node)
          return record_default_scope(node) if node.name == :default_scope && in_scope?(node)
          return unless node.name == :scope && in_scope?(node)

          name = extract_first_symbol(node)
          return if name == "[INFERRED]"

          callable = scope_body_node(node)
          body = callable ? lambda_body_source(callable) : nil

          @results << {
            name:            name.to_s,
            body:            body,
            required_params: callable ? lambda_required_params(callable) : [],
            location:        node.location.start_line,
            # A lambda body sliced verbatim from source IS the scope's ground
            # truth; only scopes whose body can't be extracted (block form,
            # metaprogrammed) are heuristic.
            confidence:      body ? Confidence::VERIFIED : Confidence::INFERRED,
            owner:           @owner_stack.dup
          }
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
