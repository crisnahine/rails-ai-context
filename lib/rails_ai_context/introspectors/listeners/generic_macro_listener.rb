# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      class GenericMacroListener < BaseListener
        def initialize(*target_methods)
          super()
          @target_methods = target_methods.flatten.map(&:to_sym).to_set
          @enclosing = []
        end

        def on_call_node_enter(node)
          return unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
          return unless @target_methods.include?(node.name)

          @results << {
            macro:         node.name,
            args:          extract_symbol_args(node),
            values:        extract_arg_values(node),
            options:       extract_keyword_options(node),
            option_values: extract_keyword_sources(node),
            option_nodes:  extract_keyword_nodes(node),
            nested_in:     @enclosing.last&.name,
            parent_location: @enclosing.last&.location&.start_line,
            location:      node.location.start_line,
            confidence:    confidence_for(node)
          }

          # A target macro that takes a block encloses whatever the block
          # declares: `string :title` inside `hash :order_params do ... end`
          # is a key of that hash, not a second filter of the class.
          @enclosing.push(node) if node.block
        end

        def on_call_node_leave(node)
          @enclosing.pop if @enclosing.last.equal?(node)
        end
      end
    end
  end
end
