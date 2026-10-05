# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts database schema information including tables, columns,
    # indexes, and foreign keys from the Rails application.
    class SchemaIntrospector < Base
      extend StaticTier
      static_tier :alternate_source

      # @return [Hash] database schema context
      def call
        return attach_secondary_databases(static_schema_parse) unless active_record_connected?

        @partitions = PgPartitions.names(connection)
        if table_names.empty?
          # Connected but not migrated: the files answer, and the notes say so.
          @connection_state = "connected, no tables yet"
          return attach_secondary_databases(static_schema_parse)
        end

        attach_secondary_databases({
          adapter: adapter_name,
          tables: extract_tables,
          total_tables: table_names.size,
          schema_version: current_schema_version,
          # The version stamp is read off db/schema.rb and the tables off the
          # connection, so the two can be one migration apart. The tables the
          # dump declares are what lets a consumer say so rather than call a
          # declared table a typo.
          declared_tables: declared_table_names,
          check_constraints: check_constraints,
          enum_types: enum_types,
          generated_columns: generated_columns(schema_reader),
          extensions: extensions,
          # What names the migration behind a declared table the connection lacks.
          pending_migrations: RailsAiContext::PendingMigrations.live(RailsAiContext::PendingMigrations.migrate_dir_for(app.root))
        }.compact)
      end

      # Static tier entry: skip the connection probe entirely and answer from
      # schema.rb / structure.sql / migration files.
      def static_call
        attach_secondary_databases(static_schema_parse)
      end

      private

      def active_record_connected?
        return false unless defined?(ActiveRecord::Base)

        # ActiveRecord::Base.connected? only reports whether a connection has
        # ALREADY been checked out on this thread. On a freshly booted MCP
        # server - before any query runs - it is false even when the database
        # is fully reachable, which wrongly forces the static schema.rb parse.
        # That parse omits the implicit `id` primary key and reports
        # schema.rb-approximate types instead of the live column metadata,
        # undercutting the gem's "live, zero stale data" promise.
        return true if ActiveRecord::Base.connected?

        # Force a real connection. In Rails 8 a lazily checked-out connection
        # reports active? => nil until it actually materializes, so a trivial
        # query is the reliable reachability probe. The rescue below falls back
        # to static parsing when the database is genuinely unreachable (no DB
        # configured, db:create not run, server down). SELECT 1 is valid on
        # sqlite3, postgresql, mysql2, and trilogy.
        ActiveRecord::Base.connection.select_value("SELECT 1")
        true
      rescue => e
        RailsAiContext.debug_fail(e, false, label: "active_record_connected?")
      end

      def adapter_name
        ActiveRecord::Base.connection.adapter_name
      rescue => e
        RailsAiContext.debug_fail(e, "unknown", label: "adapter_name")
      end

      def connection
        ActiveRecord::Base.connection
      end

      def table_names
        @table_names ||= (connection.tables - @partitions.to_a)
          .reject { |t| t.start_with?("ar_internal_metadata", "schema_migrations") }
      end

      def extract_tables
        table_names.each_with_object({}) do |table, hash|
          hash[table] = {
            columns: extract_columns(table),
            indexes: extract_indexes(table),
            foreign_keys: extract_foreign_keys(table),
            primary_key: SchemaConventions.primary_key_value(connection.primary_key(table)),
            comment: table_comment(table),
            unique_constraints: unique_constraints(table)
          }.compact
        end
      end

      def table_comment(table)
        comment = connection.table_comment(table) if connection.supports_comments?
        comment unless comment.to_s.empty?
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "table_comment")
      end

      # Rails 7.1+ on PostgreSQL.
      def unique_constraints(table)
        return unless connection.respond_to?(:unique_constraints) && connection.supports_unique_constraints?

        found = connection.unique_constraints(table).map do |constraint|
          SchemaConventions.unique_constraint_entry(constraint.name, constraint.column, constraint.deferrable)
        end
        found if found.any?
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "unique_constraints")
      end

      def extensions
        found = connection.extensions if connection.respond_to?(:extensions)
        Array(found).map(&:to_s) if found.present?
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extensions")
      end

      # What schema.rb writes for a column beyond its type: the connection's
      # limit, precision and collation, less the defaults the dumper leaves out.
      def column_detail(table, col, bigint)
        native_limit = (connection.native_database_types[col.type] || {})[:limit]
        limit = col.limit unless bigint || col.limit == native_limit || col.sql_type.to_s.match?(/\A(?:tiny|medium|long)?(?:text|blob)\b/i)
        # A datetime's default precision is 6, and MySQL writes none as 0.
        precision = col.precision unless col.type == :datetime && [ nil, 0, 6 ].include?(col.precision) ||
                                         col.type == :time && col.precision.to_i.zero? && col.sql_type.to_s.start_with?("time")
        {
          limit: limit,
          precision: precision,
          scale: col.scale,
          unsigned: (true if col.respond_to?(:unsigned?) && col.unsigned?),
          collation: (col.collation unless col.collation.nil? || col.collation == table_collation(table))
        }
      end

      # MySQL gives every text column the table's collation; the dump names only a different one.
      def table_collation(table)
        return unless connection.respond_to?(:mariadb?)

        @table_collations ||= {}
        return @table_collations[table] if @table_collations.key?(table)

        @table_collations[table] = connection.select_all("SHOW TABLE STATUS LIKE #{connection.quote(table)}").first&.fetch("Collation", nil)
      end

      def extract_columns(table)
        schema_defaults = parse_schema_defaults_for_table(table)

        connection.columns(table).map do |col|
          # schema.rb's dumper names a bigint `bigint`, not integer with limit 8;
          # the static tier reads that name, so the booted one says it too.
          bigint = col.respond_to?(:bigint?) && col.bigint?
          entry = {
            name: col.name,
            type: bigint ? "bigint" : col.type.to_s,
            null: col.null,
            default: col.default,
            **column_detail(table, col, bigint),
            comment: col.comment
          }
          # PostgreSQL gives an array's default as its literal ({}), which the
          # static tier reads the way Rails dumps it ([]).
          if col.respond_to?(:array?) && col.array?
            entry[:array] = true
            entry[:default] = SchemaConventions.format_default(StructureSqlReader.array_default(col.default, col.sql_type_metadata.sql_type)) if col.default.is_a?(String)
          end
          # Supplement with schema.rb default when live DB returns nil
          if entry[:default].nil? && schema_defaults[col.name]
            entry[:default] = schema_defaults[col.name]
          end
          entry.compact
        end
      end

      def extract_indexes(table)
        connection.indexes(table).map do |idx|
          # An expression index's columns come as one String; split into keys as the dump readers do.
          columns = idx.columns.is_a?(String) ? StructureSqlReader.index_keys(idx.columns) : idx.columns
          detail = SchemaConventions.index_detail(
            columns, using: idx.using, type: idx.type, order: idx.orders, opclass: idx.opclasses, length: idx.lengths,
            include: (idx.include if idx.respond_to?(:include)),
            nulls_not_distinct: (idx.nulls_not_distinct if idx.respond_to?(:nulls_not_distinct))
          )
          { name: idx.name, columns: columns, unique: idx.unique, where: idx.where }.compact.merge(detail)
        end
      end

      def extract_foreign_keys(table)
        # PostgreSQL clones a key that references a partitioned table once per partition.
        connection.foreign_keys(table).reject { |fk| @partitions.to_a.include?(fk.to_table) }.map do |fk|
          SchemaConventions.foreign_key_entry(fk.from_table, fk.to_table, fk.column, fk.primary_key, on_delete: fk.on_delete, on_update: fk.on_update)
        end
      rescue => e
        # Some adapters don't support foreign_keys.
        RailsAiContext.debug_fail(e, [], label: "extract_foreign_keys")
      end

      # Supplements live DB column data when the adapter returns nil defaults.
      def parse_schema_defaults_for_table(table)
        schema_reader.defaults_for(table)
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "parse_schema_defaults_for_table")
      end

      def schema_reader
        @schema_reader ||= SchemaReader.new(schema_file_path, partitions: @partitions.to_a)
      end

      # Constraints and enum types are declared in the dump, not reported by
      # the adapter, so the live tier reads them from schema.rb too.
      def check_constraints
        schema_reader.check_constraints
      end

      def enum_types
        schema_reader.enums
      end

      # The tables db/schema.rb declares, or nil when there is no dump to
      # read - nil is "unknown", which is not the claim that the dump
      # declares nothing. A structure.sql app answers nil: reading it costs a
      # full parse on every booted call, and a missing note is better than a
      # slow one.
      def declared_table_names
        return nil unless File.exist?(schema_file_path)

        names = schema_reader.tables.keys.map(&:to_s)
        names.any? ? names : nil
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "declared_table_names")
      end

      def current_schema_version
        RailsAiContext::SchemaVersion.current(app.root.to_s)
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "current_schema_version")
      end

      # Reads the version stamp from the schema.rb file actually being parsed,
      # rather than the app's primary db/schema.rb. Secondary database dumps
      # (db/queue_schema.rb, etc.) carry their own version: keyword, and
      # current_schema_version would otherwise report the primary database's
      # version on every secondary entry.
      def schema_version_for(path)
        RailsAiContext::SchemaVersion.from_schema_rb(path)
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "schema_version_for")
      end

      def schema_file_path
        File.join(app.root, "db", "schema.rb")
      end

      def structure_file_path
        File.join(app.root, "db", "structure.sql")
      end

      def migrations_dir
        File.join(app.root, "db", "migrate")
      end

      # Every db/migrate the app owns: its own and each in-repo engine's, which create tables
      # in the same database.
      def migrations_dirs
        @migrations_dirs ||= MigrationReplay.migration_dirs(app.root.to_s)
      end

      def migration_files
        @migration_files ||= MigrationReplay.migration_files(migrations_dirs)
      end

      # Fallback: parse schema file as text when DB isn't connected.
      # Tries db/schema.rb first, then db/structure.sql, then migrations.
      # This enables introspection in CI, Claude Code, etc.
      # Every key the booted answer carries, answered from the files, and
      # meaning the same thing: `declared_tables` is what db/schema.rb
      # declares, nil for an app whose tables come from structure.sql or the
      # migrations.
      def static_schema_parse
        result = static_schema_sources
        return result unless result.is_a?(Hash) && result[:tables].is_a?(Hash)

        result.merge(declared_tables: declared_table_names)
      end

      def static_schema_sources
        schema_rb_exists = File.exist?(schema_file_path)

        if schema_rb_exists
          result = parse_schema_rb(schema_file_path)
          return result if result[:total_tables].to_i > 0
        end

        if File.exist?(structure_file_path)
          result = parse_structure_sql(structure_file_path)
          return result if result[:total_tables].to_i > 0
        end

        return parse_migrations if migration_files.any?

        # schema.rb exists but has no tables - happens on fresh Rails apps right
        # after `db:create` where no migrations have been run yet. Return a
        # legitimate empty-schema state instead of a misleading "not found" error.
        if schema_rb_exists
          return {
            total_tables: 0,
            tables: {},
            note: "Schema file exists but is empty - no migrations have been run yet. " \
                  "Run `bin/rails db:migrate` after generating migrations to populate schema.rb."
          }
        end

        if RailsAiContext::AppKind.mongoid?(app.root)
          return { unavailable: "this app uses Mongoid; ActiveRecord schema introspection does not apply" }
        end

        # An absent data source, not a failure: :unavailable keeps a fresh
        # greenfield app out of the "introspection failed" warnings banner.
        { unavailable: "No db/schema.rb, db/structure.sql, or migrations found" }
      end

      # Rails multi-database setups dump each secondary database to its own
      # file named after the database.yml entry (db/queue_schema.rb for the
      # queue database, db/cache_structure.sql for sql format). The primary
      # dump keeps the top-level :tables shape; secondaries ride their own
      # key so single-database consumers are unaffected.
      def secondary_database_dumps
        dumps = {}
        Dir.glob(File.join(app.root.to_s, "db", "*_schema.rb")).sort.each do |path|
          name = File.basename(path, ".rb").sub(/_schema\z/, "")
          parsed = parse_schema_rb(path)
          next unless parsed[:total_tables].to_i.positive?

          parsed[:note] = "Parsed from db/#{File.basename(path)} (from committed dump, not a live connection)"
          dumps[name] = parsed
        end
        Dir.glob(File.join(app.root.to_s, "db", "*_structure.sql")).sort.each do |path|
          name = File.basename(path, ".sql").sub(/_structure\z/, "")
          next if dumps.key?(name)

          parsed = parse_structure_sql(path)
          next unless parsed[:total_tables].to_i.positive?

          parsed[:note] = "Parsed from db/#{File.basename(path)} (from committed dump, not a live connection)"
          dumps[name] = parsed
        end
        dumps
      end

      # Additive: only sets :secondary_databases when at least one secondary
      # dump parsed to tables, and only on a result that already has the
      # primary :tables key, so error/unavailable results pass through untouched.
      def attach_secondary_databases(result)
        return result unless result.is_a?(Hash) && result[:tables]

        secondary = secondary_database_dumps
        result[:secondary_databases] = secondary if secondary.any?
        result
      end

      def static_column(column)
        options = column[:options]
        entry = { name: column[:name], type: column[:type] }
        entry[:null] = false if options[:null] == false
        entry[:default] = column[:default] unless column[:default].nil?
        entry[:array] = true if options[:array] == true
        %i[limit precision scale].each { |key| entry[key] = options[key] if options[key].is_a?(Integer) }
        entry[:unsigned] = true if options[:unsigned] == true
        entry[:collation] = options[:collation] if options[:collation].is_a?(String)
        entry[:comment] = options[:comment] if options[:comment].is_a?(String)
        entry[:primary_key] = true if column[:primary_key]
        entry
      end

      def static_index(index)
        columns = index[:columns]
        return nil if columns.empty?

        options = index[:options]
        entry = {
          name:    options[:name]&.to_s,
          columns: columns,
          unique:  options[:unique] == true,
          where:   (options[:where] if options[:where].is_a?(String))
        }
        # An expression index (e.g. "lower(email)") names no plain column.
        entry[:expression] = true if columns.size == 1 && !columns.first.match?(/\A\w+\z/)
        detail = options.slice(:using, :type, :include, :order, :opclass, :length, :nulls_not_distinct)
                        .reject { |_, value| value == RailsAiContext::Confidence::INFERRED }
        entry.compact.merge(SchemaConventions.index_detail(columns, **detail))
      end

      def parse_schema_rb(path)
        content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
        return { error: "schema.rb too large (#{File.size(path)} bytes)" } unless content

        schema = SchemaReader.new(path, pk_type: SchemaConventions.implicit_pk_type(app.root.to_s, path))

        tables = {}
        schema.tables.each do |table_name, declared|
          next if table_name.start_with?("ar_internal_metadata", "schema_migrations")

          comment = declared.dig(:options, :comment)
          unique = Array(declared[:unique_constraints]).map do |constraint|
            SchemaConventions.unique_constraint_entry(constraint.dig(:options, :name), constraint[:columns], constraint.dig(:options, :deferrable))
          end
          tables[table_name] = {
            columns: declared[:columns].map { |c| static_column(c) },
            indexes: declared[:indexes].filter_map { |i| static_index(i) },
            foreign_keys: [],
            comment: (comment if comment.is_a?(String)),
            unique_constraints: (unique if unique.any?),
            unread_calls: declared[:unread_calls]
          }.compact
          key = declared.dig(:options, :primary_key)
          tables[table_name][:primary_key] = SchemaConventions.primary_key_value(key) if key
        end

        schema.foreign_keys.each do |fk|
          tables[fk[:from]]&.dig(:foreign_keys)&.push(
            SchemaConventions.foreign_key_entry(fk[:from], fk[:to], fk[:column], fk[:primary_key], on_delete: fk[:on_delete], on_update: fk[:on_update])
          )
        end

        check_constraints = schema.check_constraints
        enum_types = schema.enums

        version = schema_version_for(path)

        result = {
          adapter: "static_parse",
          tables: tables,
          total_tables: tables.size,
          schema_version: version,
          check_constraints: check_constraints,
          enum_types: enum_types,
          generated_columns: generated_columns(schema),
          note: "Parsed from db/schema.rb (#{connection_state})"
        }
        result[:extensions] = schema.extensions if schema.extensions.any?
        # schema.rb records only the max applied version, so pending here
        # means "migration files newer than the schema version" - exact for
        # linear histories, best-effort for out-of-order merges. With no
        # version recorded there is no answer, so the key stays absent.
        if version
          migrate_dir = RailsAiContext::PendingMigrations.migrate_dir_for(app.root, path)
          result[:pending_migrations] = RailsAiContext::PendingMigrations.for(migrate_dir: migrate_dir, applied: version)
        end
        result
      end

      def parse_structure_sql(path)
        content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
        return { error: "structure.sql too large (#{File.size(path)} bytes)" } unless content

        parsed = StructureSqlReader.parse(content)
        dialect = parsed[:dialect]
        tables = parsed[:tables]

        applied = RailsAiContext::SchemaVersion.applied_versions(content)

        result = {
          adapter: "static_parse",
          dialect: dialect.to_s,
          tables: tables,
          total_tables: tables.size,
          note: "Parsed from db/structure.sql (#{connection_state})"
        }
        if applied.any?
          result[:schema_version] = applied.map(&:to_i).max.to_s
          migrate_dir = RailsAiContext::PendingMigrations.migrate_dir_for(app.root, path)
          result[:pending_migrations] = RailsAiContext::PendingMigrations.for(migrate_dir: migrate_dir, applied: applied)
        end
        result
      end

      def connection_state
        @connection_state || "no DB connection"
      end

      def generated_columns(schema)
        schema.tables.flat_map { |table, declared|
          declared[:columns].filter_map { |column|
            options = column[:options]
            next unless options[:virtual] == true || options[:stored] == true

            { table: table, column: column[:name], stored: options[:stored] == true }
          }
        }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "generated_columns")
      end

      # A table whose create_table names it through the class has no literal to read, so the
      # count says how many names came from the file instead.
      def replay_note(tables, counts)
        inferred = tables.count { |_, data| data[:inferred_name] }
        note = "Reconstructed from #{CountPhrase.call(migration_files.size, "migration file")} " \
               "(#{connection_state}, no schema.rb)"
        note += ", #{CountPhrase.call(inferred, "table name")} read from the file rather than the create_table call" if inferred.positive?
        note += ", #{CountPhrase.call(counts.unnamed, "create_table call")} left unnamed" if counts.unnamed.positive?
        note += ", #{CountPhrase.call(counts.unnamed_columns, "added column")} left unnamed" if counts.unnamed_columns.positive?
        note += ", #{CountPhrase.call(counts.helper_calls, "migration helper call")} not replayed" if counts.helper_calls.positive?
        note += ", #{CountPhrase.call(counts.failed_files, "migration file")} it could not read" if counts.failed_files.positive?
        note
      end

      # Reconstruct schema by replaying migrations in order.
      # Handles: create_table, add_column, remove_column, rename_column,
      # rename_table, drop_table, change_column, add_index, add_reference,
      # add_foreign_key, add_timestamps.
      def parse_migrations
        pk_type = SchemaConventions.implicit_pk_type(app.root.to_s, schema_file_path)
        replayed = MigrationReplay.replayed(migrations_dirs, pk_type: pk_type, root: app.root.to_s)
        tables = replayed.tables

        {
          adapter: "static_parse",
          tables: tables,
          total_tables: tables.size,
          note: replay_note(tables, replayed.counts)
        }
      end
    end
  end
end
