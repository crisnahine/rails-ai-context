# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Every Proc literal (`-> {}`, `lambda {}`, `proc {}`, `Proc.new {}`) with
      # the line it starts on and the constant it is assigned to, if any.
      class ProcLiteralListener < BaseListener
        def initialize
          super
          @assigned = {}
        end

        def on_constant_write_node_enter(node)
          @assigned[node.value.location.start_offset] = node.name.to_s
        end

        def on_lambda_node_enter(node)
          record(node)
        end

        def on_call_node_enter(node)
          record(node) if proc_call?(node)
        end

        private

        def proc_call?(node)
          return false unless node.block.is_a?(Prism::BlockNode)
          return %i[lambda proc].include?(node.name) if node.receiver.nil?

          node.name == :new && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Proc
        end

        def record(node)
          @results << { line: node.location.start_line, constant: @assigned[node.location.start_offset],
                        source: one_line_source(node) }
        end
      end
    end
  end
end
