# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects association macro calls via Prism AST:
      # belongs_to, has_many, has_one, has_and_belongs_to_many, and the
      # belongs_to delegated_type declares
      class AssociationsListener < BaseListener
        include WithOptionsScope

        ASSOCIATION_METHODS = %i[
          belongs_to has_many has_one has_and_belongs_to_many
        ].to_set.freeze

        # acts_as_tenant calls `belongs_to tenant, scope, **valid_options`, the tenant defaulting to :account.
        TENANT_OPTIONS = %i[foreign_key class_name inverse_of optional primary_key counter_cache polymorphic touch].freeze

        def on_call_node_enter(node)
          return record_tenant(node) if node.name == :acts_as_tenant && in_scope?(node)

          delegated = node.name == :delegated_type
          return unless delegated || ASSOCIATION_METHODS.include?(node.name)
          return unless in_scope?(node)

          name, literal = first_name_and_literal(node)
          options = scope_options(receiver_name(node)).merge(extract_keyword_sources(node))
          # delegated_type passes its options to `belongs_to role, polymorphic: true`.
          options = options.except(:types).merge(polymorphic: true) if delegated
          # The booted tier reads the macro off `assoc.macro.to_s`, so a
          # static record spells it the same way or no consumer can compare
          # the two.
          @results << {
            type:          delegated ? "belongs_to" : node.name.to_s,
            name:          name,
            computed_name: (true unless literal),
            computed_foreign_key: (true if computed_key?(node)),
            # Sources, not literals: `class_name: Organisation.name` names a
            # class, and the marker names nothing.
            options:       options,
            delegated_types: (delegated_types(node) if delegated),
            extension_methods: extension_methods(node),
            location:      node.location.start_line,
            confidence:    confidence_for(node)
          }.compact
        end

        private

        def record_tenant(node)
          first = node.arguments&.arguments&.first
          first = nil if first.is_a?(Prism::KeywordHashNode)
          name, literal = first ? first_name_and_literal(node) : [ :account, true ]
          @results << {
            type:          "belongs_to",
            name:          name,
            computed_name: (true unless literal),
            options:       scope_options(receiver_name(node)).merge(extract_keyword_sources(node).slice(*TENANT_OPTIONS)),
            location:      node.location.start_line,
            confidence:    confidence_for(node)
          }.compact
        end

        def delegated_types(node)
          types = extract_keyword_nodes(node)[:types]
          types && literal_strings(types).presence
        end

        # `has_many :sessions do def active ... end end` adds `user.sessions.active`.
        def extension_methods(node)
          body = node.block.is_a?(Prism::BlockNode) ? node.block.body : nil
          return nil unless body.is_a?(Prism::StatementsNode)

          names = body.body.grep(Prism::DefNode).map { |d| d.name.to_s }
          names.presence
        end

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
