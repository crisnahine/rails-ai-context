# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects enum declarations via Prism AST.
      # Handles both Rails 7+ syntax (`enum :role, { ... }`) and
      # legacy syntax (`enum role: { ... }`).
      class EnumsListener < BaseListener
        include OwnerScope

        # The keywords Rails' `_enum` takes, and the underscored names the 7.x hash form
        # (`enum status: {...}, _prefix: true`) gives them; any other key there is an enum.
        OPTIONS = %i[prefix suffix scopes default instance_methods validate].freeze
        LEGACY_OPTIONS = (OPTIONS - %i[validate]).map { |key| :"_#{key}" }.freeze

        def on_call_node_enter(node)
          return unless node.name == :enum && node.receiver.nil?

          args = node.arguments&.arguments || []
          return if args.empty?

          first = args.first

          if first.is_a?(Prism::SymbolNode)
            # Rails 7+ syntax: enum :role, { admin: 0, member: 1 }, prefix: true
            extract_rails7_enum(node, first, args)
          elsif first.is_a?(Prism::KeywordHashNode)
            # Legacy syntax: enum role: { admin: 0, member: 1 }
            extract_legacy_enum(node, first)
          end
        end

        private

        def extract_rails7_enum(node, name_node, args)
          enum_name = name_node.unescaped
          values_node = args[1]
          raw_values = values_node ? enum_values(values_node) : {}
          # Normalize array-style values ([:admin, :member]) to hash ({ admin: 0, member: 1 })
          values = normalize_enum_values(raw_values)
          options = extract_enum_modifiers(args[2..])

          @results << {
            name:       enum_name,
            values:     values,
            options:    options,
            location:   node.location.start_line,
            confidence: confidence_for(node),
            owner:      @owner_stack.dup
          }
        end

        def extract_legacy_enum(node, keyword_hash)
          options = {}
          keyword_hash.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)
            key = extract_key(assoc.key)
            options[key.to_s.delete_prefix("_").to_sym] = extract_value(assoc.value) if LEGACY_OPTIONS.include?(key)
          end

          keyword_hash.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)
            key = extract_key(assoc.key)
            next if LEGACY_OPTIONS.include?(key)

            @results << {
              name:       key.to_s,
              values:     normalize_enum_values(enum_values(assoc.value)),
              options:    options,
              location:   node.location.start_line,
              confidence: confidence_for(node),
              owner:      @owner_stack.dup
            }
          end
        end

        # A literal hash or array as its values, or the bare keywords of `enum :status, active: 0`,
        # which Rails reads as values whole; anything else (`Statuses.to_h`) as its source,
        # which a String value in the enum map marks as computed.
        def enum_values(node)
          # `%i[low high].freeze` is the literal it freezes.
          node = node.receiver if node.is_a?(Prism::CallNode) && node.name == :freeze && literal_collection?(node.receiver)
          literal_collection?(node) ? extract_value(node) : one_line_source(node)
        end

        # A `**splat` among the pairs is values the source does not spell.
        def literal_collection?(node)
          return node.elements.all?(Prism::AssocNode) if node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)

          node.is_a?(Prism::ArrayNode)
        end

        def extract_enum_modifiers(remaining_args)
          return {} unless remaining_args&.any?
          opts = {}
          remaining_args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)
            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)
              key = extract_key(assoc.key)
              opts[key] = extract_value(assoc.value) if OPTIONS.include?(key)
            end
          end
          opts
        end

        # Normalize array-style enum values to a hash with auto-incrementing indices.
        # [:admin, :member] → { admin: 0, member: 1 }
        def normalize_enum_values(values)
          return values unless values.is_a?(Array)
          values.each_with_index.each_with_object({}) do |(v, i), h|
            key = v.is_a?(Symbol) ? v : v.to_s.to_sym
            h[key] = i
          end
        end
      end
    end
  end
end
