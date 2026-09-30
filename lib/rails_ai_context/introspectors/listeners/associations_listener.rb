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
            computed_foreign_key: (true if computed_key?(node)),
            # Sources, not literals: `class_name: Organisation.name` names a
            # class, and the marker names nothing.
            options:       scope_options(receiver_name(node)).merge(extract_keyword_sources(node)),
            location:      node.location.start_line,
            confidence:    confidence_for(node)
          }.compact
        end

        private

        # `foreign_key: AUTHOR_KEY` names a column only at run time.
        def computed_key?(node)
          key = extract_keyword_nodes(node)[:foreign_key]
          return false if key.nil?

          keys = key.is_a?(Prism::ArrayNode) ? key.elements : [ key ]
          keys.empty? || keys.any? { |k| literal_string(k).nil? }
        end
      end
    end
  end
end
