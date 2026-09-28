# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects association macro calls via Prism AST:
      # belongs_to, has_many, has_one, has_and_belongs_to_many
      class AssociationsListener < BaseListener
        include WithOptionsScope

        ASSOCIATION_METHODS = %i[
          belongs_to has_many has_one has_and_belongs_to_many
        ].to_set.freeze

        def on_call_node_enter(node)
          return unless ASSOCIATION_METHODS.include?(node.name)
          return unless in_scope?(node)

          name, literal = first_name_and_literal(node)
          # The booted tier reads the macro off `assoc.macro.to_s`, so a
          # static record spells it the same way or no consumer can compare
          # the two.
          @results << {
            type:          node.name.to_s,
            name:          name,
            computed_name: (true unless literal),
            # Sources, not literals: `class_name: Organisation.name` names a
            # class, and the marker names nothing.
            options:       scope_options(receiver_name(node)).merge(extract_keyword_sources(node)),
            location:      node.location.start_line,
            confidence:    confidence_for(node)
          }.compact
        end
      end
    end
  end
end
