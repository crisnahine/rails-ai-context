# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    module Listeners
      # A queue a class body assigns outside any method: Resque's `@queue = :name`
      # and Que's `self.queue = "name"`, or a `def self.queue` returning one, which
      # Resque asks for when @queue is unset. A literal is kept as its value, anything else as source.
      class QueueAssignmentListener < BaseListener
        def initialize
          super
          @def_depth = 0
        end

        def on_def_node_enter(node)
          if @def_depth.zero? && node.name == :queue && node.receiver.is_a?(Prism::SelfNode) && node.parameters.nil?
            body = node.body
            body = body.body.first if body.is_a?(Prism::StatementsNode) && body.body.one?
            record(node, body, :method) if body && !body.is_a?(Prism::StatementsNode)
          end
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
