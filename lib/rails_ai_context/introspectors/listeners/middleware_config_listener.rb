# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      class MiddlewareConfigListener < BaseListener
        MIDDLEWARE_ACTIONS = %i[use insert_before insert_after insert unshift].to_set.freeze

        def on_call_node_enter(node)
          return unless MIDDLEWARE_ACTIONS.include?(node.name)
          return unless middleware_config_receiver?(node)

          args = node.arguments&.arguments || []
          middleware_name = resolve_middleware_arg(args, node.name)
          return unless middleware_name

          @results << {
            action:     node.name.to_s,
            middleware: middleware_name,
            location:   node.location.start_line
          }
        end

        private

        def middleware_config_receiver?(node)
          receiver = node.receiver
          return false unless receiver.is_a?(Prism::CallNode) && receiver.name == :middleware

          inner = receiver.receiver
          return false unless inner.is_a?(Prism::CallNode) && inner.name == :config
          true
        end

        def resolve_middleware_arg(args, action)
          idx = %i[insert_before insert_after insert].include?(action) ? 1 : 0
          idx = 1 if idx == 0 && args[0].is_a?(Prism::IntegerNode)
          arg = args[idx]
          case arg
          when Prism::ConstantReadNode then arg.name.to_s
          when Prism::ConstantPathNode then constant_path_string(arg)
          else nil
          end
        end
      end
    end
  end
end
