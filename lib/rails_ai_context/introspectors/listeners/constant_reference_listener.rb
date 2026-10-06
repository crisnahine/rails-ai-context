# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # References to constants by their last name (`MessageVerifier`, `ActiveSupport::MessageVerifier`).
      # A constant that only qualifies a nested one (`MessageVerifier::InvalidSignature`) is no reference to it.
      class ConstantReferenceListener < BaseListener
        def initialize(names: [])
          super()
          @names = names.map(&:to_sym).to_set
          @qualifiers = {}.compare_by_identity
        end

        def on_constant_path_node_enter(node)
          @qualifiers[node.parent] = true if node.parent
          record(node)
        end

        def on_constant_read_node_enter(node)
          record(node)
        end

        private

        def record(node)
          return if @qualifiers.delete(node) || !@names.include?(node.name)

          @results << { name: node.name.to_s, source: node.slice, line: node.location.start_line }
        end
      end
    end
  end
end
