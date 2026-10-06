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
          timestamps: :add_timestamps, check_constraint: :add_check_constraint, remove_check_constraint: :remove_check_constraint
        }.freeze

        def on_call_node_enter(node)
          note_block(node)
          args = node.arguments&.arguments || []
          if %i[down revert].include?(node.name) && node.block
            @results << { kind: node.name, range: node.location.start_line..node.location.end_line }
          elsif node.name == :revert && node.receiver.nil? && args.any?
            # `revert SomeMigration` runs another file's statements inverted, which this file does not hold.
            @results << { kind: :not_replayed, location: node.location.start_line }
          elsif TABLE_OPS[node.name] == :remove_reference && block_column?(node.receiver)
            # Table#remove_references drops each name it is given.
            args.reject { |arg| arg.is_a?(Prism::KeywordHashNode) }.each do |arg|
              @results << statement(node, :remove_reference, [ arg, *args.grep(Prism::KeywordHashNode) ]).merge(block: true)
            end
          elsif TABLE_OPS.key?(node.name) && block_column?(node.receiver)
            @results << statement(node, TABLE_OPS[node.name], args).merge(block: true)
          elsif node.name == :create_join_table && (node.receiver.nil? || node.receiver.is_a?(Prism::LocalVariableReadNode))
            tables = args.reject { |arg| arg.is_a?(Prism::KeywordHashNode) }.first(2).map { |arg| literal_string(arg) }
            @results << { action: :create_join_table, tables: tables, options: extract_keyword_options(node),
                          location: node.location.start_line }
          elsif %i[remove_columns add_timestamps rename_index add_check_constraint remove_check_constraint].include?(node.name) && node.receiver.nil?
            @results << top_level(node, args)
          elsif node.name == :execute && node.receiver.nil?
            statements = sql_statements(args.first)
            # SQL built at run time that creates or drops a table is counted as not replayed.
            if statements.nil?
              literal = args.first.respond_to?(:parts) ? args.first.parts.grep(Prism::StringNode).map(&:unescaped).join : ""
              @results << { kind: :not_replayed, location: node.location.start_line } if literal.match?(/\b(?:CREATE|DROP)\s+TABLE\b/i)
              return
            end
            statements.each do |sql|
              if (match = DROP_TABLE.match(sql))
                match[1].split(",").each do |name|
                  @results << { action: :drop_table, table: name.strip.delete('"`').split(".").last, options: {}, location: node.location.start_line }
                end
              elsif sql.match?(CREATE_TABLE)
                @results << { action: :create_table_sql, sql: sql, location: node.location.start_line }
              end
            end
          end
        end

        DROP_TABLE = /\A\s*DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?((?:[\w."`]+\s*,\s*)*[\w."`]+)(?:\s+(?:CASCADE|RESTRICT))?\s*\z/i
        CREATE_TABLE = /\A\s*CREATE\s+TABLE\s/i

        private

        # A literal SQL string's statements, which drop or create tables here; nil for a string built at run time.
        def sql_statements(node)
          node = node.receiver if node.is_a?(Prism::CallNode) && node.name == :squish && node.arguments.nil?
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
          when :change_column then result.merge!(column: names[0], column_type: names[1])
          when :change_column_null then result.merge!(column: names[0], null: boolean_value(positional[1]))
          when :change_column_default
            result[:column] = names[0]
            result[:new_default] = extract_value(positional[1]) if positional[1]
          when :add_timestamps then result.merge!(default_source: default_source(node), default_proc: proc_default?(node))
          when :add_check_constraint, :remove_check_constraint then result[:expression] = names[0]
          end
          result
        end

        # The block parameter a create_table body names `t`, whether it reads
        # as a local variable or as a bare call.
        def block_column?(receiver)
          case receiver
          when Prism::LocalVariableReadNode then receiver.name == :t && table_param?(receiver)
          when Prism::CallNode then receiver.name == :t && receiver.receiver.nil?
          else false
          end
        end
      end
    end
  end
end
