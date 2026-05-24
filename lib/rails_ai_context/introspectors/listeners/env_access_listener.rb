# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects ENV variable access patterns via Prism AST:
      # ENV["KEY"], ENV.fetch("KEY"), ENV.fetch("KEY", "default")
      class EnvAccessListener < BaseListener
        def on_call_node_enter(node)
          return unless env_receiver?(node.receiver)

          case node.name
          when :[]
            extract_subscript(node)
          when :fetch
            extract_fetch(node)
          end
        end

        private

        def env_receiver?(receiver)
          receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :ENV
        end

        def extract_subscript(node)
          args = node.arguments&.arguments || []
          key = string_value(args.first)
          return unless key

          @results << {
            method:   "[]",
            key:      key,
            has_default: false,
            location: node.location.start_line
          }
        end

        def extract_fetch(node)
          args = node.arguments&.arguments || []
          key = string_value(args.first)
          return unless key

          @results << {
            method:      "fetch",
            key:         key,
            has_default: args.size > 1 || !node.block.nil?,
            location:    node.location.start_line
          }
        end

        def string_value(node)
          case node
          when Prism::StringNode then node.unescaped
          when Prism::SymbolNode then node.value
          else nil
          end
        end
      end
    end
  end
end
