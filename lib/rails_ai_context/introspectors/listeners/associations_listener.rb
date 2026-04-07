# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects association macro calls via Prism AST:
      # belongs_to, has_many, has_one, has_and_belongs_to_many
      class AssociationsListener < BaseListener
        ASSOCIATION_METHODS = %i[
          belongs_to has_many has_one has_and_belongs_to_many
        ].to_set.freeze

        def on_call_node_enter(node)
          return unless ASSOCIATION_METHODS.include?(node.name) && node.receiver.nil?

          @results << {
            type:       node.name,
            name:       extract_first_symbol(node),
            options:    extract_keyword_options(node),
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end
      end
    end
  end
end
