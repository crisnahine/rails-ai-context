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
            name:       name.to_s,
            body:       body,
            location:   node.location.start_line,
            confidence: confidence_for(node)
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
      end
    end
  end
end
