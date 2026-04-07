# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects enum declarations via Prism AST.
      # Handles both Rails 7+ syntax (`enum :role, { ... }`) and
      # legacy syntax (`enum role: { ... }`).
      class EnumsListener < BaseListener
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
          enum_name = name_node.value.to_s
          values_node = args[1]
          raw_values = values_node ? extract_value(values_node) : {}
          # Normalize array-style values ([:admin, :member]) to hash ({ admin: 0, member: 1 })
          values = normalize_enum_values(raw_values)
          options = extract_enum_modifiers(args[2..])

          @results << {
            name:       enum_name,
            values:     values,
            options:    options,
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end

        def extract_legacy_enum(node, keyword_hash)
          # Collect modifier options (_prefix, _suffix, etc.) first
          options = {}
          keyword_hash.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)
            key = extract_key(assoc.key)
            options[key] = extract_value(assoc.value) if enum_modifier_key?(key)
          end

          keyword_hash.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)
            key = extract_key(assoc.key)
            next if enum_modifier_key?(key)

            @results << {
              name:       key.to_s,
              values:     extract_value(assoc.value),
              options:    options,
              location:   node.location.start_line,
              confidence: confidence_for(node)
            }
          end
        end

        def extract_enum_modifiers(remaining_args)
          return {} unless remaining_args&.any?
          opts = {}
          remaining_args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)
            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)
              key = extract_key(assoc.key)
              opts[key] = extract_value(assoc.value) if enum_modifier_key?(key)
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

        def enum_modifier_key?(key)
          %i[prefix suffix _prefix _suffix default scopes].include?(key)
        end
      end
    end
  end
end
