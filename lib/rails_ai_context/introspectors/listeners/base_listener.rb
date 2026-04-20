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
          args = node.arguments&.arguments || []
          keywords = args.select { |a| a.is_a?(Prism::KeywordHashNode) }
          keywords.flat_map(&:elements).each_with_object({}) do |assoc, h|
            next unless assoc.is_a?(Prism::AssocNode)
            key = extract_key(assoc.key)
            h[key] = extract_value(assoc.value)
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
