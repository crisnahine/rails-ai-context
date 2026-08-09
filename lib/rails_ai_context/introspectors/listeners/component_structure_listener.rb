# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Structure of a ViewComponent or Phlex component class. Emits tagged
      # results, one per structural fact found:
      #
      #   { kind: :slot,           name: "header" }                        def header(&block)
      #   { kind: :slot_macro,     name: "header", type: :one }            renders_one :header
      #   { kind: :constant_table, name: "VARIANTS", values: [...] }       VARIANTS = { ... }
      #   { kind: :variant_branch, ivar: "variant", values: [...] }        case @variant
      #   { kind: :constant_index, constant: "SIZES", ivar: "size" }       SIZES[@size]
      #
      # Only the `.rb` class is in scope; sidecar ERB templates are not Ruby.
      class ComponentStructureListener < BaseListener
        # Phlex lifecycle hooks take a block but are not slots.
        NON_SLOT_METHODS = %w[initialize template view_template before_template after_template].to_set.freeze

        SLOT_MACROS = { renders_one: :one, renders_many: :many }.freeze

        def on_def_node_enter(node)
          return unless node.parameters&.block.is_a?(Prism::BlockParameterNode)
          return if NON_SLOT_METHODS.include?(node.name.to_s)

          @results << { kind: :slot, name: node.name.to_s, location: node.location.start_line }
        end

        def on_constant_write_node_enter(node)
          values = table_values(node.value)
          return if values.empty?

          @results << {
            kind:     :constant_table,
            name:     node.name.to_s,
            values:   values,
            location: node.location.start_line
          }
        end

        def on_case_node_enter(node)
          predicate = node.predicate
          return unless predicate.is_a?(Prism::InstanceVariableReadNode)

          values = node.conditions.grep(Prism::WhenNode).flat_map { |when_node|
            when_node.conditions.filter_map { |condition| literal_name(condition) }
          }
          return if values.empty?

          @results << {
            kind:     :variant_branch,
            ivar:     predicate.name.to_s.delete_prefix("@"),
            values:   values.uniq,
            location: node.location.start_line
          }
        end

        def on_call_node_enter(node)
          if SLOT_MACROS.key?(node.name) && node.receiver.nil?
            record_slot_macro(node)
          elsif node.name == :[]
            record_constant_index(node)
          end
        end

        private

        def record_slot_macro(node)
          name = extract_symbol_args(node).first
          return unless name

          renderer = extract_arg_values(node).drop(1).map(&:to_s)
          entry = {
            kind:     :slot_macro,
            name:     name.to_s,
            type:     SLOT_MACROS.fetch(node.name),
            location: node.location.start_line
          }
          entry[:renderer] = renderer.join(", ") if renderer.any?
          @results << entry
        end

        # `SIZES[@size]` ties a prop to the constant table that enumerates it.
        def record_constant_index(node)
          return unless node.receiver.is_a?(Prism::ConstantReadNode)

          argument = node.arguments&.arguments&.first
          return unless argument.is_a?(Prism::InstanceVariableReadNode)

          @results << {
            kind:     :constant_index,
            constant: node.receiver.name.to_s,
            ivar:     argument.name.to_s.delete_prefix("@"),
            location: node.location.start_line
          }
        end

        def table_values(node)
          case node
          when Prism::HashNode
            node.elements.grep(Prism::AssocNode).filter_map { |assoc| literal_name(assoc.key) }
          when Prism::ArrayNode
            node.elements.filter_map { |element| literal_name(element) }
          else
            []
          end
        end

        def literal_name(node)
          case node
          when Prism::SymbolNode then node.value.to_s
          when Prism::StringNode then node.unescaped
          end
        end
      end
    end
  end
end
