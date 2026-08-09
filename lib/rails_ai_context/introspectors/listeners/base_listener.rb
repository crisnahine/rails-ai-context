# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    module Listeners
      # Base class for Prism Dispatcher listeners.
      # Provides shared helpers for extracting values from AST nodes.
      class BaseListener
        attr_reader :results

        def initialize
          @results = []
        end

        private

        # Extract the first positional symbol argument from a call node.
        # e.g. `has_many :posts` → :posts
        def extract_first_symbol(node)
          arg = node.arguments&.arguments&.first
          case arg
          when Prism::SymbolNode then arg.value.to_sym
          when Prism::StringNode then arg.unescaped.to_sym
          else RailsAiContext::Confidence::INFERRED
          end
        end

        # Extract keyword options from a call node.
        # e.g. `has_many :posts, dependent: :destroy` → { dependent: :destroy }
        def extract_keyword_options(node)
          keyword_hash(node) { |value| extract_value(value) }
        end

        # The call's keyword arguments, each value passed through the block.
        def keyword_hash(node)
          args = node.arguments&.arguments || []
          args.select { |a| a.is_a?(Prism::KeywordHashNode) }
              .flat_map(&:elements)
              .each_with_object({}) do |assoc, h|
            next unless assoc.is_a?(Prism::AssocNode)
            h[extract_key(assoc.key)] = yield(assoc.value)
          end
        end

        # Extract all symbol arguments (skipping keyword hashes).
        # e.g. `validates :email, :name, presence: true` → [:email, :name]
        def extract_symbol_args(node)
          args = node.arguments&.arguments || []
          args.filter_map { |a|
            case a
            when Prism::SymbolNode then a.value.to_sym
            when Prism::StringNode then a.unescaped.to_sym
            else nil
            end
          }
        end

        # Extract every positional argument as a value, falling back to the raw
        # source slice for expressions that have no literal value (`2.hours`).
        def extract_arg_values(node)
          args = node.arguments&.arguments || []
          args.reject { |a| a.is_a?(Prism::KeywordHashNode) }.map { |a| value_or_source(a) }
        end

        # Keyword options with the raw source slice kept for expressions that
        # have no literal value (`every: 3.seconds`).
        def extract_keyword_sources(node)
          keyword_hash(node) { |value| value_or_source(value) }
        end

        # Keyword options as their raw Prism nodes, for callers that need to
        # inspect the structure of an expression rather than its value.
        def extract_keyword_nodes(node)
          keyword_hash(node) { |value| value }
        end

        def value_or_source(node)
          value = extract_value(node)
          value == RailsAiContext::Confidence::INFERRED ? node.slice : value
        end

        def extract_key(node)
          case node
          when Prism::SymbolNode then node.value.to_sym
          when Prism::StringNode then node.unescaped.to_sym
          else RailsAiContext::Confidence::INFERRED
          end
        end

        def extract_value(node)
          case node
          when Prism::SymbolNode         then node.value.to_sym
          when Prism::StringNode         then node.unescaped
          when Prism::InterpolatedStringNode then adjacent_literals(node)
          when Prism::IntegerNode        then node.value
          when Prism::FloatNode          then node.value
          when Prism::TrueNode           then true
          when Prism::FalseNode          then false
          when Prism::NilNode            then nil
          when Prism::ConstantReadNode   then node.name.to_s
          when Prism::ConstantPathNode   then constant_path_string(node)
          when Prism::ArrayNode          then node.elements.map { |e| extract_value(e) }
          when Prism::HashNode           then hash_node_to_hash(node)
          when Prism::KeywordHashNode    then hash_node_to_hash(node)
          else RailsAiContext::Confidence::INFERRED
          end
        end

        # `"a" "b"` and its line-continued form parse as one interpolated node
        # with only literal parts. Anything with a real `#{}` stays inferred.
        def adjacent_literals(node)
          parts = node.parts
          return RailsAiContext::Confidence::INFERRED unless parts.all? { |p| p.is_a?(Prism::StringNode) }
          parts.map(&:unescaped).join
        end

        def constant_path_string(node)
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          parts.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
          parts.join("::")
        end

        def hash_node_to_hash(node)
          elements = node.respond_to?(:elements) ? node.elements : []
          elements.each_with_object({}) do |assoc, h|
            next unless assoc.is_a?(Prism::AssocNode)
            h[extract_key(assoc.key)] = extract_value(assoc.value)
          end
        end

        def confidence_for(node)
          RailsAiContext::Confidence.for_node(node)
        end
      end
    end
  end
end
