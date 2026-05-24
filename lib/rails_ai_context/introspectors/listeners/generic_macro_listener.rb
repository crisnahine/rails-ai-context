# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      class GenericMacroListener < BaseListener
        def initialize(*target_methods)
          super()
          @target_methods = target_methods.flatten.map(&:to_sym).to_set
        end

        def on_call_node_enter(node)
          return unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
          return unless @target_methods.include?(node.name)

          @results << {
            macro:      node.name,
            args:       extract_symbol_args(node),
            options:    extract_keyword_options(node),
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end
      end
    end
  end
end
