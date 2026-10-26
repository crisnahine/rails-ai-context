# frozen_string_literal: true

require "bigdecimal"
require "set"
require "strscan"

module RailsAiContext
  module Introspectors
    module MigrationReplay
      # Applies one statement to the tables the way Rails runs it, whether a
      # migration calls it or a change_table block's `t` does.
      module Statements
        module_function

        # A change_column_default that names no new value leaves the default.
        NOT_GIVEN = Object.new.freeze

        # rails_version: the app's; an unknown one takes the newest rules. server: :mysql or :mariadb, nil when unknown.
        def apply(entry, tables, pk_type, adapter: nil, rails_version: nil, server: nil)
          steps = sqlite_rebuilds(entry, tables[entry[:table]], adapter, rails_version) if family(adapter) == :sqlite
          keeping_key_order(tables[entry[:table]], steps) { apply_statement(entry, tables, pk_type, adapter, rails_version, server) }
        end

        # A table keeps its keys in the order it declares them; PRAGMA foreign_key_list lists the last declared first.
        def keeping_key_order(table_data, steps)
          before = table_data&.dig(:foreign_keys)&.dup
          made = yield
          turn_keys(table_data, before, steps) if before && steps&.any?
          made
        end

        # Each rebuild declares the kept keys again in the order SQLite lists them, so it turns them around; the
        # rebuild add_foreign_key runs declares its new key last (alter_table, copy_table, 7.0 to 8.1).
        def turn_keys(table_data, before, steps)
          after = table_data[:foreign_keys] or return
          added = after.reject { |fk| before.any? { |old| old.equal?(fk) } }
          order = after.reject { |fk| added.any? { |new| new.equal?(fk) } }
          steps.each do |step|
            order = order.reverse
            order += added if step == :add_key
          end
          after.replace(steps.include?(:add_key) ? order : order + added)
        end

        # The SQLite adapter's calls for these each rebuild the table once (alter_table, 7.0 to 8.1).
        SQLITE_REBUILDS = %i[remove_column remove_columns rename_column change_column change_column_default change_column_null
                             add_check_constraint].freeze

        # The table rebuilds the SQLite adapter runs for a statement, one per call it makes, in order; :add_key is
        # add_foreign_key's. A statement inside create_table's block is part of the CREATE TABLE.
        def sqlite_rebuilds(entry, table_data, adapter, rails_version)
          return [] if table_data.nil? || entry[:definition]

          options = entry[:options] || {}
          case entry[:action]
          when :add_column then column_rebuilds(entry[:column_type], options, rails_version)
          when :add_timestamps then timestamps_rebuilds(options, entry[:migration_version], rails_version)
          when :add_reference, :add_belongs_to then reference_rebuilds(options, rails_version)
          when :remove_reference, :remove_belongs_to
            # remove_reference drops the key, then each column; SQLite's remove_column ignores if_exists:.
            key = options[:foreign_key] && !(options[:if_exists] == true && reference_key(table_data, entry[:ref], options).nil?)
            [ (:rebuild if key), :rebuild, (:rebuild if options[:polymorphic]) ].compact
          when :add_foreign_key then [ :add_key ]
          when :remove_foreign_key
            missing = options[:if_exists] == true && foreign_key_for(table_data, entry[:table], entry[:to_table], options, adapter, rails_version).nil?
            missing ? [] : [ :rebuild ]
          when :remove_check_constraint
            missing = options[:if_exists] == true && check_constraint_for(table_data[:check_constraints], entry[:table], entry[:expression], options[:name]).nil?
            missing ? [] : [ :rebuild ]
          when *SQLITE_REBUILDS then [ :rebuild ]
          else []
          end
        end

        # invalid_alter_table_type? (7.0 to 8.1): SQLite's ALTER TABLE cannot add a key, a NOT NULL column with no
        # default, or (7.2 on) a stored virtual column, so add_column rebuilds the table for those.
        def column_rebuilds(type, options, rails_version)
          type = type.to_s
          rebuild = type == "primary_key" || options[:primary_key] == true || (options[:null] == false && options[:default].nil?) ||
                    (type == "virtual" && options[:stored] == true && RailsVersion.at_least?(rails_version, "7.2"))
          rebuild ? [ :rebuild ] : []
        end

        # 7.1 on add both columns in one rebuild; 7.0 runs add_column for each, NOT NULL unless the migration (4.2 and older) or the call says otherwise.
        def timestamps_rebuilds(options, version, rails_version)
          return [ :rebuild ] if RailsVersion.at_least?(rails_version, "7.1")

          stamp = SchemaConventions.timestamps_columns(options.except(:default), version: version).first
          column_rebuilds("datetime", { null: stamp[:null], default: options[:default] }, rails_version) * 2
        end

        # ReferenceDefinition#add (7.0 to 8.1): add_column for the type column when polymorphic, then for the id column,
        # add_index, then add_foreign_key.
        def reference_rebuilds(options, rails_version)
          polymorphic = options[:polymorphic]
          steps = []
          steps += column_rebuilds("string", (polymorphic.is_a?(Hash) ? polymorphic : {}).merge(options.slice(:null)), rails_version) if polymorphic
          steps += column_rebuilds(options[:type], options, rails_version)
          steps << :add_key if options[:foreign_key] && !polymorphic
          steps
        end

        # The key a remove_reference's foreign_key: names: to_table from the hash or the plural name, on <ref>_id.
        def reference_key(table_data, ref, options)
          fk = options[:foreign_key].is_a?(Hash) ? options[:foreign_key] : {}
          foreign_keys_for(table_data, (fk[:to_table] || ref.to_s.pluralize).to_s, fk[:column] || SchemaConventions.reference_column_name(ref)).first
        end

        def apply_statement(entry, tables, pk_type, adapter, rails_version, server = nil)
          table = entry[:table]
          options = entry[:options] || {}
          case entry[:action]
          when :create_table
            options = legacy_key_options(options, entry, adapter)
            drop_table(tables, table, options, adapter) if options[:force]
            options[:as].is_a?(String) ? create_table_as(tables, table, options[:as], adapter, entry) : seed_table(tables, table, options, pk_type, default: SchemaConventions.key_default(options, entry), adapter: adapter,
                                                                                                                                                        version: entry[:migration_version])
          when :create_table_sql then create_table_sql(tables, entry, adapter, rails_version)
          when :rename_index
            index = tables[table]&.dig(:indexes)&.find { |idx| idx[:name] == entry[:old_name] }
            index[:name] = entry[:new_name] if index && entry[:new_name]
          when :create_join_table then create_join_table(entry, tables, pk_type, adapter, rails_version)
          when :drop_table then drop_table(tables, table, options, adapter)
          when :drop_join_table then tables.delete(join_table_name(entry))
          when :rename_table
            new_name = entry[:new_name]
            if table && new_name && tables[table]
              tables[new_name] = tables.delete(table)
              tables.each_value { |child| child[:inherits]&.map! { |parent| parent == table ? new_name : parent } }
              rename_table_indexes(tables[new_name], table, new_name, legacy: unshortened_index_names?(entry, rails_version))
              sequence = rename_table_sequences(tables[new_name], table, new_name, rails_version)
              follow_sequence(tables, *sequence) if sequence
              each_foreign_key(tables) do |fk|
                fk[:from_table] = new_name if fk[:from_table] == table
                fk[:to_table] = new_name if fk[:to_table] == table
              end
            end
          when :add_column then add_column(tables[table], entry, adapter, pk_type, rails_version)
          when :add_timestamps then add_timestamps(tables, entry, adapter, rails_version)
          when :remove_column then remove_columns_from(tables[table], [ entry[:column] ], adapter)
          when :remove_columns then remove_columns_from(tables[table], entry[:columns], adapter)
          when :remove_reference, :remove_belongs_to then remove_reference_from(tables[table], entry[:ref], options, adapter)
          when :rename_column then rename_column_in(tables, table, entry[:column], entry[:new_name], adapter, rails_version)
          when :change_column
            col = column_in(tables, entry)
            change_column(col, entry, adapter, rails_version)
            add_serial_index(tables[table], entry[:column_type], col, adapter)
          when :change_column_default, :change_column_null then alter_column(column_in(tables, entry), entry, adapter, rails_version)
          when :add_index then apply_schema_index(entry, table, tables, rails_version)
          when :remove_index then remove_index_from(tables[table], entry[:columns], options)
          when :add_reference, :add_belongs_to
            apply_reference(tables, table, entry[:ref], entry[:options], pk_type, version: entry[:migration_version], adapter: adapter,
                                                                                  rails_version: rails_version)
          when :remove_foreign_key
            # Compatibility::V8_0 (8.1) sets _skip_column_match on remove_foreign_key alone.
            column_match = !(entry[:migration_version] && (entry[:migration_version] <=> [ 8, 1 ]).negative?)
            tables[table][:foreign_keys].delete(foreign_key_for(tables[table], table, entry[:to_table], options, adapter, rails_version, server, column_match: column_match)) if tables[table]
          when :add_foreign_key then add_foreign_key(tables[table], table, entry[:to_table], options, adapter, rails_version)
          when :add_check_constraint then add_check_constraint(tables[table], table, entry[:expression], options, adapter)
          when :remove_check_constraint then remove_check_constraint(tables[table], table, entry[:expression], options)
          when :validate_check_constraint
            check_constraint_for(tables.dig(table, :check_constraints), table, options[:expression], options[:name])&.delete(:validate)
          when :validate_foreign_key
            # Only the PostgreSQL adapter defines it; the others raise NoMethodError and the migration stops.
            foreign_key_for(tables[table], table, entry[:to_table], options, adapter, rails_version, server)&.delete(:validate) if postgres_rules?(adapter)
          when :add_unique_constraint then add_unique_constraint(tables[table], entry[:columns], options, adapter, rails_version)
          when :change_column_comment then change_comment(column_in(tables, entry), entry, adapter)
          when :add_exclusion_constraint then add_exclusion_constraint(tables[table], entry[:expression], options, adapter)
          when :remove_exclusion_constraint then remove_exclusion_constraint(tables[table], entry[:expression], options)
          when :change_table_comment then change_comment(tables[table], entry, adapter)
          when :remove_unique_constraint then remove_unique_constraint(tables[table], table, entry[:columns], options)
          end
        end

        # PostgreSQL's DROP TABLE ... CASCADE also drops each table that INHERITS this one, and theirs, and every
        # foreign key to them; MySQL refuses that drop and SQLite keeps the other tables as they are.
        def drop_table(tables, table, options, adapter)
          return unless tables.delete(table) && options[:force] == :cascade && postgres_rules?(adapter)

          tables.each_value { |data| data[:foreign_keys]&.reject! { |fk| fk[:to_table] == table } }
          tables.select { |_, data| data[:inherits]&.include?(table) }.each_key { |child| drop_table(tables, child, options, adapter) }
        end

        # PostgreSQL and MySQL skip an existing key or check under if_not_exists; SQLite's table rebuild ignores it (7.0 to 8.1).
        # 7.0's add_check_constraint has no if_not_exists, but a second constraint of the same name fails there.
        def skip_existing?(options, adapter)
          if_not_exists?(options) && family(adapter) != :sqlite
        end

        def if_not_exists?(options)
          options.is_a?(Hash) && options[:if_not_exists] == true
        end

        # The existing key if_not_exists skips: 7.0 matches to_table only, 7.1 and 8.0 also a column the
        # call gives, and 8.1 fills the default column first and matches a given primary_key too.
        def add_foreign_key(table_data, table, to_table, options, adapter, rails_version)
          return unless table_data

          # The SQLite adapter reads no key's name.
          kept = family(adapter) == :sqlite ? SchemaConventions::FOREIGN_KEY_OPTIONS - [ :name ] : SchemaConventions::FOREIGN_KEY_OPTIONS
          # Only PostgreSQL defers validation (supports_validate_constraints?); the others create a validated key.
          kept -= [ :validate ] unless postgres_rules?(adapter)
          key = SchemaConventions.foreign_key_entry(table, to_table, options[:column], options[:primary_key], **options.slice(*kept))
          newest = RailsVersion.at_least?(rails_version, "8.1")
          column = newest ? key[:column] : (options[:column] if RailsVersion.at_least?(rails_version, "7.1"))
          found = foreign_keys_for(table_data, to_table&.to_s, column)
          found = found.select { |fk| fk[:primary_key] == key[:primary_key] } if newest && options[:primary_key]
          return if skip_existing?(options, adapter) && found.any?

          table_data[:foreign_keys] << key
        end

        # A name Rails makes up (chk_rails_...) is one the dump leaves out.
        def add_check_constraint(table_data, table, expression, options, adapter)
          return unless table_data && expression

          name = options[:name] if options[:name].is_a?(String) || options[:name].is_a?(Symbol)
          return if skip_existing?(options, adapter) && check_constraint_for(table_data[:check_constraints], table, expression, name)

          (table_data[:check_constraints] ||= []) << { name: name&.to_s, expression: expression, validate: (false if options[:validate] == false && postgres_rules?(adapter)) }.compact
        end

        # By name, the given one or the one Rails derives from the expression (check_constraint_for, 7.0 to 8.1).
        def check_constraint_for(constraints, table, expression, name)
          name = name&.to_s || SchemaConventions.check_constraint_name(table, expression)
          Array(constraints).find { |c| (c[:name] || SchemaConventions.check_constraint_name(table, c[:expression])) == name }
        end

        def remove_check_constraint(table_data, table, expression, options)
          constraints = table_data && table_data[:check_constraints] or return

          found = check_constraint_for(constraints, table, expression, options[:name])
          constraints.delete(found) if found
          table_data.delete(:check_constraints) if constraints.empty?
        end

        # Only PostgreSQL has unique constraints (7.1 to 8.1). One made with using_index: takes that index over; a name Rails
        # makes up (uniq_rails_...) is one the dump leaves out; 8.0 adds nulls_not_distinct:.
        # shortcut: 8.0 writes NULLS NOT DISTINCT only on PostgreSQL 15 and later, which the replay takes as given; split by server version if an app on 14 shows it.
        def add_unique_constraint(table_data, columns, options, adapter, rails_version)
          return unless table_data && postgres_rules?(adapter)

          columns = Array(columns)
          if columns.empty? && options[:using_index]
            index = table_data[:indexes].find { |idx| idx[:name] == options[:using_index].to_s } or return
            columns = table_data[:indexes].delete(index)[:columns]
          end
          return if columns.empty?

          nulls_not_distinct = options[:nulls_not_distinct] if RailsVersion.at_least?(rails_version, "8.0")
          (table_data[:unique_constraints] ||= []) << SchemaConventions.unique_constraint_entry(options[:name], columns, options[:deferrable], nulls_not_distinct)
        end

        # The one remove_unique_constraint names, by its columns or its name (unique_constraint_for, 7.1 to 8.1).
        def remove_unique_constraint(table_data, table, columns, options)
          constraints = table_data && table_data[:unique_constraints] or return

          columns = Array(columns)
          found = constraints.find do |c|
            (options[:name].nil? || (c[:name] || SchemaConventions.unique_constraint_name(table, c[:columns])) == options[:name].to_s) &&
              (columns.empty? || c[:columns] == columns)
          end
          constraints.delete(found) if found
          table_data.delete(:unique_constraints) if constraints.empty?
        end

        # PostgreSQL and MySQL make a composite key's columns not null; SQLite leaves them nullable.
        def composite_keys_not_null(tables, adapter)
          return if family(adapter) == :sqlite

          tables.each_value do |table|
            key = table[:primary_key]
            Array(table[:columns]).each { |column| column[:null] = false if key.is_a?(Array) && key.include?(column[:name]) }
          end
        end

        # A create_table implies its key column the way a dump does. A table
        # the replay cannot name is left out: a nil key breaks every reader.
        def seed_table(tables, table, options, pk_type, default: nil, adapter: nil, version: nil)
          return if table.nil? || table.to_s.empty?

          unless tables.key?(table)
            tables[table] = { columns: implicit_pk_columns(options, pk_type, default: default, adapter: adapter, version: version), indexes: [], foreign_keys: [] }
            comment = (options || {})[:comment]
            tables[table][:comment] = comment if comment.is_a?(String) && comments?(adapter)
            inherit_options(tables, table, options, adapter)
          end
          key = (options || {})[:primary_key]
          tables[table][:primary_key] = SchemaConventions.primary_key_value(key) if key.is_a?(Array)
        end

        # create_table's options: string follows the column list, so an INHERITS there names the table's parents.
        def inherit_options(tables, table, options, adapter)
          sql = (options || {})[:options]
          list = sql[/\bINHERITS\s*\(([^)]*)\)/i, 1] if sql.is_a?(String) && postgres_rules?(adapter)
          return unless list

          inherit_parents(tables, table, SqlScan.new(list, family: family(adapter)).split(",").map { |parent| StructureSqlReader.qualified_name(parent).delete_prefix("public.") })
        end

        # A table takes its parents' columns first; a parent no earlier statement made stays inherits_unresolved.
        def inherit_parents(tables, table, parents)
          data = tables[table]
          found, missing = parents.partition { |parent| tables.key?(parent) }
          data.merge!(inherits: found, local_columns: data[:columns].map { |c| c[:name] }) if found.any?
          data[:columns] = StructureSqlReader.inherit(data[:columns], tables.slice(*found), keep_sequence: true)
          data[:inherits_unresolved] = missing if missing.any?
        end

        # Compatibility::V5_0 gives a declared integer or bigint key default: nil, so it has no sequence, but not a bigint key on MySQL.
        # shortcut: Rails 7.0 exempts Mysql2 and not the trilogy gem's adapter, which no answer shows; split by adapter if one does.
        def legacy_key_options(options, entry, adapter)
          version = entry[:migration_version]
          return options unless version && (version <=> [ 5, 0 ]) <= 0 && %w[integer bigint].include?(options[:id].to_s) && !options.key?(:default)
          return options if options[:id].to_s == "bigint" && family(adapter) == :mysql

          options.merge(default: nil)
        end

        # MySQL's CREATE TABLE takes its SELECT without the AS.
        CREATE_AS = /\A\s*CREATE\s+(?:UNLOGGED\s+)?TABLE\s+(?<keep>IF\s+NOT\s+EXISTS\s+)?(?<name>(?>#{SqlScan::QUALIFIED_NAME_TEXT}))(?:\s*\((?!\s*SELECT\b)(?<list>(?:[^()]|\([^()]*\))*)\))?\s*(?<as>AS\s+|(?=\(*\s*SELECT\b))(?<query>.+)\z/im

        # A table the SQL creates; an INHERITS parent an earlier statement made gives it its columns.
        def create_table_sql(tables, entry, adapter, rails_version)
          sql = entry[:sql]
          if (as = CREATE_AS.match(sql)) && (!as[:as].empty? || family(adapter) == :mysql)
            name = SqlScan.names(as[:name]).last
            create_table_as(tables, name, as[:query], adapter, entry, as[:list]) unless as[:keep] && tables.key?(name)
            return [ name ]
          end

          kept = sql.scan(/\bTABLE\s+IF\s+NOT\s+EXISTS\s+(#{SqlScan::QUALIFIED_NAME_TEXT})/io).map { |(found)| StructureSqlReader.qualified_name(found).delete_prefix("public.") }
          StructureSqlReader.parse(sql, dialect: family(adapter), own_sequences: true, rails_version: rails_version)[:tables].each do |name, table|
            next if tables.key?(name) && kept.include?(name)

            parents = Array(table.delete(:inherits_unresolved))
            tables[name] = table
            inherit_parents(tables, name, parents)
          end
        end

        # CREATE TABLE ... AS: the selected columns with no key, typed by the FROM table they come from; one the query
        # computes or takes from another table has no type the replay knows. The entry counts a column it cannot name
        # (unnamed_columns) and a query it cannot read (unread_query), which makes no table.
        def create_table_as(tables, table, sql, adapter, entry, list = nil)
          return if table.nil? || table.to_s.empty?

          picked = (SelectList.columns(sql, tables, adapter: adapter) unless list && family(adapter) == :sqlite)
          return entry[:unread_query] = true unless picked

          # MySQL's column list declares columns: the ones the query does not select come first, and a selected one keeps its
          # definition. PostgreSQL's list names the selected ones in order.
          mysql = family(adapter) == :mysql
          declared = (StructureSqlReader.parse("CREATE TABLE t (#{list})", dialect: :mysql)[:tables]["t"] if list && mysql) || { columns: [], indexes: [], foreign_keys: [] }
          SqlScan.new(list.to_s, family: adapter).split(",").map { |name| SelectList.sql_name(name.strip, adapter) }.each_with_index { |name, i| picked[i] = picked[i].merge(name: name) if i < picked.size } unless mysql
          named = picked.select { |c| c[:name] }
          entry[:unnamed_columns] = picked.size - named.size
          columns = named.map { |c| selected_column(DumpedColumn.without_sequence(c.except(:primary_key)), adapter) }
          columns = columns.map { |c| declared[:columns].find { |d| d[:name].casecmp?(c[:name]) } || c }
          tables[table] = declared.merge(columns: (declared[:columns] - columns) + columns)
        end

        # MySQL keeps a column's not null and default, and an auto-increment one takes 0; PostgreSQL keeps neither;
        # SQLite also types the column by its affinity, the text, integer or no type a booted app reads.
        def selected_column(col, adapter)
          case family(adapter)
          when :mysql then col[:auto_increment] ? col.except(:auto_increment).merge(null: false, default: "0") : col
          when :sqlite
            type = { "string" => "text", "text" => "text", "integer" => "integer", "bigint" => "integer" }[col[:type]]
            { name: col[:name], type: type }
          else col.except(:null, :default, :auto_increment)
          end
        end

        def implicit_pk_columns(options, pk_type, default: nil, adapter: nil, version: nil)
          options ||= {}
          # TableDefinition#primary_key compares the type with :uuid, so only the symbol earns a default: "uuid" gets none.
          # Compatibility::V5_0's create_table gives id: :uuid, and no other spelling, uuid_generate_v4().
          id_type = options[:id].is_a?(Hash) ? options[:id][:type] : options[:id]
          uuid_function = version && (version <=> [ 5, 0 ]) <= 0 && options[:id] == :uuid ? "uuid_generate_v4()" : "gen_random_uuid()"
          SchemaConventions.implicit_primary_key(options, pk_type, default: default).map do |pk|
            type, sizes = dumped_type(pk[:type], options.slice(:unsigned).merge(pk[:options] || {}), adapter, primary_key: true)
            # PostgreSQL backs an integer or bigint key with its own sequence unless a default is given (integer_like_primary_key?).
            # MySQL makes the same key AUTO_INCREMENT.
            sequenced = %w[integer bigint].include?(type) && !options.key?(:default) && !(pk[:options] || {}).key?(:default)
            increments = sequenced && family(adapter) == :mysql
            sequenced &&= postgres_rules?(adapter)
            type = DumpedColumn.serial_name(type, true) if sequenced
            # PostgreSQL's create_table gives a uuid key gen_random_uuid() unless the call names a default.
            uuid = type == "uuid" && id_type == :uuid && postgres_rules?(adapter) && !options.key?(:default) && !(pk[:options] || {}).key?(:default)
            default = uuid ? DumpedColumn.call({ type: "uuid", default_sql: uuid_function }, family: family(adapter), rails_version: nil)[:default] : pk[:default]
            { name: pk[:name], type: type, null: false, primary_key: true, default: default, **sizes, own_sequence: (true if sequenced || sizes[:own_sequence]),
              auto_increment: (true if increments || sizes[:auto_increment]) }.compact
          end
        end

        def family(adapter)
          RailsAiContext::DatabaseFamily.of(adapter.to_s).key
        end

        # An adapter with no family reads with PostgreSQL's rules, as structure.sql does.
        def postgres_rules?(adapter)
          RailsAiContext::DatabaseFamily.of(adapter.to_s).postgres_rules?
        end

        # Rails' type_to_sql (7.0 to 8.1) writes a precision into a decimal, date or time type and an interval alone, and
        # a limit into any other.
        PRECISE_TYPES = %w[decimal numeric datetime timestamp time interval].freeze

        def written_sizes(type, opts)
          sizes = opts.slice(:limit, :precision, :scale, :unsigned, :size, :array)
          PRECISE_TYPES.include?(type.to_s) ? sizes.except(:limit) : sizes.except(:precision, :scale)
        end

        # A declared type and its sizes as the dump writes them.
        def dumped_type(type, opts, adapter, rails_version = nil, primary_key: false)
          column = DumpedColumn.call(written_sizes(type, opts).merge(type: type.to_s, primary_key: primary_key), family: family(adapter), rails_version: rails_version)
          [ column[:type], column.except(:type) ]
        end

        # A column as the dump writes it, whether a table block or add_column declares it.
        def column_entry(name, type, entry, adapter, rails_version)
          opts = SchemaConventions.compat_precision(entry[:options] || {}, type, entry[:migration_version])
          virtual = entry[:virtual] || type == "virtual"
          # A generated column takes its own type from type: (each adapter's virtual, 7.0 to 8.1).
          type = opts[:type].to_s if type == "virtual" && (opts[:type].is_a?(Symbol) || opts[:type].is_a?(String))
          declared = written_sizes(type, opts).merge(name: name, type: type.to_s, primary_key: opts[:primary_key] == true, **written_names(opts, adapter))
          declared[:null] = false if opts[:null] == false
          declared.merge!(auto_increment: true, null: false) if opts[:auto_increment] == true && family(adapter) == :mysql
          default = default_fields(opts[:default], entry, sent: !postgres_rules?(adapter)) { |value| sent_value(value, type, opts[:precision], opts[:scale]) } if opts.key?(:default)
          if virtual
            declared[:generated] = opts[:as].is_a?(String) ? opts[:as] : ""
            declared[:stored] = opts[:stored] == true
          end
          col = DumpedColumn.call(declared.merge(default.to_h.except(:kept)), family: family(adapter), rails_version: rails_version)
          col[:default] = default[:kept] if default&.key?(:kept)
          held_decimal(col, default)
        end

        # A decimal's default reads at the scale the column ends with (dumped_decimals), so the replay holds the value it sent.
        def held_decimal(col, default)
          col[:default] = default[:default].to_s if col[:type] == "decimal" && !col[:array] && default&.key?(:default) && !col[:default].nil?
          col
        end

        # Only PostgreSQL has exclusion constraints (7.1 to 8.1); a name Rails makes up (excl_rails_...) is one the dump leaves out.
        def add_exclusion_constraint(table_data, expression, options, adapter)
          return unless table_data && expression.is_a?(String) && postgres_rules?(adapter)

          name = options[:name] if options[:name].is_a?(String) || options[:name].is_a?(Symbol)
          return if if_not_exists?(options) && Array(table_data[:exclusion_constraints]).any? { |c| name ? c[:name] == name.to_s : c[:expression] == expression }

          (table_data[:exclusion_constraints] ||= []) << SchemaConventions.exclusion_constraint_entry(name, expression, **options.slice(:using, :where, :deferrable))
        end

        # The one remove_exclusion_constraint names, by name or by its elements (exclusion_constraint_for, 7.1 to 8.1).
        def remove_exclusion_constraint(table_data, expression, options)
          constraints = table_data && table_data[:exclusion_constraints] or return

          found = constraints.find { |c| options[:name] ? c[:name] == options[:name].to_s : c[:expression] == expression }
          constraints.delete(found) if found
          table_data.delete(:exclusion_constraints) if constraints.empty?
        end

        # The comment, collation and enum type a column declares; SQLite keeps no comment.
        def written_names(opts, adapter)
          named = ->(value) { value.to_s if value.is_a?(String) || value.is_a?(Symbol) }
          { comment: (opts[:comment] if opts[:comment].is_a?(String) && comments?(adapter)), collation: (opts[:collation] if opts[:collation].is_a?(String)),
            enum_type: named.(opts[:enum_type]) }.compact
        end

        # PostgreSQL and MySQL keep a table's and a column's comment; SQLite's adapter has none (supports_comments?).
        def comments?(adapter)
          family(adapter) != :sqlite
        end

        # change_column_comment and change_table_comment take the comment, or from: and to:; nil removes it.
        def change_comment(target, entry, adapter)
          return unless target && comments?(adapter)

          options = entry[:options] || {}
          comment = entry.key?(:comment) ? entry[:comment] : options[:to]
          return if comment == RailsAiContext::Confidence::INFERRED || !(comment.nil? || comment.is_a?(String))

          comment.nil? || comment.empty? ? target.delete(:comment) : target[:comment] = comment
        end

        # A declared default as DumpedColumn reads it: a value as the statement sends it, the SQL a proc holds, or kept:, a
        # proc's source the dump readers report as it is. Empty for a value only the running migration knows.
        def default_fields(value, entry, sent:)
          if value == RailsAiContext::Confidence::INFERRED
            return {} unless entry[:default_proc]

            return entry[:default_literal] ? { default_sql: entry[:default_literal] } : { kept: entry[:default_source] }
          end
          { default: sent ? yield(value) : value }
        end

        # Rails sends a default cast through the column's type (quote_default_expression), so a decimal whose precision
        # has no scale, scale 0 by extract_scale, sends its whole part (DecimalWithoutScale casts with to_i).
        def sent_value(value, type, precision, scale)
          return value unless type.to_s == "decimal" && precision.is_a?(Integer) && scale.to_i.zero? && value.to_s.match?(DumpedColumn::DECIMAL_TEXT)

          BigDecimal(value.to_s).to_i.to_s
        end

        # The new default is to: of a from:/to: pair, or the positional value (extract_new_default_value, 7.0 and 8.1); an
        # unreadable one is left. PostgreSQL's adapter casts only change_column_default's value, which reads the column back.
        def change_column_default(col, entry, adapter, rails_version, sent: true)
          opts = entry[:options] || {}
          new_default = if opts.key?(:to) then opts[:to]
          elsif entry.key?(:new_default) then entry[:new_default]
          else NOT_GIVEN
          end
          return if col.nil? || new_default.equal?(NOT_GIVEN)

          default = default_fields(new_default, entry, sent: sent) { |value| sent_value(value, col[:type], col[:precision], col[:scale]) }
          return if default.empty?

          col.replace(DumpedColumn.without_sequence(col))
          col[:default] = default.fetch(:kept) { DumpedColumn.call(col.except(:default).merge(default), family: family(adapter), rails_version: rails_version)[:default] }
          held_decimal(col, default)
        end

        # change_column builds the type from its own sizes on every adapter. PostgreSQL and MySQL
        # set the default and null only when given; SQLite rebuilds the column from the options alone (7.0 to 8.1).
        def change_column(col, entry, adapter, rails_version)
          return unless col

          return col.replace(column_entry(col[:name], entry[:column_type] || col[:type], entry, adapter, rails_version).merge(col.slice(:primary_key))) if family(adapter) == :sqlite

          type = entry[:column_type] || col[:type]
          opts = SchemaConventions.compat_precision(entry[:options] || {}, type, entry[:migration_version])
          col[:type], sizes = dumped_type(type, opts, adapter, rails_version)
          col.except!(:limit, :precision, :scale, :unsigned, :year, :size, :array, :enum_type).merge!(sizes)
          col.merge!(carried_names(col, type, opts, adapter, rails_version, legacy: legacy_70?(entry, rails_version) && !entry[:block]))
          # change_column keeps a column's AUTO_INCREMENT unless the options name it (change_column_for_alter, 7.0 to 8.1).
          col[:auto_increment] = opts[:auto_increment] == true if opts.key?(:auto_increment)
          change_column_null(col, opts[:null]) if opts.key?(:null)
          change_column_default(col, entry.merge(options: { to: opts[:default] }), adapter, rails_version,
                                sent: !postgres_rules?(adapter) && !entry[:default_proc]) if opts.key?(:default)
        end

        # MySQL's type map reads these as a string or text type (text_type?), so change_column keeps their collation.
        MYSQL_TEXT_TYPE = /char|text|\A(?:enum|set)\b/i

        # The comment, collation and enum type a change_column leaves (7.0 to 8.1): the comment stays unless given, the
        # enum type only as given; PostgreSQL resets the collation with the type, MySQL keeps it on a text type alone,
        # where 7.0 takes any collation key as given, nil too, and Compatibility::V7_0 (legacy) never keeps one.
        def carried_names(col, type, opts, adapter, rails_version, legacy: false)
          names = col.extract!(:comment, :collation)
          names.delete(:comment) if opts.key?(:comment)
          given = legacy || (RailsVersion.at_least?(rails_version, "7.1") ? !opts[:collation].nil? : opts.key?(:collation))
          names.delete(:collation) unless family(adapter) == :mysql && type.to_s.match?(MYSQL_TEXT_TYPE) && !given
          names.merge(written_names(opts, adapter)).reject { |key, value| key == :comment && value.empty? }
        end

        # A decimal's default as the dump reads it once every statement has run, at the scale the column ends with.
        def dumped_decimals(tables, adapter)
          tables.each_value do |table|
            Array(table[:columns]).each do |c|
              next unless c[:type] == "decimal"

              dumped = DumpedColumn.call(c.slice(:type, :precision, :scale, :default), family: family(adapter), rails_version: nil)
              c.except!(:precision, :scale).merge!(dumped.slice(:precision, :scale))
              c[:default] = dumped[:default] if c.key?(:default)
            end
          end
        end

        # A computed column name is counted in the note instead: a nil name trips every reader.
        def add_column(table_data, entry, adapter, pk_type, rails_version)
          return unless table_data && entry[:column]
          return if if_not_exists?(entry[:options]) && table_data[:columns].any? { |c| c[:name] == entry[:column] }

          table_data[:columns].reject! { |c| c[:name] == entry[:column] }
          table_data[:columns] << declared_column(entry[:column], entry[:column_type], entry, adapter, pk_type, rails_version)
          add_serial_index(table_data, entry[:column_type], table_data[:columns].last, adapter)
        end

        def add_serial_index(table_data, type, col, adapter)
          return unless col && SchemaConventions.serial_index?(family(adapter), type, col, table_data[:primary_key])

          table_data[:indexes] << SchemaConventions.serial_index(table_data[:indexes], col[:name])
        end

        # A column a statement makes the key reads as the key create_table implies (TableDefinition#primary_key, 7.0 to 8.1).
        def declared_column(name, type, entry, adapter, pk_type, rails_version)
          opts = entry[:options] || {}
          return column_entry(name, type, entry, adapter, rails_version) unless type == "primary_key" || opts[:primary_key] == true

          id = opts.except(:primary_key)
          id = id.merge(type: type) unless type == "primary_key"
          implicit_pk_columns({ id: id, primary_key: name }, pk_type, default: SchemaConventions.key_default({ id: id }, entry), adapter: adapter).first
        end

        # A literal nil: on 7.0 PostgreSQL sets NOT NULL and MySQL and SQLite allow NULL; from 7.1 a migration written for
        # 7.0 or earlier turns it into false (Compatibility::V7_0, its own call alone), and any other call raises.
        def null_argument(entry, adapter, rails_version)
          return entry[:null] unless entry[:null_nil]
          return !postgres_rules?(adapter) unless RailsVersion.at_least?(rails_version, "7.1")

          false if legacy_70?(entry, rails_version) && !entry[:block]
        end

        # Only null: false is stored, so allowing NULL again removes the mark; MySQL keeps an AUTO_INCREMENT column NOT NULL.
        def change_column_null(col, null)
          return if col.nil? || null.nil? || (null && col[:auto_increment])

          null ? col.delete(:null) : col[:null] = false
        end

        def column_in(tables, entry)
          tables[entry[:table]]&.dig(:columns)&.find { |c| c[:name] == entry[:column] }
        end

        # definition: false for a change_table block, whose `t.` column and reference calls run add_column and add_reference.
        def apply_schema_column(entry, current_table, tables, pk_type, adapter, rails_version = nil, definition: true)
          return unless tables[current_table]

          action = %w[references belongs_to].include?(entry[:column_type]) ? :add_reference : :add_column
          steps = sqlite_rebuilds(entry.merge(action: action, definition: definition), tables[current_table], adapter, rails_version) if family(adapter) == :sqlite
          keeping_key_order(tables[current_table], steps) { schema_column(entry, current_table, tables, pk_type, adapter, rails_version, definition) }
        end

        def schema_column(entry, current_table, tables, pk_type, adapter, rails_version, definition)
          col_type = entry[:column_type]

          if %w[references belongs_to].include?(col_type)
            apply_reference(tables, current_table, entry[:name], entry[:options], pk_type, version: entry[:migration_version], adapter: adapter,
                                                                                          rails_version: rails_version, index_compat: definition)
            return
          end

          # Skip non-column types
          return if %w[index check_constraint].include?(col_type)

          col = declared_column(entry[:name], col_type, entry, adapter, pk_type, rails_version)
          opts = entry[:options] || {}
          data = tables[current_table]
          if data[:local_columns] && !data[:local_columns].include?(col[:name]) && data[:columns].any? { |c| c[:name] == col[:name] }
            # PostgreSQL merges a column a child declares into the one it inherits, in that column's place.
            StructureSqlReader.merge_column(data[:columns], col)
          else
            # Only one branch of an if runs, so a second declaration of a name replaces the first.
            data[:columns].reject! { |c| c[:name] == col[:name] }
            data[:columns] << col
          end
          data[:local_columns] |= [ col[:name] ] if data[:local_columns]
          add_serial_index(tables[current_table], col_type, col, adapter)
          return unless opts[:index] && opts[:index] != false

          # TableDefinition#column indexes a column declared with index: (7.0 to 8.1).
          index_opts = opts[:index].is_a?(Hash) ? opts[:index] : {}
          apply_schema_index({ columns: [ col[:name] ], options: index_opts, migration_version: entry[:migration_version] }, current_table, tables, rails_version)
        end

        # TableDefinition#timestamps and add_timestamps (7.0 and 8.1). Only a
        # table definition indexes them; add_timestamps adds the columns alone.
        def add_timestamps(tables, entry, adapter, rails_version)
          table_data = tables[entry[:table]] or return
          options = entry[:options] || {}
          if options.key?(:default)
            default = default_fields(options[:default], entry, sent: false)
            options = if default.empty? then options.except(:default)
            else options.merge(default: default.fetch(:kept) { DumpedColumn.call({ type: "datetime" }.merge(default), family: family(adapter), rails_version: rails_version)[:default] })
            end
          end
          stamps = SchemaConventions.timestamps_columns(options, version: entry[:migration_version])
          precision = SchemaConventions.compat_precision(options.slice(:precision), "datetime", entry[:migration_version], timestamps: true)
          stamps.map! { |stamp| stamp.merge(DumpedColumn.call({ type: "datetime", **precision }, family: family(adapter), rails_version: rails_version).slice(:precision)) }
          table_data[:columns].reject! { |c| stamps.any? { |stamp| stamp[:name] == c[:name] } }
          table_data[:columns].concat(stamps)
          return unless entry[:definition] && options[:index]

          stamps.each do |stamp|
            apply_schema_index({ columns: [ stamp[:name] ], options: options[:index].is_a?(Hash) ? options[:index] : {}, migration_version: entry[:migration_version] },
                               entry[:table], tables, rails_version)
          end
        end

        # An index follows its column to the new name, and one Rails named for
        # the old columns is renamed for the new (rename_column_indexes, 7.0 to 8.1).
        def rename_index_columns(table_data, table, old_name, new_name, rails_version)
          Array(table_data && table_data[:indexes]).each do |idx|
            next unless idx[:columns].include?(old_name)

            legacy = !RailsVersion.at_least?(rails_version, "7.1")
            old_default = SchemaConventions.default_index_name(table, idx[:columns], legacy: legacy)
            idx[:columns] = idx[:columns].map { |col| col == old_name ? new_name.to_s : col }
            idx[:name] = SchemaConventions.default_index_name(table, idx[:columns], legacy: legacy) if idx[:name] == old_default
          end
        end

        # An index Rails named for the old table takes the name for the new one;
        # a name the migration chose stays (rename_table_indexes, 7.0 and 8.1). legacy: 7.0's names, which 7.1 never shortens.
        def rename_table_indexes(table_data, old_table, new_table, legacy: false)
          Array(table_data[:indexes]).each do |idx|
            next unless idx[:name] == SchemaConventions.default_index_name(old_table, idx[:columns], legacy: legacy)

            idx[:name] = SchemaConventions.default_index_name(new_table, idx[:columns], legacy: legacy)
          end
        end

        # 7.0 never shortens an index name. From 7.1 Compatibility::V7_0 keeps that for the calls it overrides, in a migration
        # written for 7.0 or earlier: add_index, rename_table, and a block's index calls (compat: false for the rest).
        def unshortened_index_names?(entry, rails_version, compat: true)
          version = entry[:migration_version]
          !RailsVersion.at_least?(rails_version, "7.1") || (compat && !version.nil? && (version <=> [ 7, 1 ]).negative?)
        end

        # A migration written for 7.0 or earlier on Rails 7.1 or later runs Compatibility::V7_0, which sends a MySQL
        # change_column :no_collation (its own change_column; a block's t.change goes to the connection).
        def legacy_70?(entry, rails_version)
          version = entry[:migration_version]
          !version.nil? && (version <=> [ 7, 1 ]).negative? && RailsVersion.at_least?(rails_version, "7.1")
        end

        # PostgreSQL's rename_table renames the key's first column's sequence when it has the name Rails builds from the
        # old table (pk_and_sequence_for, key_sequence_name); every other sequence keeps its name. Returns the old and new name.
        def rename_table_sequences(table_data, old_table, new_table, rails_version)
          key = Array(table_data[:primary_key]).first || table_data[:columns].find { |c| c[:primary_key] }&.dig(:name)
          renamed = nil
          table_data[:columns].each do |c|
            keep_sequence_name(c, old_table)
            next unless c[:name] == key && c[:own_sequence]

            schema, sequence = SqlScan.split_qualified(c[:own_sequence])
            next unless sequence == key_sequence_name(old_table, key, rails_version)

            renamed = [ c[:own_sequence], SqlScan.join_qualified(*[ schema, key_sequence_name(new_table, key, rails_version)[0, 63] ].compact) ]
            c[:own_sequence] = renamed.last
          end
          renamed
        end

        # A nextval default holds its sequence, not the name, so it reads back under the name the sequence has now.
        def follow_sequence(tables, old_name, new_name)
          tables.each_value do |data|
            Array(data[:columns]).each { |c| c[:default] = DumpedColumn.nextval_default(new_name) if DumpedColumn.nextval_sequence(c[:default]) == old_name }
          end
        end

        # PostgreSQL writes a nextval default back with its ::regclass cast, and without public on the search path; one naming
        # the sequence the column's own name makes reads as a serial (new_column_from_field), which settle_sequences types.
        def nextval_defaults(tables)
          tables.each do |name, data|
            Array(data[:columns]).each do |c|
              sequence = DumpedColumn.nextval_sequence(c[:default]) or next
              next c[:default] = DumpedColumn.nextval_default(sequence) unless PgNaming.serial_sequence?(sequence, name, c[:name])

              c.delete(:default)
              c[:own_sequence] = sequence
            end
          end
        end

        # 7.1 to 8.1 cut the table to fit the key's name and _seq in 63 bytes; 7.0 does not, and PostgreSQL cuts the result.
        def key_sequence_name(table, key, rails_version)
          table = table[0, 63 - "_#{key}_seq".size] if RailsVersion.at_least?(rails_version, "7.1")
          "#{table}_#{key}_seq"
        end

        # own_sequence is true until the serial's sequence is named (name_sequences), then that name; a rename leaves the
        # sequence its name, so the name is fixed before the column or table changes.
        def keep_sequence_name(col, table)
          col[:own_sequence] = PgNaming.owned_sequence(col, table) if col[:own_sequence]
        end

        def following_sequence?(col, table)
          return false unless col[:own_sequence]

          col[:own_sequence] == true || PgNaming.serial_sequence?(col[:own_sequence], table, col[:name])
        end

        # PostgreSQL names a new serial's sequence for its table and column, numbering the suffix seq1, seq2 and on
        # while another relation holds the name (ChooseRelationName); the mark then holds it. held keeps each table's
        # relation_names, refreshed here for the tables a statement touched.
        def name_sequences(tables, touched, adapter, held)
          return unless postgres_rules?(adapter)

          touched.each do |table|
            fresh = Array(tables.dig(table, :columns)).select { |c| c[:own_sequence] == true }
            fresh.each do |col|
              col[:own_sequence] = (0..).lazy.map { |n| PgNaming.owned_sequence(col.except(:own_sequence), table, "seq#{n unless n.zero?}") }.find do |name|
                tables.each_key.none? { |other| (other == table ? relation_names(tables, table) : held[other] ||= relation_names(tables, other)).include?(name) }
              end
            end
          end
          touched.each { |table| tables.key?(table) ? held[table] = relation_names(tables, table) : held.delete(table) }
        end

        # The names a table, its indexes and its columns' sequences hold.
        def relation_names(tables, table)
          schema, = SqlScan.split_qualified(table)
          data = tables[table]
          Set[table] + Array(data[:indexes]).map { |idx| SqlScan.join_qualified(*[ schema, idx[:name] ].compact) } +
            Array(data[:columns]).filter_map { |c| c[:own_sequence] if c[:own_sequence].is_a?(String) }
        end

        # The columns of a table some table INHERITS, before a statement changes them (follow_parent).
        def inherited_state(tables, table)
          return unless tables[table] && (tables[table][:inherits] || tables.each_value.any? { |t| t[:inherits]&.include?(table) })

          tables[table][:columns].map { |c| [ c, c.dup ] }
        end

        # The statements whose ALTER COLUMN PostgreSQL runs on each child too, so they set the child's own value.
        COLUMN_ALTERS = %i[change_column change_column_default change_column_null].to_set.freeze

        # PostgreSQL's ALTER TABLE reaches every table that INHERITS the one it names: a column added or renamed changes
        # in each child, an altered one takes the same statement, and a dropped one goes unless the child declares it or
        # another parent has it. A column a statement adds to a child itself is the child's own.
        def follow_parent(tables, table, before, entry, adapter, rails_version)
          columns = tables.dig(table, :columns) or return
          kept = before.map(&:first)
          added = columns.reject { |c| kept.any? { |k| k.equal?(c) } }
          altered = COLUMN_ALTERS.include?(entry[:action])
          own_columns(tables[table], before, added)
          tables.each do |name, child|
            next unless Array(child[:inherits]).include?(table)

            child_before = inherited_state(tables, name)
            before.each do |column, was|
              mine = child[:columns].find { |c| c[:name] == was[:name] } or next
              if columns.none? { |c| c.equal?(column) }
                remove_columns_from(child, [ was[:name] ], adapter) unless inherited_elsewhere?(tables, child, table, was[:name])
              elsif altered
                alter_column(mine, entry, adapter, rails_version) if was[:name] == entry[:column]
              elsif column != was
                follow_column(child, mine, column, was, table)
              end
            end
            added.each { |c| child[:columns] << StructureSqlReader.inherited_column(c, table, keep_sequence: true) unless child[:columns].any? { |m| m[:name] == c[:name] } }
            follow_parent(tables, name, child_before, entry, adapter, rails_version) if child_before
          end
        end

        def alter_column(col, entry, adapter, rails_version)
          case entry[:action]
          when :change_column then change_column(col, entry, adapter, rails_version)
          when :change_column_default then change_column_default(col, entry, adapter, rails_version)
          when :change_column_null then change_column_null(col, null_argument(entry, adapter, rails_version))
          end
        end

        def own_columns(table_data, before, added)
          return unless table_data[:local_columns]

          before.each { |column, was| table_data[:local_columns] = renamed(table_data[:local_columns], was[:name], column[:name]) }
          table_data[:local_columns] |= added.map { |c| c[:name] }
        end

        def inherited_elsewhere?(tables, child, parent, name)
          child[:local_columns]&.include?(name) ||
            (child[:inherits] - [ parent ]).any? { |other| Array(tables.dig(other, :columns)).any? { |c| c[:name] == name } }
        end

        # A child's copy takes what changed in the parent's column; a rename leaves the child's index names (rename_column_indexes runs on the parent).
        def follow_column(child, mine, column, was, parent)
          (column.keys | was.keys).each do |key|
            next if key == :primary_key || column[key] == was[key]

            case key
            when :name
              Array(child[:indexes]).each { |idx| idx[:columns] = renamed(idx[:columns], was[:name], column[:name]) }
              Array(child[:unique_constraints]).each { |uc| uc[:columns] = renamed(uc[:columns], was[:name], column[:name]) }
              Array(child[:foreign_keys]).each { |fk| fk[:column] = renamed(fk[:column], was[:name], column[:name]) }
              mine[:name] = column[:name]
            when :own_sequence then column[:own_sequence] ? mine[:own_sequence] = PgNaming.owned_sequence(column, parent) : mine.delete(:own_sequence)
            else column.key?(key) ? mine[key] = column[key] : mine.delete(key)
            end
          end
        end

        # The dump reads a serial by name (serial?): one whose sequence follows its current names is a serial of its size
        # whatever its type (schema_type), any other its type with that sequence as its default. The marks go before output,
        # and so does a nil default, which the dump writes as no default.
        def settle_sequences(tables)
          tables.each do |name, table|
            Array(table[:columns]).map! do |c|
              key = c[:primary_key] == true || Array(table[:primary_key]) == [ c[:name] ]
              settled = following_sequence?(c, name) ? c.merge(type: DumpedColumn.serial_name(DumpedColumn.without_sequence(c)[:type], key)) : StructureSqlReader.detached_serial(c, name)
              settled.except(:own_sequence, :auto_increment, :year, *(:default if settled[:default].nil?))
            end
            table.except!(:inherits, :local_columns)
          end
        end

        def rename_column_in(tables, table, old_name, new_name, adapter, rails_version)
          col = tables[table]&.dig(:columns)&.find { |c| c[:name] == old_name.to_s }
          return unless col && new_name

          keep_sequence_name(col, table)
          col[:name] = new_name.to_s
          tables[table][:primary_key] = renamed(tables[table][:primary_key], old_name.to_s, new_name.to_s) if tables[table].key?(:primary_key)
          rename_index_columns(tables[table], table, old_name.to_s, new_name.to_s, rails_version)
          Array(tables[table][:unique_constraints]).each { |uc| uc[:columns] = renamed(uc[:columns], old_name.to_s, new_name.to_s) }
          each_foreign_key(tables) do |fk|
            fk[:column] = renamed(fk[:column], old_name.to_s, new_name.to_s) if fk[:from_table] == table
            # SQLite rebuilds the table, which leaves another table's key naming the old column.
            fk[:primary_key] = renamed(fk[:primary_key], old_name.to_s, new_name.to_s) if fk[:to_table] == table && family(adapter) != :sqlite
          end
          follow_rename(tables[table], old_name.to_s, new_name.to_s, adapter)
        end

        # An index's per-key options follow a rename on PostgreSQL and MySQL. PostgreSQL also carries it through every
        # expression that holds the column by number: an index's keys, include and where, a check, a generated column.
        def follow_rename(data, old_name, new_name, adapter)
          return if family(adapter) == :sqlite

          postgres = postgres_rules?(adapter)
          Array(data[:indexes]).each do |idx|
            %i[order opclass length].each { |key| idx[key] = idx[key].transform_keys { |c| c == old_name ? new_name : c } if idx[key].is_a?(Hash) }
            next unless postgres

            idx[:columns] = idx[:columns].map { |key| renamed_sql(key, old_name, new_name) } if idx[:columns].is_a?(Array)
            idx[:include] = renamed(idx[:include], old_name, new_name) if idx[:include]
            idx[:where] = renamed_sql(idx[:where], old_name, new_name) if idx[:where]
          end
          return unless postgres

          Array(data[:check_constraints]).each { |check| check[:expression] = renamed_sql(check[:expression], old_name, new_name) }
          Array(data[:exclusion_constraints]).each do |exclusion|
            exclusion[:expression] = renamed_sql(exclusion[:expression], old_name, new_name)
            exclusion[:where] = renamed_sql(exclusion[:where], old_name, new_name) if exclusion[:where]
          end
          data[:columns].each { |c| c[:generated] = renamed_sql(c[:generated], old_name, new_name) if c[:generated] }
        end

        # A key's column, or each column of a composite key, under its new name.
        def renamed(columns, old_name, new_name)
          columns.is_a?(Array) ? columns.map { |c| c == old_name ? new_name : c } : (columns == old_name ? new_name : columns)
        end

        # A foreign key names its tables and columns, so it follows them through a rename the way the database does.
        def each_foreign_key(tables, &block)
          tables.each_value { |data| Array(data[:foreign_keys]).each(&block) }
        end

        # remove_reference drops <ref>_id, and <ref>_type when polymorphic
        # (schema_statements.rb, 7.0 and 8.1); the database drops the index.
        def remove_reference_from(table_data, ref, options, adapter)
          return unless ref

          names = [ SchemaConventions.reference_column_name(ref) ]
          names << "#{ref}_type" if options[:polymorphic]
          remove_columns_from(table_data, names, adapter)
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

        # The key remove_foreign_key and validate_foreign_key act on (foreign_key_for, 7.0 to 8.1): the first by to_table,
        # column: and name: (a key stored without one has Rails' default) in the order the adapter lists keys, and from 8.1
        # a key on <to_table singular>_id first unless column_match is false. SQLite's remove_foreign_key ignores name:.
        def foreign_key_for(table_data, table, to_table, options, adapter, rails_version, server = nil, column_match: true)
          return unless table_data

          to = (to_table || options[:to_table])&.to_s
          column = options[:column]
          name = (options[:name]&.to_s unless family(adapter) == :sqlite)
          return if to.nil? && column.nil? && name.nil?

          keys = foreign_keys_for(table_data, to, column)
          keys = keys.select { |fk| SchemaConventions.real_foreign_key_name(table, fk) == name } if name
          if column_match && column.nil? && to && RailsVersion.at_least?(rails_version, "8.1")
            preferred = keys.select { |fk| fk[:column].to_s == "#{to.singularize}_id" }
            keys = preferred if preferred.any?
          end
          found = listed(keys, table, adapter, server).first
          # With the server unknown the key is MySQL's; the answer says so where MariaDB would list another first.
          table_data[:mysql_order_assumed] = true if server.nil? && !found.equal?(listed(keys, table, adapter, :mariadb).first)
          found
        end

        # PostgreSQL lists a table's keys by name (ORDER BY conname), MariaDB by name byte by byte, MySQL by name upper-cased
        # byte by byte (live on 8.4 and 9.6; its query has no ORDER BY), SQLite the last declared first.
        def listed(keys, table, adapter, server = nil)
          return keys.reverse if family(adapter) == :sqlite

          keys.sort_by do |fk|
            name = SchemaConventions.real_foreign_key_name(table, fk)
            family(adapter) == :mysql && server != :mariadb ? name.upcase : name
          end
        end

        # The keys to to_table on column:, each compared as a list so a composite key matches (ForeignKeyDefinition#defined_for?).
        def foreign_keys_for(table_data, to, column)
          Array(table_data[:foreign_keys]).select do |fk|
            (to.nil? || fk[:to_table].to_s == to) && (column.nil? || Array(fk[:column]).map(&:to_s) == Array(column).map(&:to_s))
          end
        end

        # PostgreSQL drops every index and check that names a dropped column, whole: in its keys, include, where or
        # expression. MySQL takes the column out of each index and drops one left with none, and every check that names
        # no column left; SQLite's table rebuild keeps each index on the columns left (copy_table_indexes, 7.0 to 8.1).
        def remove_columns_from(table_data, names, adapter)
          return unless table_data

          names = names.compact.map(&:to_s)
          table_data[:columns].reject! { |c| names.include?(c[:name]) }
          if postgres_rules?(adapter)
            table_data[:indexes].reject! { |idx| names.any? { |name| index_names?(idx, name) } }
          else
            table_data[:indexes].each { |idx| shrink_index(idx, names) }
            table_data[:indexes].reject! { |idx| Array(idx[:columns]).empty? }
          end
          table_data[:foreign_keys].reject! { |fk| Array(fk[:column]).any? { |key| names.include?(key.to_s) } }
          table_data[:unique_constraints]&.reject! { |uc| (uc[:columns] & names).any? }
          table_data.delete(:unique_constraints) if table_data[:unique_constraints]&.empty?
          drop_checks(table_data, names, adapter)
          drop_exclusions(table_data, names) if postgres_rules?(adapter)
        end

        def index_names?(idx, name)
          Array(idx[:columns]).any? { |key| key == name || sql_names?(key, name) } || Array(idx[:include]).include?(name) || sql_names?(idx[:where], name)
        end

        def shrink_index(idx, names)
          return unless idx[:columns].is_a?(Array)

          idx[:columns] -= names
          %i[order opclass length].each do |key|
            next unless idx[key].is_a?(Hash)

            idx[key] = idx[key].except(*names)
            idx.delete(key) if idx[key].empty?
          end
        end

        def drop_checks(table_data, names, adapter)
          checks = table_data[:check_constraints] or return
          names_any = ->(check) { names.any? { |name| sql_names?(check[:expression], name) } }
          if postgres_rules?(adapter)
            checks.reject!(&names_any)
          elsif family(adapter) == :mysql
            # MySQL and MariaDB drop a check that names no column at all with any column they drop.
            others = table_data[:columns].map { |c| c[:name] }
            checks.reject! { |check| others.none? { |other| sql_names?(check[:expression], other, :mysql) } }
          end
          table_data.delete(:check_constraints) if checks.empty?
        end

        def drop_exclusions(table_data, names)
          exclusions = table_data[:exclusion_constraints] or return
          exclusions.reject! { |c| names.any? { |name| sql_names?(c[:expression], name) || sql_names?(c[:where], name) } }
          table_data.delete(:exclusion_constraints) if exclusions.empty?
        end

        # Where SQL text names a column: a bare word, or one in double quotes, outside strings, neither a function's
        # name nor another relation's column. PostgreSQL folds a bare name to lower case; MySQL matches any case.
        def sql_name_spans(text, name, family = :postgresql)
          return [] unless text.is_a?(String) && !name.empty?

          masked = SqlScan.new(text, family: family).masked.b
          bare = Regexp.new(Regexp.escape(name.b), family == :mysql || name == name.downcase ? Regexp::IGNORECASE : nil)
          quoted = Regexp.new(Regexp.escape(%("#{name.gsub('"', '""')}").b))
          pattern = /(?<![\w$."])(?:#{bare}|#{quoted})(?![\w$"])(?!\s*\()/n
          masked.to_enum(:scan, pattern).map { Regexp.last_match.offset(0) }
        end

        def sql_names?(text, name, family = :postgresql)
          sql_name_spans(text, name, family).any?
        end

        # The SQL text with each name of the old column given the new one.
        # shortcut: the text stays as the migration wrote it, where PostgreSQL's dump shows its deparsed form ((quantity > 0)); deparse it if a tool compares the two.
        def renamed_sql(text, old_name, new_name)
          spans = sql_name_spans(text, old_name)
          return text if spans.empty?

          shown = PgNaming.quote_ident(new_name)
          out = text.b
          spans.reverse_each { |from, to| out[from...to] = shown.b }
          out.force_encoding(text.encoding)
        end

        # PostgreSQL's enum types by name, each with its values in order, as create_enum, add_enum_value, rename_enum_value,
        # rename_enum and drop_enum leave them (7.0 to 8.1). A column holds its type by oid, so it follows a rename.
        def enum_statement(enums, entry, tables)
          name = entry[:name] or return
          options = entry[:options] || {}
          case entry[:action]
          when :create_enum then enums[name] ||= Array(entry[:values]) if entry[:values]
          when :drop_enum then enums.delete(name)
          when :rename_enum
            to = entry[:new_name] || (options[:to].to_s if options[:to].is_a?(String) || options[:to].is_a?(Symbol))
            return unless to

            enums[to] = enums.delete(name) if enums.key?(name)
            tables.each_value { |table| Array(table[:columns]).each { |c| c[:enum_type] = to if c[:enum_type] == name } }
          when :add_enum_value
            values = enums[name] or return
            value = entry[:value] or return
            return if values.include?(value)

            at = values.index(options[:before].to_s) || values.index(options[:after].to_s)&.+(1) || values.size
            values.insert(at, value)
          when :rename_enum_value
            values = enums[name] or return
            at = values.index(options[:from].to_s)
            values[at] = options[:to].to_s if at && (options[:to].is_a?(String) || options[:to].is_a?(Symbol))
          end
        end

        # create_join_table (7.0 and 8.1): no id, two non-null unindexed references,
        # named by table_name: or derive_join_table_name, which it returns for the block.
        def create_join_table(entry, tables, pk_type, adapter, rails_version)
          first, second = entry[:tables]
          return nil unless first && second

          options = entry[:options] || {}
          name = join_table_name(entry)
          seed_table(tables, name, { id: false }, pk_type, adapter: adapter)
          column_options = { null: false, index: false }.merge(options[:column_options].is_a?(Hash) ? options[:column_options] : {})
          [ first, second ].each do |t|
            apply_reference(tables, name, t.to_s.singularize, column_options, pk_type, version: entry[:migration_version], adapter: adapter, rails_version: rails_version)
          end
          name
        end

        def join_table_name(entry)
          first, second = entry[:tables]
          (entry.dig(:options, :table_name) || HabtmJoinTables.join_table_name(first, second)).to_s if first && second
        end

        # From 7.1 ReferenceDefinition passes if_not_exists: to each add_column, add_index and add_foreign_key
        # it makes; 7.0 passes it to add_column only, so its migration fails on the existing index.
        def apply_reference(tables, table, name, options, pk_type, version: nil, adapter: nil, rails_version: nil, index_compat: false)
          return unless tables[table] && name

          options ||= {}
          keep = if_not_exists?(options)
          ref = SchemaConventions.reference_definition(table, name, options, pk_type, version: version,
                                                     legacy: unshortened_index_names?({ migration_version: version }, rails_version, compat: index_compat))
          ref[:columns].each do |col|
            # Only the id column takes the reference's own options (ReferenceDefinition#columns).
            if col[:name] == SchemaConventions.reference_column_name(name)
              type, sizes = dumped_type(col[:type], options, adapter)
              col.merge!(type: type, **sizes)
            end
            next if keep && tables[table][:columns].any? { |c| c[:name] == col[:name] }

            tables[table][:columns].reject! { |c| c[:name] == col[:name] }
            tables[table][:columns] << col
          end
          add_reference_foreign_key(tables[table], table, name, options, adapter, rails_version)
          return unless ref[:index]
          return if keep && tables[table][:indexes].any? { |idx| idx[:name] == ref[:index][:name] }

          tables[table][:indexes].reject! { |idx| idx[:name] == ref[:index][:name] }
          tables[table][:indexes] << ref[:index]
        end

        # ReferenceDefinition's foreign_key: (7.0 to 8.1): true points at the
        # pluralized name, a hash may name to_table: and primary_key:, and it is added with add_foreign_key.
        def add_reference_foreign_key(table_data, table, name, options, adapter, rails_version)
          fk = options[:foreign_key]
          return if !fk || options[:polymorphic]

          fk = {} unless fk.is_a?(Hash)
          to = fk[:to_table] || name.to_s.pluralize
          return if to == RailsAiContext::Confidence::INFERRED

          table_data[:foreign_keys] ||= []
          key_options = fk.slice(:primary_key, *SchemaConventions::FOREIGN_KEY_OPTIONS)
                          .merge(column: SchemaConventions.reference_column_name(name), if_not_exists: options[:if_not_exists])
          add_foreign_key(table_data, table, to.to_s, key_options, adapter, rails_version)
        end

        def apply_schema_index(entry, current_table, tables, rails_version)
          return unless tables[current_table]
          cols = entry[:columns]&.map(&:to_s) || []
          opts = entry[:options] || {}
          return if cols.empty?

          idx_name = opts[:name]&.to_s ||
                     SchemaConventions.default_index_name(current_table, entry[:string_key] ? cols.first : cols, legacy: unshortened_index_names?(entry, rails_version))
          return if if_not_exists?(opts) && tables[current_table][:indexes].any? { |idx| idx[:name] == idx_name }
          tables[current_table][:indexes] << SchemaConventions.index_entry(idx_name, cols, opts)
        end
      end
    end
  end
end
