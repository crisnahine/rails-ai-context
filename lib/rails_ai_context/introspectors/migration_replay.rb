# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Reconstructs the table structure by replaying db/migrate in order, for
    # an app that committed neither schema.rb nor structure.sql. Best-effort
    # by nature, but it follows the same conventions as the dump readers
    # (SchemaConventions), so the same app answers the same columns whichever
    # file it happened to commit.
    module MigrationReplay
      module_function

      # @return [Hash] table name => { columns:, indexes:, foreign_keys: }
      def tables(migrations_dir, pk_type:)
        tables = {}
        Dir.glob(File.join(migrations_dir, "*.rb")).sort.each do |path|
          content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
          next unless content

          replay(content, tables, pk_type: pk_type)
        end

        tables.delete("ar_internal_metadata")
        tables.delete("schema_migrations")
        tables
      end

      def replay(content, tables, pk_type:)
        ast_data = SourceIntrospector.walk_source(content, {
          migration: -> { Listeners::MigrationDslListener.new },
          schema: -> { Listeners::SchemaDslListener.new }
        })

        current_table = nil
        # parse_string returns nil for an oversize source, and a migration can
        # sit between max_file_size and max_schema_file_size.
        parsed = AstCache.parse_string(content)
        return unless parsed

        root = parsed.value

        # A `def down` says what to undo, not what the schema holds. Replaying
        # it alongside `up` cancels the migration out: the ordinary
        # up-creates/down-drops pair erased a table the app really has, and the
        # reverse pair invented one it dropped.
        down_ranges = []
        find_down_bodies(root, down_ranges)
        all_entries = (ast_data[:migration] + ast_data[:schema])
          .reject { |r| down_ranges.any? { |range| range.cover?(r[:location]) } }
          .sort_by { |r| r[:location] }

        # t.timestamps has no column-name argument, so SchemaDslListener skips
        # it; a direct walk finds the call sites. The walk sees the whole file,
        # so a down body's timestamps would be attributed to the last table
        # created on the way up - the same filter has to apply here.
        timestamps_lines = Set.new
        find_timestamps_calls(root, timestamps_lines)
        timestamps_lines.delete_if { |line| down_ranges.any? { |range| range.cover?(line) } }

        all_entries.each do |entry|
          if entry.key?(:action)
            if entry[:action] == :create_table
              current_table = entry[:table]
            elsif entry[:action] == :drop_table || entry[:action] == :rename_table
              current_table = nil
            end
            apply_migration_action(entry, tables, pk_type)
          elsif entry[:type] == :create_table
            current_table = entry[:table]
            seed_table(tables, current_table, entry[:options], pk_type)
          elsif entry[:type] == :column && current_table
            apply_schema_column(entry, current_table, tables, pk_type)
          elsif entry[:type] == :index && current_table
            apply_schema_index(entry, current_table, tables)
          end
        end

        timestamps_lines.each do |line_num|
          table_for_line = nil
          all_entries.select { |e| (e.key?(:action) && e[:action] == :create_table) || e[:type] == :create_table }
            .each do |ct|
              table_for_line = ct[:table] if ct[:location] < line_num
            end
          if table_for_line && tables[table_for_line]
            tables[table_for_line][:columns].concat(SchemaConventions.timestamps_columns)
          end
        end
      end

      # Line ranges of every `def down` / `def self.down` in the file.
      # Every way a migration spells "this part only runs on the way down":
      # `def down`, `reversible { |dir| dir.down { ... } }`, and `revert`.
      def find_down_bodies(node, ranges)
        case node
        when Prism::DefNode
          ranges << (node.location.start_line..node.location.end_line) if node.name == :down
        when Prism::CallNode
          if %i[down revert].include?(node.name) && node.block
            ranges << (node.location.start_line..node.location.end_line)
          end
        end
        node.child_nodes.compact.each { |child| find_down_bodies(child, ranges) }
      end

      def find_timestamps_calls(node, lines)
        case node
        when Prism::CallNode
          if node.name == :timestamps && node.receiver
            receiver = node.receiver
            is_t = case receiver
            when Prism::LocalVariableReadNode then receiver.name == :t
            when Prism::CallNode then receiver.name == :t && receiver.receiver.nil?
            else false
            end
            lines << node.location.start_line if is_t
          end
        end
        node.child_nodes.compact.each { |child| find_timestamps_calls(child, lines) }
      end

      # A replayed create_table implies its id column the way a dumped one
      # does; leaving it out gave the same app two answers depending on which
      # file it committed. A table the replay cannot name it cannot report -
      # Canvas calls `create_table table_name do |t|` with a local computed at
      # run time, and keeping the entry put a nil key in the schema that took a
      # whole context run down the moment a serializer sorted the names.
      def seed_table(tables, table, options, pk_type)
        return if table.nil? || table.to_s.empty?

        tables[table] ||= {
          columns: implicit_pk_columns(options, pk_type),
          indexes: [],
          foreign_keys: []
        }
      end

      def implicit_pk_columns(options, pk_type)
        SchemaConventions.implicit_primary_key(options || {}, pk_type).map do |pk|
          { name: pk[:name], type: pk[:type], null: false, primary_key: true }
        end
      end

      def apply_migration_action(entry, tables, pk_type)
        case entry[:action]
        when :create_table
          seed_table(tables, entry[:table], entry[:options], pk_type)

        when :drop_table
          tables.delete(entry[:table])

        when :rename_table
          old = entry[:table]
          new_name = entry[:new_name]
          tables[new_name] = tables.delete(old) if old && new_name && tables[old]

        when :add_column
          table = entry[:table]
          return unless tables[table]
          col_name = entry[:column]
          col_type = entry[:column_type]
          tables[table][:columns].reject! { |c| c[:name] == col_name }
          col = { name: col_name, type: col_type }
          opts = entry[:options] || {}
          col[:null] = false if opts[:null] == false
          col[:default] = SchemaConventions.format_default(opts[:default]) if opts.key?(:default)
          tables[table][:columns] << col

        when :remove_column
          table = entry[:table]
          tables[table][:columns]&.reject! { |c| c[:name] == entry[:column] } if tables[table]

        when :rename_column
          table = entry[:table]
          if tables[table]
            col = tables[table][:columns].find { |c| c[:name] == entry[:column] }
            col[:name] = entry[:new_name] if col
          end

        when :change_column
          table = entry[:table]
          if tables[table]
            col = tables[table][:columns].find { |c| c[:name] == entry[:column] }
            col[:type] = entry[:column_type] if col && entry[:column_type]
          end

        when :change_column_default
          table = entry[:table]
          if tables[table]
            col = tables[table][:columns].find { |c| c[:name] == entry[:column] }
            if col
              opts = entry[:options] || {}
              if opts.key?(:to)
                raw = opts[:to]
                col[:default] = raw == nil ? nil : SchemaConventions.format_default(raw)
              end
            end
          end

        when :change_column_null
          table = entry[:table]
          if tables[table]
            col = tables[table][:columns].find { |c| c[:name] == entry[:column] }
            unless col.nil? || entry[:null].nil?
              # The columns hash marks nullability by presence: only null:
              # false is stored, so allowing NULL again removes the mark.
              entry[:null] ? col.delete(:null) : col[:null] = false
            end
          end

        when :add_index
          table = entry[:table]
          return unless tables[table]
          cols = entry[:columns]&.map(&:to_s) || []
          opts = entry[:options] || {}
          unique = opts[:unique] == true
          idx_name = opts[:name]&.to_s
          tables[table][:indexes] << { name: idx_name, columns: cols, unique: unique }.compact if cols.any?

        when :add_reference, :add_belongs_to
          table = entry[:table]
          return unless tables[table]
          col_name = SchemaConventions.reference_column_name(entry[:ref])
          tables[table][:columns].reject! { |c| c[:name] == col_name }
          col = { name: col_name, type: pk_type }
          opts = entry[:options] || {}
          col[:null] = false if opts[:null] == false
          tables[table][:columns] << col

        when :add_foreign_key
          from = entry[:table]
          to = entry[:to_table]
          return unless tables[from]
          opts = entry[:options] || {}
          tables[from][:foreign_keys] << SchemaConventions.foreign_key_entry(from, to, opts[:column], opts[:primary_key])
        end
      end

      def apply_schema_column(entry, current_table, tables, pk_type)
        return unless tables[current_table]
        col_type = entry[:column_type]

        if %w[references belongs_to].include?(col_type)
          col = { name: SchemaConventions.reference_column_name(entry[:name]), type: pk_type }
          opts = entry[:options] || {}
          col[:null] = false if opts[:null] == false
          tables[current_table][:columns] << col
          return
        end

        # Skip non-column types
        return if %w[index check_constraint].include?(col_type)

        col = { name: entry[:name], type: col_type }
        opts = entry[:options] || {}
        col[:null] = false if opts[:null] == false
        col[:default] = SchemaConventions.format_default(opts[:default]) if opts.key?(:default) && opts[:default] != RailsAiContext::Confidence::INFERRED
        col[:array] = true if opts[:array] == true
        tables[current_table][:columns] << col
      end

      def apply_schema_index(entry, current_table, tables)
        return unless tables[current_table]
        cols = entry[:columns]&.map(&:to_s) || []
        opts = entry[:options] || {}
        unique = opts[:unique] == true
        idx_name = opts[:name]&.to_s
        tables[current_table][:indexes] << { name: idx_name, columns: cols, unique: unique }.compact if cols.any?
      end
    end
  end
end
