# frozen_string_literal: true

module RailsAiContext
  # Confidence tags for AST introspection results.
  # Shared across tools and introspectors without creating
  # cross-layer dependencies.
  #
  # VERIFIED: value extracted from a runtime-confirmed source (e.g. inspection of
  #           a loaded Rails environment).
  # STATIC: value derived from source files without a booted app - trustworthy
  #         structure, but not runtime-confirmed (e.g. a routes.rb entry may
  #         still be disabled by a constraint the parser cannot evaluate).
  # INFERRED: value involves dynamic expressions, metaprogramming,
  #           or runtime-only constructs that AST cannot fully resolve.
  # UNAVAILABLE: data source is absent entirely; use the reasoned form to tell
  #              consumers what would unlock the data.
  module Confidence
    VERIFIED = "[VERIFIED]"
    INFERRED = "[INFERRED]"
    # STATIC marks data derived from source files without a booted app -
    # trustworthy structure, but not runtime-confirmed (a routes.rb entry may
    # still be disabled by a constraint the parser cannot evaluate).
    STATIC = "[STATIC]"
    # UNAVAILABLE marks data whose source is absent entirely; prefer the
    # reasoned form so consumers learn what would unlock the data.
    UNAVAILABLE = "[UNAVAILABLE]"

    # Reasoned unavailability tag: "[UNAVAILABLE: requires a booted Rails app]".
    # Reasons are collapsed to their first line so a raised exception message
    # can be passed through without flooding the tag.
    def self.unavailable(reason)
      "[UNAVAILABLE: #{reason.to_s.lines.first.to_s.strip}]"
    end

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
