# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects migration DSL patterns via Prism AST:
      # create_table, add_column, remove_column, add_index,
      # rename_column, add_reference, change_column_default, etc.
      class MigrationDslListener < BaseListener
        SINGLE_TABLE_ACTIONS = %i[
          create_table drop_table rename_table change_table
        ].to_set.freeze

        COLUMN_ACTIONS = %i[
          add_column remove_column rename_column change_column change_column_default
          change_column_null
        ].to_set.freeze

        INDEX_ACTIONS = %i[add_index remove_index].to_set.freeze

        REFERENCE_ACTIONS = %i[add_reference remove_reference add_belongs_to remove_belongs_to].to_set.freeze

        FOREIGN_KEY_ACTIONS = %i[add_foreign_key remove_foreign_key].to_set.freeze

        ALL_ACTIONS = (
          SINGLE_TABLE_ACTIONS | COLUMN_ACTIONS | INDEX_ACTIONS |
          REFERENCE_ACTIONS | FOREIGN_KEY_ACTIONS
        ).freeze

        def on_call_node_enter(node)
          return unless node.receiver.nil? && ALL_ACTIONS.include?(node.name)

          args = node.arguments&.arguments || []
          table = string_or_symbol(args[0])

          if SINGLE_TABLE_ACTIONS.include?(node.name)
            extract_table_action(node, table, args)
          elsif COLUMN_ACTIONS.include?(node.name)
            extract_column_action(node, table, args)
          elsif INDEX_ACTIONS.include?(node.name)
            extract_index_action(node, table, args)
          elsif REFERENCE_ACTIONS.include?(node.name)
            extract_reference_action(node, table, args)
          elsif FOREIGN_KEY_ACTIONS.include?(node.name)
            extract_foreign_key_action(node, table, args)
          end
        end

        private

        def extract_table_action(node, table, args)
          options = extract_keyword_options(node)
          result = {
            action:   node.name,
            table:    table,
            options:  options,
            location: node.location.start_line
          }

          # rename_table has a second positional arg for the new name
          if node.name == :rename_table
            result[:new_name] = string_or_symbol(args[1])
          end

          @results << result
        end

        def extract_column_action(node, table, args)
          column = string_or_symbol(args[1])
          options = extract_keyword_options(node)

          result = {
            action:   node.name,
            table:    table,
            column:   column,
            options:  options,
            location: node.location.start_line
          }

          case node.name
          when :add_column
            result[:column_type] = symbol_value(args[2])
          when :rename_column
            result[:new_name] = string_or_symbol(args[2])
          when :change_column
            result[:column_type] = symbol_value(args[2])
          end

          @results << result
        end

        def extract_index_action(node, table, args)
          columns = resolve_columns(args[1])
          options = extract_keyword_options(node)

          @results << {
            action:   node.name,
            table:    table,
            columns:  columns,
            options:  options,
            location: node.location.start_line
          }
        end

        def extract_reference_action(node, table, args)
          ref = string_or_symbol(args[1])
          options = extract_keyword_options(node)

          @results << {
            action:   node.name,
            table:    table,
            ref:      ref,
            options:  options,
            location: node.location.start_line
          }
        end

        def extract_foreign_key_action(node, table, args)
          to_table = string_or_symbol(args[1])
          options = extract_keyword_options(node)

          @results << {
            action:   node.name,
            table:    table,
            to_table: to_table,
            options:  options,
            location: node.location.start_line
          }
        end

        def string_or_symbol(node)
          case node
          when Prism::StringNode then node.unescaped
          when Prism::SymbolNode then node.value
          else nil
          end
        end

        def symbol_value(node)
          case node
          when Prism::SymbolNode then node.value
          when Prism::StringNode then node.unescaped
          else nil
          end
        end

        def resolve_columns(node)
          case node
          when Prism::ArrayNode
            node.elements.filter_map { |e| string_or_symbol(e) }
          when Prism::StringNode
            [ node.unescaped ]
          when Prism::SymbolNode
            [ node.value ]
          else []
          end
        end
      end
    end
  end
end
