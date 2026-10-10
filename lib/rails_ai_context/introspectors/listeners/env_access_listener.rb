# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects ENV variable access patterns via Prism AST:
      # ENV["KEY"], ENV.fetch("KEY"), ENV.fetch("KEY", "default")
      class EnvAccessListener < BaseListener
        def on_call_node_enter(node)
          return extract_creds(node) if creds_receiver?(node.receiver)
          return unless env_receiver?(node.receiver)

          case node.name
          when :[]
            extract_subscript(node)
          when :fetch
            extract_fetch(node)
          end
        end

        private

        # Rails 8.2's `Rails.app.creds` checks ENV before the encrypted
        # credentials, and `Rails.app.envs` reads only ENV.
        def creds_receiver?(receiver)
          return false unless receiver.is_a?(Prism::CallNode) && %i[creds envs].include?(receiver.name)

          app = receiver.receiver
          app.is_a?(Prism::CallNode) && %i[app application].include?(app.name) &&
            app.receiver.is_a?(Prism::ConstantReadNode) && app.receiver.name == :Rails
        end

        # `require(:database, :host)` reads ENV["DATABASE__HOST"].
        def extract_creds(node)
          return unless %i[require option].include?(node.name)

          args = node.arguments&.arguments || []
          parts = args.reject { |arg| arg.is_a?(Prism::KeywordHashNode) }
          keys = parts.map { |arg| literal_string(arg) }
          return if keys.empty? || keys.any?(&:nil?)

          default = extract_keyword_nodes(node)[:default]
          optional = node.name == :option
          @results << {
            method:      optional && default.nil? ? "[]" : "fetch",
            key:         keys.map(&:upcase).join("__"),
            has_default: !default.nil?,
            default:     literal_value(default),
            location:    node.location.start_line
          }
        end

        def env_receiver?(receiver)
          receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :ENV
        end

        def extract_subscript(node)
          args = node.arguments&.arguments || []
          key = literal_string(args.first)
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
          key = literal_string(args.first)
          return unless key

          @results << {
            method:      "fetch",
            key:         key,
            has_default: args.size > 1 || !node.block.nil?,
            # nil unless the fallback is a value that can be printed as one.
            # `ENV.fetch("PORT", defaults[:port])` has a default, but naming
            # it `defaults[:port]` puts a Ruby expression where a reader
            # expects something to copy into a .env file.
            default:     args.size > 1 ? literal_value(args[1]) : block_value(node.block),
            location:    node.location.start_line
          }
        end

        # `ENV.fetch("REDIS_URL") { "redis://localhost:6379/1" }`: a block whose
        # one statement is a literal is that default, as a second argument is.
        def block_value(block)
          statements = block.body if block.is_a?(Prism::BlockNode)
          return unless statements.is_a?(Prism::StatementsNode) && statements.body.size == 1

          literal_value(statements.body.first)
        end

        def literal_value(node)
          case node
          when Prism::StringNode  then node.unescaped
          when Prism::SymbolNode  then ":#{node.value}"
          when Prism::IntegerNode, Prism::FloatNode then node.value.to_s
          when Prism::TrueNode    then "true"
          when Prism::FalseNode   then "false"
          when Prism::NilNode     then "nil"
          else nil
          end
        end
      end
    end
  end
end
