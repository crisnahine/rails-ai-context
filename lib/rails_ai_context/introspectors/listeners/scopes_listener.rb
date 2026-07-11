# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects `scope :name, -> { ... }` declarations via Prism AST.
      class ScopesListener < BaseListener
        def on_call_node_enter(node)
          return unless node.name == :scope && node.receiver.nil?

          name = extract_first_symbol(node)
          return if name == "[INFERRED]"

          # Extract the lambda body source if available
          args = node.arguments&.arguments || []
          lambda_node = args.find { |a| a.is_a?(Prism::LambdaNode) }
          body = lambda_node ? lambda_body_source(lambda_node) : nil

          @results << {
            name:            name.to_s,
            body:            body,
            required_params: lambda_node ? lambda_required_params(lambda_node) : [],
            location:        node.location.start_line,
            # A lambda body sliced verbatim from source IS the scope's ground
            # truth; only scopes whose body can't be extracted (block form,
            # metaprogrammed) are heuristic.
            confidence:      body ? Confidence::VERIFIED : Confidence::INFERRED
          }
        end

        private

        def lambda_body_source(node)
          body = node.body
          return nil unless body
          # Get the source slice for the body
          body.slice&.strip
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
