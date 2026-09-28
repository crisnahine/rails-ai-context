# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      class MiddlewareConfigListener < BaseListener
        MIDDLEWARE_ACTIONS = %i[use insert_before insert_after insert unshift swap move_before move_after delete].to_set.freeze

        # The verbs that name the stack position first and the middleware second.
        POSITIONAL_ACTIONS = %i[insert_before insert_after insert swap move_before move_after].freeze

        # `app_class` is the app's own application constant ("MyApp::Application"),
        # the one constant besides `Rails` that names the app's stack.
        def initialize(app_class: nil)
          super()
          @app_class = app_class&.delete_prefix("::")
        end

        def on_call_node_enter(node)
          return record_exceptions_app(node) if node.name == :exceptions_app= && app_chain?(node.receiver)
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

        # `config.exceptions_app = Middleware::PublicExceptions.new(path)` is
        # the app that renders errors, not a layer of the stack.
        def record_exceptions_app(node)
          value = Array(node.arguments&.arguments).first
          value = value.receiver if value.is_a?(Prism::CallNode) && value.name == :new
          return unless value.is_a?(Prism::ConstantReadNode) || value.is_a?(Prism::ConstantPathNode)

          @results << { action: "exceptions_app", middleware: constant_path_string(value), location: node.location.start_line }
        end

        # How an initializer reaches the app's own stack: through its config,
        # or through the app itself.
        APP_RECEIVERS = %i[config configuration app application].freeze

        def middleware_config_receiver?(node)
          receiver = node.receiver
          return false unless receiver.is_a?(Prism::CallNode) && receiver.name == :middleware

          app_chain?(receiver.receiver)
        end

        # Every link names the app or its config, down to `Rails` or nothing:
        # any other constant anywhere in the chain is some engine's stack.
        def app_chain?(node)
          case node
          when Prism::LocalVariableReadNode then APP_RECEIVERS.include?(node.name)
          when Prism::ConstantReadNode, Prism::ConstantPathNode then app_class?(node)
          when Prism::CallNode
            return false unless APP_RECEIVERS.include?(node.name)

            base = node.receiver
            base.nil? || (base.is_a?(Prism::ConstantReadNode) && base.name == :Rails) || app_chain?(base)
          else false
          end
        end

        def app_class?(node)
          !@app_class.nil? && node.slice.delete_prefix("::") == @app_class
        end

        def resolve_middleware_arg(args, action)
          idx = POSITIONAL_ACTIONS.include?(action) ? 1 : 0
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
