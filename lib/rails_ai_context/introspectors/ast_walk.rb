# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    # Every node of a Prism tree: the root, then each child's subtree in
    # source order. Without a block it returns an Enumerator.
    module AstWalk
      # Nodes whose body has its own self and locals.
      OWN_SCOPES = [ Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode ].freeze
      # Every write that keeps its value: in a variable, a constant, an attribute or an element, or spread over targets.
      VALUE_WRITES = [
        Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
        Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode, Prism::ClassVariableWriteNode, Prism::ClassVariableOperatorWriteNode,
        Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode, Prism::GlobalVariableWriteNode,
        Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
        Prism::ConstantWriteNode, Prism::ConstantOperatorWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
        Prism::ConstantPathWriteNode, Prism::ConstantPathOperatorWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode,
        Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode, Prism::IndexOperatorWriteNode,
        Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::MultiWriteNode
      ].freeze

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

      # The `def` starting at `offset`, reached down the nodes that hold it, or nil.
      def def_at(node, offset)
        node = node.compact_child_nodes.find { |child| child.location.start_offset <= offset && offset < child.location.end_offset } until node.nil? || (node.is_a?(Prism::DefNode) && node.location.start_offset == offset)
        node
      end

      # The nodes a body runs with its own self: the node opening a method,
      # class or `class << x` is there, its body is not.
      def scope(node, found = [])
        return found unless node

        found << node
        case node
        when *OWN_SCOPES then found
        else node.compact_child_nodes.each_with_object(found) { |child, into| scope(child, into) }
        end
      end
    end
  end
end
