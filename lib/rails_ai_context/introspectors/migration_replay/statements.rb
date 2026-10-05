# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module MigrationReplay
      # Applies one statement to the tables the way Rails runs it, whether a
      # migration calls it or a change_table block's `t` does.
      module Statements
        module_function

        # A change_column_default that names no new value leaves the default.
        NOT_GIVEN = Object.new.freeze

        def apply(entry, tables, pk_type)
          table = entry[:table]
          options = entry[:options] || {}
          case entry[:action]
          when :create_table
            options[:as].is_a?(String) ? create_table_as(tables, table, options[:as]) : seed_table(tables, table, options, pk_type)
          when :create_table_sql then tables.merge!(StructureSqlReader.parse(entry[:sql])[:tables])
          when :rename_index
            index = tables[table]&.dig(:indexes)&.find { |idx| idx[:name] == entry[:old_name] }
            index[:name] = entry[:new_name] if index && entry[:new_name]
          when :create_join_table then create_join_table(entry, tables, pk_type)
          when :drop_table then tables.delete(table)
          when :rename_table
            new_name = entry[:new_name]
            if table && new_name && tables[table]
              tables[new_name] = tables.delete(table)
              rename_table_indexes(tables[new_name], table, new_name)
            end
          when :add_column then add_column(tables[table], entry)
          when :add_timestamps then add_timestamps(tables, entry)
          when :remove_column then remove_columns_from(tables[table], [ entry[:column] ])
          when :remove_columns then remove_columns_from(tables[table], entry[:columns])
          when :remove_reference, :remove_belongs_to then remove_reference_from(tables[table], entry[:ref], options)
          when :rename_column then rename_column_in(tables, table, entry[:column], entry[:new_name])
          when :change_column
            col = column_in(tables, entry)
            col[:type] = entry[:column_type] if col && entry[:column_type]
          when :change_column_default then change_column_default(column_in(tables, entry), entry)
          when :change_column_null
            col = column_in(tables, entry)
            unless col.nil? || entry[:null].nil?
              # Only null: false is stored, so allowing NULL again removes the mark.
              entry[:null] ? col.delete(:null) : col[:null] = false
            end
          when :add_index then apply_schema_index(entry, table, tables)
          when :remove_index then remove_index_from(tables[table], entry[:columns], options)
          when :add_reference, :add_belongs_to
            apply_reference(tables, table, entry[:ref], entry[:options], pk_type, version: entry[:migration_version])
          when :remove_foreign_key then remove_foreign_key_from(tables[table], entry[:to_table], options)
          when :add_foreign_key
            fk = SchemaConventions.foreign_key_entry(table, entry[:to_table], options[:column], options[:primary_key])
            tables[table][:foreign_keys] << fk if tables[table]
          end
        end

        # A create_table implies its key column the way a dump does. A table
        # the replay cannot name is left out: a nil key breaks every reader.
        def seed_table(tables, table, options, pk_type)
          return if table.nil? || table.to_s.empty?

          tables[table] ||= {
            columns: implicit_pk_columns(options, pk_type),
            indexes: [],
            foreign_keys: []
          }
          key = (options || {})[:primary_key]
          tables[table][:primary_key] = SchemaConventions.primary_key_value(key) if key.is_a?(Array)
        end

        AS_SELECT = /\A\s*SELECT\s+(.+?)\s+FROM\s+["`]?(\w+)["`]?/im

        # CREATE TABLE ... AS SELECT: the selected columns, typed by the table
        # they come from, with no key; a column it cannot trace is left out.
        def create_table_as(tables, table, sql)
          return if table.nil? || table.to_s.empty?

          list, from = AS_SELECT.match(sql)&.captures
          source = Array(tables.dig(from, :columns))
          picked = if list.to_s.strip == "*" then source
          else
            list.to_s.split(",").filter_map do |item|
              expression, alias_name = item.strip.split(/\s+AS\s+/i, 2)
              key = expression.to_s.split(".").last.to_s.delete('"`')
              source.find { |c| c[:name] == key }&.merge(name: (alias_name || key).delete('"`'))
            end
          end
          tables[table] = { columns: picked.map { |c| c.except(:primary_key, :null) }, indexes: [], foreign_keys: [] }
        end

        def implicit_pk_columns(options, pk_type)
          SchemaConventions.implicit_primary_key(options || {}, pk_type).map do |pk|
            { name: pk[:name], type: pk[:type], null: false, primary_key: true }
          end
        end

        # A computed column name is counted in the note instead: a nil name trips every reader.
        def add_column(table_data, entry)
          return unless table_data && entry[:column]

          table_data[:columns].reject! { |c| c[:name] == entry[:column] }
          col = { name: entry[:column], type: entry[:column_type] }
          opts = entry[:options] || {}
          col[:null] = false if opts[:null] == false
          col[:default] = SchemaConventions.format_default(opts[:default]) if opts.key?(:default)
          table_data[:columns] << col
        end

        # The new default is to: of a from:/to: pair, or the positional value
        # (extract_new_default_value, 7.0 and 8.1); an unreadable one is left.
        def change_column_default(col, entry)
          opts = entry[:options] || {}
          new_default = if opts.key?(:to) then opts[:to]
          elsif entry.key?(:new_default) then entry[:new_default]
          else NOT_GIVEN
          end
          return if col.nil? || new_default.equal?(NOT_GIVEN) || new_default == RailsAiContext::Confidence::INFERRED

          col[:default] = SchemaConventions.format_default(new_default)
        end

        def column_in(tables, entry)
          tables[entry[:table]]&.dig(:columns)&.find { |c| c[:name] == entry[:column] }
        end

        def apply_schema_column(entry, current_table, tables, pk_type)
          return unless tables[current_table]
          col_type = entry[:column_type]

          if %w[references belongs_to].include?(col_type)
            apply_reference(tables, current_table, entry[:name], entry[:options], pk_type,
                            version: entry[:migration_version])
            return
          end

          # Skip non-column types
          return if %w[index check_constraint].include?(col_type)

          col = { name: entry[:name], type: col_type }
          opts = entry[:options] || {}
          col[:null] = false if opts[:null] == false
          default = declared_default(opts, entry)
          col[:default] = SchemaConventions.format_default(default) if opts.key?(:default) && default != RailsAiContext::Confidence::INFERRED
          col[:array] = true if opts[:array] == true
          if entry[:virtual]
            col[:generated] = opts[:as].is_a?(String) ? opts[:as] : ""
            col[:stored] = opts[:stored] == true
          end
          # Only one branch of an if runs, so a second declaration of a name replaces the first.
          tables[current_table][:columns].reject! { |c| c[:name] == col[:name] }
          tables[current_table][:columns] << col
          return unless opts[:index] && opts[:index] != false

          # TableDefinition#column indexes a column declared with index: (7.0 to 8.1).
          index_opts = opts[:index].is_a?(Hash) ? opts[:index] : {}
          apply_schema_index({ columns: [ col[:name] ], options: index_opts }, current_table, tables)
        end

        # TableDefinition#timestamps and add_timestamps (7.0 and 8.1). Only a
        # table definition indexes them; add_timestamps adds the columns alone.
        def add_timestamps(tables, entry)
          table_data = tables[entry[:table]] or return
          options = entry[:options] || {}
          if options.key?(:default)
            default = declared_default(options, entry)
            options = default == RailsAiContext::Confidence::INFERRED ? options.except(:default) : options.merge(default: default)
          end
          stamps = SchemaConventions.timestamps_columns(options, version: entry[:migration_version])
          table_data[:columns].reject! { |c| stamps.any? { |stamp| stamp[:name] == c[:name] } }
          table_data[:columns].concat(stamps)
          return unless entry[:definition] && options[:index]

          stamps.each do |stamp|
            apply_schema_index({ columns: [ stamp[:name] ], options: options[:index].is_a?(Hash) ? options[:index] : {} },
                               entry[:table], tables)
          end
        end

        # A literal default, or a proc's source the way the dump readers report
        # it; any other expression is a value only the running migration knows.
        def declared_default(options, entry)
          value = options[:default]
          value == RailsAiContext::Confidence::INFERRED && entry[:default_proc] ? entry[:default_source] : value
        end

        # An index follows its column to the new name, and one Rails named for
        # the old columns is renamed for the new (rename_column_indexes, 7.0 to 8.1).
        def rename_index_columns(table_data, table, old_name, new_name)
          Array(table_data && table_data[:indexes]).each do |idx|
            next unless idx[:columns].include?(old_name)

            old_default = SchemaConventions.default_index_name(table, idx[:columns])
            idx[:columns] = idx[:columns].map { |col| col == old_name ? new_name.to_s : col }
            idx[:name] = SchemaConventions.default_index_name(table, idx[:columns]) if idx[:name] == old_default
          end
        end

        # An index Rails named for the old table takes the name for the new one;
        # a name the migration chose stays (rename_table_indexes, 7.0 and 8.1).
        def rename_table_indexes(table_data, old_table, new_table)
          Array(table_data[:indexes]).each do |idx|
            next unless idx[:name] == SchemaConventions.default_index_name(old_table, idx[:columns])

            idx[:name] = SchemaConventions.default_index_name(new_table, idx[:columns])
          end
        end

        def rename_column_in(tables, table, old_name, new_name)
          col = tables[table]&.dig(:columns)&.find { |c| c[:name] == old_name.to_s }
          return unless col && new_name

          col[:name] = new_name.to_s
          rename_index_columns(tables[table], table, old_name.to_s, new_name.to_s)
        end

        # remove_reference drops <ref>_id, and <ref>_type when polymorphic
        # (schema_statements.rb, 7.0 and 8.1); the database drops the index.
        def remove_reference_from(table_data, ref, options)
          return unless ref

          names = [ SchemaConventions.reference_column_name(ref) ]
          names << "#{ref}_type" if options[:polymorphic]
          remove_columns_from(table_data, names)
        end

        # The one index remove_index would drop, by name, by exact columns or
        # both (index_name_for_remove, 7.0 and 8.1); Rails raises on any other count.
        def remove_index_from(table_data, columns, options)
          return unless table_data

          cols = Array(columns).map(&:to_s)
          cols = Array(options[:column]).map(&:to_s) if cols.empty?
          name = options[:name]&.to_s
          return if name.nil? && cols.empty?

          matches = table_data[:indexes].select do |idx|
            (name.nil? || idx[:name].to_s == name) && (cols.empty? || Array(idx[:columns]) == cols)
          end
          table_data[:indexes].delete(matches.first) if matches.size == 1
        end

        # The key remove_foreign_key would drop (foreign_key_for, 8.1): by
        # to_table and column:, and a key on <to_table singular>_id first.
        def remove_foreign_key_from(table_data, to_table, options)
          return unless table_data

          to = (to_table || options[:to_table])&.to_s
          column = options[:column]&.to_s
          return if to.nil? && column.nil?

          keys = table_data[:foreign_keys].select do |fk|
            (to.nil? || fk[:to_table].to_s == to) && (column.nil? || fk[:column].to_s == column)
          end
          if column.nil?
            preferred = keys.select { |fk| fk[:column].to_s == "#{to.singularize}_id" }
            keys = preferred if preferred.any?
          end
          table_data[:foreign_keys].delete(keys.first) if keys.any?
        end

        # PostgreSQL and SQLite drop every index holding a dropped column.
        # ponytail: MySQL shrinks a composite index instead; split by adapter if a MySQL app needs it.
        def remove_columns_from(table_data, names)
          return unless table_data

          names = names.compact.map(&:to_s)
          table_data[:columns].reject! { |c| names.include?(c[:name]) }
          table_data[:indexes].reject! { |idx| (Array(idx[:columns]) & names).any? }
          table_data[:foreign_keys].reject! { |fk| names.include?(fk[:column].to_s) }
        end

        # create_join_table (7.0 and 8.1): no id, two non-null unindexed references,
        # named by table_name: or derive_join_table_name, which it returns for the block.
        def create_join_table(entry, tables, pk_type)
          first, second = entry[:tables]
          return nil unless first && second

          options = entry[:options] || {}
          name = (options[:table_name] || HabtmJoinTables.join_table_name(first, second)).to_s
          seed_table(tables, name, { id: false }, pk_type)
          column_options = { null: false, index: false }.merge(options[:column_options].is_a?(Hash) ? options[:column_options] : {})
          [ first, second ].each { |t| apply_reference(tables, name, t.to_s.singularize, column_options, pk_type) }
          name
        end

        def apply_reference(tables, table, name, options, pk_type, version: nil)
          return unless tables[table] && name

          ref = SchemaConventions.reference_definition(table, name, options, pk_type, version: version)
          ref[:columns].each do |col|
            tables[table][:columns].reject! { |c| c[:name] == col[:name] }
            tables[table][:columns] << col
          end
          add_reference_foreign_key(tables[table], table, name, options || {})
          return unless ref[:index]

          tables[table][:indexes].reject! { |idx| idx[:name] == ref[:index][:name] }
          tables[table][:indexes] << ref[:index]
        end

        # ReferenceDefinition's foreign_key: (7.0 to 8.1): true points at the
        # pluralized name, a hash may name to_table: and primary_key:.
        def add_reference_foreign_key(table_data, table, name, options)
          fk = options[:foreign_key]
          return if !fk || options[:polymorphic]

          fk = {} unless fk.is_a?(Hash)
          to = fk[:to_table] || name.to_s.pluralize
          return if to == RailsAiContext::Confidence::INFERRED

          (table_data[:foreign_keys] ||= []) <<
            SchemaConventions.foreign_key_entry(table, to.to_s, SchemaConventions.reference_column_name(name), fk[:primary_key])
        end

        def apply_schema_index(entry, current_table, tables)
          return unless tables[current_table]
          cols = entry[:columns]&.map(&:to_s) || []
          opts = entry[:options] || {}
          unique = opts[:unique] == true
          return if cols.empty?

          idx_name = opts[:name]&.to_s || SchemaConventions.default_index_name(current_table, entry[:string_key] ? cols.first : cols)
          where = opts[:where] if opts[:where].is_a?(String)
          tables[current_table][:indexes] << { name: idx_name, columns: cols, unique: unique, where: where }.compact
        end
      end
    end
  end
end
