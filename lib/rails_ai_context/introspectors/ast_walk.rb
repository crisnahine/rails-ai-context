# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Every node of a Prism tree: the root, then each child's subtree in
    # source order. Without a block it returns an Enumerator.
    module AstWalk
      module_function

      def each(node)
        return enum_for(:each, node) unless block_given?

        stack = [ node ]
        until stack.empty?
          current = stack.pop
          yield current
          stack.concat(current.compact_child_nodes.reverse)
        end
      end
    end
  end
end
