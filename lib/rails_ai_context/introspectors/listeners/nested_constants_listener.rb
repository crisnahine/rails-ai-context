# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # The offset ranges of the modules and classes a class body nests: what they declare runs only where they are mixed in.
      class NestedConstantsListener < BaseListener
        def initialize
          super
          @depth = 0
        end

        def on_class_node_enter(node)
          record(node)
          @depth += 1
        end

        def on_class_node_leave(_node)
          @depth -= 1
        end

        def on_module_node_enter(node) = record(node)

        private

        def record(node)
          @results << (node.location.start_offset...node.location.end_offset) if @depth.positive?
        end
      end
    end
  end
end
