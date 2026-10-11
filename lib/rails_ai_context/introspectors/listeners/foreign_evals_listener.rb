# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # The blocks a class body evaluates on another receiver (`translation_class.class_eval do`),
      # each with the source of the first call on every line inside it.
      class ForeignEvalsListener < BaseListener
        Block = Struct.new(:receiver, :lines, :length, :calls)

        def initialize
          super
          @def_depth = 0
          @open = []
        end

        def on_def_node_enter(_node)
          @def_depth += 1
        end

        def on_def_node_leave(_node)
          @def_depth -= 1
        end

        def on_call_node_enter(node)
          @open.each { |_, block| block.calls[node.location.start_line] ||= CallSiteExpansion.call_source(node) }
          return unless @def_depth.zero? && CallSiteExpansion.foreign_eval?(node)

          body = node.block.location
          block = Block.new(node.receiver.slice, body.start_line..body.end_line, node.location.length, {})
          @results << block
          @open << [ node, block ]
        end

        def on_call_node_leave(node)
          @open.pop if @open.last&.first.equal?(node)
        end
      end
    end
  end
end
