# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Calls made on a receiver, e.g. `config.omniauth :github` or
      # `inflect.acronym "API"`. Pass `receiver:` to only match a named one.
      class ChainedCallListener < BaseListener
        def initialize(*methods, receiver: nil)
          super()
          @target_methods = methods.flatten.map(&:to_sym).to_set
          @receiver_name  = receiver&.to_sym
        end

        def on_call_node_enter(node)
          return if node.receiver.nil?
          return unless @target_methods.include?(node.name)

          name = receiver_name(node.receiver)
          return if @receiver_name && name != @receiver_name

          @results << {
            method:   node.name.to_s,
            receiver: name&.to_s,
            args:     extract_symbol_args(node),
            values:   extract_arg_values(node),
            options:  extract_keyword_options(node),
            location: node.location.start_line
          }
        end

        private

        def receiver_name(node)
          case node
          when Prism::LocalVariableReadNode then node.name
          when Prism::ConstantReadNode, Prism::ConstantPathNode then constant_path_string(node).to_sym
          when Prism::CallNode then node.name if node.arguments.nil?
          end
        end
      end
    end
  end
end
