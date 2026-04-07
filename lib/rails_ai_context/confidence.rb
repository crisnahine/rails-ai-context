# frozen_string_literal: true

module RailsAiContext
  # Confidence tags for AST introspection results.
  # Shared across tools and introspectors without creating
  # cross-layer dependencies.
  #
  # VERIFIED: value extracted from a static, deterministic AST node
  #           (symbol literals, string literals, integers, booleans).
  # INFERRED: value involves dynamic expressions, metaprogramming,
  #           or runtime-only constructs that AST cannot fully resolve.
  module Confidence
    VERIFIED = "[VERIFIED]"
    INFERRED = "[INFERRED]"

    # Determine confidence level for a Prism call node's arguments.
    # Returns VERIFIED if all arguments are static literals,
    # INFERRED if any argument is a dynamic expression.
    def self.for_node(node)
      args = node.arguments&.arguments
      return VERIFIED unless args

      static = args.all? { |a| static_node?(a) }
      static ? VERIFIED : INFERRED
    end

    # Recursively check if a node is a static literal.
    def self.static_node?(node)
      case node
      when Prism::SymbolNode, Prism::StringNode, Prism::IntegerNode,
           Prism::FloatNode, Prism::TrueNode, Prism::FalseNode,
           Prism::NilNode, Prism::ConstantReadNode, Prism::ConstantPathNode
        true
      when Prism::ArrayNode
        node.elements.all? { |e| static_node?(e) }
      when Prism::HashNode
        node.elements.all? { |e| e.is_a?(Prism::AssocNode) && static_node?(e.key) && static_node?(e.value) }
      when Prism::KeywordHashNode
        node.elements.all? { |e| e.is_a?(Prism::AssocNode) && static_node?(e.key) && static_node?(e.value) }
      else
        false
      end
    end
  end
end
