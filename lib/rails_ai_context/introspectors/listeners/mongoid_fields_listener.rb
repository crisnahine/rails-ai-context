# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects Mongoid document macros via Prism AST: field declarations,
      # embedded-document relations, and custom collection names. Regular
      # relations (belongs_to/has_many) share ActiveRecord's macro names and
      # are captured by AssociationsListener.
      class MongoidFieldsListener < BaseListener
        MONGOID_MACROS = %i[field embeds_many embeds_one embedded_in store_in].to_set.freeze

        def on_call_node_enter(node)
          return unless node.receiver.nil? && MONGOID_MACROS.include?(node.name)

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
