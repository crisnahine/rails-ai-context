# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    module Listeners
      # A queue a class body assigns outside any method: Resque's `@queue = :name`
      # and Que's `self.queue = "name"`. A literal is kept as its value, anything else as source.
      class QueueAssignmentListener < BaseListener
        def initialize
          super
          @def_depth = 0
        end

        def on_def_node_enter(_node)
          @def_depth += 1
        end

        def on_def_node_leave(_node)
          @def_depth -= 1
        end

        def on_instance_variable_write_node_enter(node)
          record(node, node.value, :ivar) if @def_depth.zero? && node.name == :@queue
        end

        def on_call_node_enter(node)
          return unless @def_depth.zero? && node.name == :queue= && node.receiver.is_a?(Prism::SelfNode)

          value = node.arguments&.arguments&.first
          record(node, value, :self) if value
        end

        private

        def record(node, value, form)
          literal = value.is_a?(Prism::SymbolNode) || value.is_a?(Prism::StringNode)
          @results << { form: form, queue: literal ? value.unescaped : nil, source: value.slice,
                        location: node.location.start_line, confidence: literal ? Confidence::VERIFIED : Confidence::INFERRED }
        end
      end
    end
  end
end
