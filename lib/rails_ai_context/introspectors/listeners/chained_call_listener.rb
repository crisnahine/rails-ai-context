# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      class ChainedCallListener < BaseListener
        def initialize(*methods)
          super()
          @target_methods = methods.flatten.map(&:to_sym).to_set
        end

        def on_call_node_enter(node)
          return if node.receiver.nil?
          return unless @target_methods.include?(node.name)

          @results << {
            method:   node.name.to_s,
            args:     extract_symbol_args(node),
            options:  extract_keyword_options(node),
            location: node.location.start_line
          }
        end
      end

    end
  end
end
