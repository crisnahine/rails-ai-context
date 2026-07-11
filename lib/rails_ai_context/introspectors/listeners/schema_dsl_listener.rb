# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects schema.rb DSL patterns via Prism AST:
      # create_table, t.string, t.index, add_foreign_key, create_enum
      class SchemaDslListener < BaseListener
        COLUMN_TYPES = %w[
          string integer text boolean datetime date decimal float binary
          references belongs_to jsonb json uuid bigint timestamp timestamptz time
          inet cidr macaddr hstore ltree numrange tsrange daterange
          bit bit_varying money oid xml point line lseg box path
          polygon circle interval serial tsvector virtual primary_key
        ].to_set.freeze

        def on_call_node_enter(node)
          if node.receiver.nil?
            extract_top_level_call(node)
          elsif column_call?(node)
            extract_column(node)
          elsif index_call?(node)
            extract_index(node)
          elsif check_constraint_call?(node)
            extract_check_constraint(node)
          end
        end

        private

        def extract_top_level_call(node)
          case node.name
          when :create_table
            extract_create_table(node)
          when :add_foreign_key
            extract_foreign_key(node)
          when :create_enum
            extract_enum(node)
          when :add_index
            extract_top_level_add_index(node)
          when :add_check_constraint
            extract_top_level_check_constraint(node)
          end
        end

        def extract_create_table(node)
          args = node.arguments&.arguments || []
          table_arg = args.first
          return unless table_arg.is_a?(Prism::StringNode)

          @results << {
            type:     :create_table,
            table:    table_arg.unescaped,
            # id: false / id: :uuid / primary_key: ... decide whether the
            # implicit primary-key column exists and what to call it.
            options:  extract_keyword_options(node),
            location: node.location.start_line
          }
        end

        def extract_foreign_key(node)
          args = node.arguments&.arguments || []
          from_arg = args[0]
          to_arg = args[1]
          return unless from_arg.is_a?(Prism::StringNode) && to_arg.is_a?(Prism::StringNode)

          @results << {
            type:     :foreign_key,
            from:     from_arg.unescaped,
            to:       to_arg.unescaped,
            location: node.location.start_line
          }
        end

        def extract_enum(node)
          args = node.arguments&.arguments || []
          name_arg = args[0]
          values_arg = args[1]
          return unless name_arg.is_a?(Prism::StringNode)

          values = case values_arg
          when Prism::ArrayNode
            values_arg.elements.filter_map { |e|
              e.is_a?(Prism::StringNode) ? e.unescaped : nil
            }
          else []
          end

          @results << {
            type:     :enum,
            name:     name_arg.unescaped,
            values:   values,
            location: node.location.start_line
          }
        end

        def extract_top_level_add_index(node)
          args = node.arguments&.arguments || []
          table_arg = args[0]
          return unless table_arg.is_a?(Prism::StringNode)

          columns = resolve_index_columns(args[1])
          options = extract_keyword_options(node)

          @results << {
            type:     :add_index,
            table:    table_arg.unescaped,
            columns:  columns,
            options:  options,
            location: node.location.start_line
          }
        end

        def extract_top_level_check_constraint(node)
          args = node.arguments&.arguments || []
          table_arg = args[0]
          expr_arg = args[1]
          return unless table_arg.is_a?(Prism::StringNode) && expr_arg.is_a?(Prism::StringNode)

          @results << {
            type:       :add_check_constraint,
            table:      table_arg.unescaped,
            expression: expr_arg.unescaped,
            location:   node.location.start_line
          }
        end

        def check_constraint_call?(node)
          node.name == :check_constraint && receiver_is_t?(node.receiver)
        end

        def extract_check_constraint(node)
          args = node.arguments&.arguments || []
          expr_arg = args.first
          return unless expr_arg.is_a?(Prism::StringNode)

          @results << {
            type:       :check_constraint,
            expression: expr_arg.unescaped,
            location:   node.location.start_line
          }
        end

        def column_call?(node)
          return false unless COLUMN_TYPES.include?(node.name.to_s)
          receiver_is_t?(node.receiver)
        end

        def index_call?(node)
          node.name == :index && receiver_is_t?(node.receiver)
        end

        def receiver_is_t?(receiver)
          case receiver
          when Prism::CallNode
            receiver.name == :t && receiver.receiver.nil?
          when Prism::LocalVariableReadNode
            receiver.name == :t
          else
            false
          end
        end

        def extract_column(node)
          args = node.arguments&.arguments || []
          name_arg = args.first
          return unless name_arg.is_a?(Prism::StringNode) || name_arg.is_a?(Prism::SymbolNode)

          col_name = case name_arg
          when Prism::StringNode then name_arg.unescaped
          when Prism::SymbolNode then name_arg.value
          end

          options = extract_keyword_options(node)

          @results << {
            type:        :column,
            table:       nil,
            column_type: node.name.to_s,
            name:        col_name,
            options:     options,
            location:    node.location.start_line
          }
        end

        def extract_index(node)
          args = node.arguments&.arguments || []
          columns = resolve_index_columns(args.first)
          options = extract_keyword_options(node)

          @results << {
            type:     :index,
            columns:  columns,
            options:  options,
            location: node.location.start_line
          }
        end

        def resolve_index_columns(arg)
          case arg
          when Prism::ArrayNode
            arg.elements.filter_map { |e|
              case e
              when Prism::StringNode then e.unescaped
              when Prism::SymbolNode then e.value
              else nil
              end
            }
          when Prism::StringNode
            [ arg.unescaped ]
          when Prism::SymbolNode
            [ arg.value ]
          else []
          end
        end
      end
    end
  end
end
