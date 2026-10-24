# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # What a replay needs beyond the DSL listeners: down-only and revert ranges,
      # a block's `t.` statements, and the top-level statements the DSL listeners leave out.
      class MigrationReplayListener < BaseListener
        include SchemaDslListener::TableBlock

        def on_def_node_enter(node)
          return unless node.name == :down

          @results << { kind: :down, range: node.location.start_line..node.location.end_line }
        end

        # A block's `t.` methods, as the statement each runs on the block's table.
        TABLE_OPS = {
          remove: :remove_columns, remove_references: :remove_reference, remove_belongs_to: :remove_reference,
          remove_index: :remove_index, rename: :rename_column, remove_timestamps: :remove_columns,
          change: :change_column, change_default: :change_column_default, change_null: :change_column_null,
          timestamps: :add_timestamps, check_constraint: :add_check_constraint, remove_check_constraint: :remove_check_constraint,
          remove_unique_constraint: :remove_unique_constraint
        }.freeze

        def on_call_node_enter(node)
          note_block(node)
          args = node.arguments&.arguments || []
          if %i[down revert].include?(node.name) && node.block
            @results << { kind: node.name, range: node.location.start_line..node.location.end_line }
          elsif node.name == :revert && node.receiver.nil? && args.any?
            # `revert SomeMigration` runs another file's statements inverted, which this file does not hold.
            @results << { kind: :not_replayed, location: node.location.start_line }
          elsif TABLE_OPS[node.name] == :remove_reference && table_receiver?(node.receiver)
            # Table#remove_references drops each name it is given.
            args.reject { |arg| arg.is_a?(Prism::KeywordHashNode) }.each do |arg|
              @results << statement(node, :remove_reference, [ arg, *args.grep(Prism::KeywordHashNode) ]).merge(block: true)
            end
          elsif TABLE_OPS.key?(node.name) && table_receiver?(node.receiver)
            @results << statement(node, TABLE_OPS[node.name], args).merge(block: true)
          elsif %i[create_join_table drop_join_table].include?(node.name) && (node.receiver.nil? || node.receiver.is_a?(Prism::LocalVariableReadNode))
            tables = args.reject { |arg| arg.is_a?(Prism::KeywordHashNode) }.first(2).map { |arg| literal_string(arg) }
            @results << { action: node.name, tables: tables, options: extract_keyword_options(node),
                          location: node.location.start_line }
          elsif TOP_LEVEL.include?(node.name) && node.receiver.nil?
            @results << top_level(node, args)
          # shortcut: only a migration's own execute is read, bare or on self, not SQL run another way (a connection call, an app's DB helper); read those if an app needs them.
          elsif node.name == :execute && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
            sql_node = args.first
            sql_node = sql_node.receiver if sql_node.is_a?(Prism::CallNode) && sql_node.name == :squish && sql_node.arguments.nil?
            statements = sql_statements(sql_node)
            # SQL built at run time that creates or drops a table is counted as not replayed.
            if statements.nil?
              literal = sql_node.respond_to?(:parts) ? sql_node.parts.grep(Prism::StringNode).map(&:unescaped).join : ""
              @results << { kind: :not_replayed, location: node.location.start_line } if literal.match?(/\b(?:CREATE(?:\s+UNLOGGED)?|DROP)\s+TABLE\b/i)
              return
            end
            statements.each do |sql|
              if (match = DROP_TABLE.match(sql))
                match[1].split(",").each do |name|
                  @results << { action: :drop_table, table: name.strip.delete('"`').split(".").last, options: match[2] ? { force: :cascade } : {},
                                location: node.location.start_line }
                end
              elsif sql.match?(CREATE_TABLE)
                @results << { action: :create_table_sql, sql: sql, location: node.location.start_line }
              end
            end
          end
        end

        TOP_LEVEL = %i[remove_columns add_timestamps rename_index add_check_constraint remove_check_constraint
                       add_unique_constraint remove_unique_constraint].to_set.freeze
        DROP_TABLE = /\A\s*DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?((?:[\w."`]+\s*,\s*)*[\w."`]+)(?:\s+(?:(CASCADE)|RESTRICT))?\s*\z/i
        CREATE_TABLE = /\A\s*CREATE\s+(?:UNLOGGED\s+)?TABLE\s/i

        private

        # A literal SQL string's statements, which drop or create tables here; nil for a string built at run time.
        def sql_statements(node)
          sql = case node
          when Prism::StringNode then node.unescaped
          # A squiggly heredoc over several lines parses as one string per line.
          when Prism::InterpolatedStringNode then adjacent_literals(node)
          end
          sql.split(";") unless sql.nil? || sql == RailsAiContext::Confidence::INFERRED
        end

        # A statement naming a table it cannot read is counted, never given another table.
        def top_level(node, args)
          table = literal_string(args.first)
          return { kind: :not_replayed, location: node.location.start_line } unless table

          statement(node, node.name, args.drop(1)).merge(table: table)
        end

        def statement(node, action, args)
          positional = args.reject { |arg| arg.is_a?(Prism::KeywordHashNode) }
          names = positional.map { |arg| literal_string(arg) }
          result = { action: action, options: extract_keyword_options(node), location: node.location.start_line }
          case action
          when :remove_columns then result[:columns] = node.name == :remove_timestamps ? %w[created_at updated_at] : names
          when :remove_reference then result[:ref] = names[0]
          # remove_index takes one column or an array of them.
          when :remove_index then result[:columns] = literal_strings(positional.first)
          when :rename_column then result.merge!(column: names[0], new_name: names[1])
          when :rename_index then result.merge!(old_name: names[0], new_name: names[1])
          when :change_column
            result.merge!(column: names[0], column_type: names[1], **default_fields(node))
          when :change_column_null then result.merge!(column: names[0], null: boolean_value(positional[1]))
          when :change_column_default
            result[:column] = names[0]
            result.merge!(new_default_fields(node, positional[1]))
          when :add_timestamps then result.merge!(default_fields(node))
          when :add_check_constraint, :remove_check_constraint then result[:expression] = names[0]
          when :add_unique_constraint, :remove_unique_constraint then result[:columns] = literal_strings(positional.first) if positional.first
          end
          result
        end
      end
    end
  end
end
