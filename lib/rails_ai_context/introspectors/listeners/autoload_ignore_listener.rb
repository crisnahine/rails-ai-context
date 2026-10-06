# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # The lib subdirectories `config.autoload_lib(ignore: %w[assets tasks])`
      # keeps Zeitwerk out of, as root-relative paths. Literal names only.
      class AutoloadIgnoreListener < BaseListener
        AUTOLOAD_LIB = %i[autoload_lib autoload_lib_once].to_set.freeze

        def on_call_node_enter(node)
          return unless AUTOLOAD_LIB.include?(node.name) && node.receiver

          ignore = extract_keyword_nodes(node)[:ignore]
          collect(ignore) if ignore
        end

        private

        def collect(node)
          case node
          when Prism::ArrayNode then node.elements.each { |element| collect(element) }
          when Prism::StringNode, Prism::SymbolNode
            name = node.unescaped.to_s.strip.delete_prefix("/")
            @results << File.join("lib", name) unless name.empty? || name.split("/").include?("..")
          end
        end
      end
    end
  end
end
