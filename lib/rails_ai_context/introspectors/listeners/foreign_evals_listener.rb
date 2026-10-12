# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # The blocks a class body evaluates on another receiver (`translation_class.class_eval do`),
      # each with the source of every outermost call, by the line it starts on.
      class ForeignEvalsListener < BaseListener
        Block = Struct.new(:receiver, :lines, :length, :calls)

        def initialize
          super
          @def_depth = 0
          @open = []
          @conditions = []
        end

        # A modifier's condition (`validates :x unless Rails.env.test?`) is not a declaration.
        def on_if_node_enter(node)
          @conditions << node.predicate.location
        end

        def on_unless_node_enter(node)
          @conditions << node.predicate.location
        end

        def on_def_node_enter(_node)
          @def_depth += 1
        end

        def on_def_node_leave(_node)
          @def_depth -= 1
        end

        def on_call_node_enter(node)
          @open.each { |_, block| record(block, node) }
          return unless @def_depth.zero? && CallSiteExpansion.foreign_eval?(node)

          body = node.block.location
          block = Block.new(node.receiver.slice, body.start_line..body.end_line, node.location.length, {})
          @results << block
          @open << [ node, block ]
        end

        def on_call_node_leave(node)
          @open.pop if @open.last&.first.equal?(node)
        end

        private

        # A call inside one already recorded on its line (`-> { order(:id) }`) is part of that one.
        def record(block, node)
          return if @conditions.any? { |condition| node.location.start_offset.between?(condition.start_offset, condition.end_offset - 1) }

          calls = (block.calls[node.location.start_line] ||= [])
          return if calls.any? { |call| call[:range].cover?(node.location.start_offset) }

          calls << { range: node.location.start_offset...node.location.end_offset, source: CallSiteExpansion.call_source(node) }
        end
      end
    end
  end
end
