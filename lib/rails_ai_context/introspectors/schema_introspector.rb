# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts database schema information including tables, columns,
    # indexes, and foreign keys from the Rails application.
    class SchemaIntrospector < Base
      extend StaticTier
      static_tier :alternate_source

      # dump path => [what the dump was read under, its DumpLookup], kept across runs for a later lookup.
      DUMP_LOOKUPS = Concurrent::Map.new
      private_constant :DUMP_LOOKUPS

      # @return [Hash] database schema context
      def call
        unless active_record_connected?
          # The dump's version says which files are newer than it, which is a
          # claim about a database; with none to ask, nothing is known pending.
          result = static_schema_parse
          if result.key?(:pending_migrations)
            result.delete(:pending_migrations)
            result[:pending_unknown] = unreachable_reason
          end
          return attach_secondary_databases(result)
        end

        @partitions = PgPartitions.names(connection)
        if table_names.empty?
          # Connected but not migrated: the files answer, and the notes say so.
          # The connection knows what has run, so its pending list stands.
          @connection_state = "connected, no tables yet"
          result = static_schema_parse
          live = RailsAiContext::PendingMigrations.live(RailsAiContext::PendingMigrations.migrate_dirs_for(app.root))
          result[:pending_migrations] = live if live
          result[:connected_tables] = 0 unless result.key?(:error) || result.key?(:unavailable)
          return attach_secondary_databases(result)
        end

        tables = extract_tables
        attach_secondary_databases({
          adapter: adapter_name,
          tables: tables,
          search_path: live_search_path,
          total_tables: SchemaConventions.table_count(tables),
          schema_version: current_schema_version,
          # The version stamp is read off db/schema.rb and the tables off the
          # connection, so the two can be one migration apart. The tables the
          # dump declares are what lets a consumer say so rather than call a
          # declared table a typo.
          **declaration_keys,
          check_constraints: SchemaConventions.check_constraints_of(tables),
          enum_types: enum_types,
          generated_columns: SchemaConventions.generated_columns_of(tables),
          extensions: extensions,
          # What names the migration behind a declared table the connection lacks.
          pending_migrations: RailsAiContext::PendingMigrations.live(RailsAiContext::PendingMigrations.migrate_dirs_for(app.root))
        }.compact)
      end

      # Static tier entry: skip the connection probe entirely and answer from
      # schema.rb / structure.sql / migration files.
      def static_call
        attach_secondary_databases(static_schema_parse)
      end

      # A table asked for by a schema-qualified name the listing does not hold. Read only when
      # asked, since an app can hold a schema per tenant.
      def self.qualified_table(name, database: nil, live: false)
        RailsAiContext::RunCache.fetch([ :qualified_table, name, database, live ]) do
          new(RailsAiContext.default_app).qualified_table(name, database: database, live: live)
        end
      end

      def self.qualified_table_note(name)
        new(RailsAiContext.default_app).qualified_table_note(name)
      end

      # [the name the listing shows it under, the table] from the connection or the dump, whichever tier answers.
      def qualified_table(name, database: nil, live: false)
        return unless name.to_s.include?(".")

        if live
          data = live_qualified_table(name) or return
          return [ live_listed_name(name) || name, data ]
        end

        found = dump_lookup(database)&.table(name)
        found if found&.last
      end

      # Why the primary's schema.rb leaves out a schema-qualified table, or nil.
      def qualified_table_note(name)
        dump_lookup(nil)&.missing&.call(name)
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
        @connection_error = e
        RailsAiContext.debug_fail(e, false, label: "active_record_connected?")
      end

      # Why the connection did not answer, in the words a reader acts on.
      def unreachable_reason
        error = @connection_error
        if defined?(ActiveRecord::NoDatabaseError) && error.is_a?(ActiveRecord::NoDatabaseError)
          "the database does not exist yet (`bin/rails db:create`, then `bin/rails db:migrate`)"
        elsif error
          "the database did not answer (#{error.class.name})"
        else
          "there is no database connection"
        end
      end

      def adapter_name
        ActiveRecord::Base.connection.adapter_name
      rescue => e
        RailsAiContext.debug_fail(e, "unknown", label: "adapter_name")
      end

      def sqlite?
        adapter_name.to_s.match?(/sqlite/i)
      end

      def postgres?
        adapter_name.to_s.match?(/postg/i)
      end

      # Every MySQL adapter inherits mariadb? from AbstractMysqlAdapter.
      def mysql?
        connection.respond_to?(:mariadb?)
      end

      def connection
        ActiveRecord::Base.connection
      end

      def table_names
        @table_names ||= (connection.tables - @partitions.to_a - sqlite_hidden_tables)
          .reject { |t| t.start_with?("ar_internal_metadata", "schema_migrations") }
      end

      def extract_tables
        add_live_relations(table_names.to_h { |table| [ table, table_entry(table) ] })
      end

      def table_entry(table)
        entry = {
          columns: extract_columns(table),
          indexes: extract_indexes(table),
          foreign_keys: extract_foreign_keys(table),
          primary_key: SchemaConventions.primary_key_value(connection.primary_key(table)),
          comment: table_comment(table),
          unique_constraints: unique_constraints(table),
          check_constraints: table_check_constraints(table)
        }.compact
        SchemaConventions.mark_primary_key(entry)
        entry
      end

      # The schemas the connection searches, which name its enum types; public alone is the default.
      # SQL, as 8.1's connection.current_schemas runs it (schema_statements.rb:242-246), which 7.0 to 8.0 lack.
      def live_search_path
        return unless postgres?

        found = connection.select_value("SELECT current_schemas(false)")
        found = found.to_s.delete_prefix("{").delete_suffix("}").split(",").map { |schema| schema.delete('"') } unless found.is_a?(Array)
        found unless found == PgNaming::DEFAULT_SEARCH_PATH
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "search_path")
      end

      # The bare name, when the search path resolves it to this same table, as connection.tables lists it.
      def live_listed_name(name)
        bare = name.split(".").last
        same = connection.select_value("SELECT to_regclass(#{connection.quote(connection.quote_table_name(bare))}) = " \
                                       "to_regclass(#{connection.quote(connection.quote_table_name(name))})")
        bare if same
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "listed_name")
      end

      # quoted_scope reads a qualified name's own schema (schema_statements.rb:1179-1191).
      def live_qualified_table(name)
        table_entry(name) if postgres? && connection.data_source_exists?(name)
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "qualified_table")
      end

      # connection.tables leaves out views and SQLite's virtual tables; a view's SQL is the dump's.
      def add_live_relations(tables)
        materialized, extension_owned = pg_view_names
        (connection.views - tables.keys - extension_owned).each do |view|
          # Only a materialized view holds rows, so only it can carry an index.
          indexes = materialized.include?(view) ? extract_indexes(view) : []
          tables[view] = SchemaConventions.view_entry(declared_dump.views.dig(view, :sql), materialized: materialized.include?(view),
                                                      columns: extract_columns(view), indexes: indexes)
        end
        sqlite_virtual_tables.each do |name, (mod, arguments)|
          tables[name] ||= SchemaConventions.virtual_table_entry(mod, arguments.to_s.split(", "))
        end
        tables
      end

      def sqlite_virtual_tables
        sqlite? ? SqliteVirtualTables.of(connection) : {}
      end

      def sqlite_hidden_tables
        sqlite? ? SqliteVirtualTables.hidden(connection) : []
      end

      PG_VIEWS = <<~SQL
        SELECT c.relname, c.relkind, EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('v', 'm') AND n.nspname = ANY (current_schemas(false))
      SQL

      # PostgreSQL lists materialized views among the views, and an extension's own
      # (PostGIS geometry_columns, pg_stat_statements) beside the app's.
      def pg_view_names
        return [ [], [] ] unless postgres?

        rows = connection.select_rows(PG_VIEWS)
        [ rows.select { |_, kind, _| kind == "m" }.map(&:first), rows.select { |*, owned| owned == true || owned == "t" }.map(&:first) ]
      rescue => e
        RailsAiContext.debug_fail(e, [ [], [] ], label: "pg_view_names")
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

      # The connection's, named as the dump names them: Rails leaves out a chk_rails_ name it made up.
      def table_check_constraints(table)
        found = if connection.supports_check_constraints?
          connection.check_constraints(table).map do |constraint|
            { name: (constraint.name if constraint.export_name_on_schema_dump?), expression: constraint.expression }.compact
          end
        else
          schema_reader.check_constraints.select { |c| c[:table] == table }.map { |c| c.slice(:name, :expression) }
        end
        found if found.any?
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "table_check_constraints")
      end

      def extensions
        found = connection.extensions if connection.respond_to?(:extensions)
        Array(found).map(&:to_s).sort if found.present?
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
          size: (SchemaConventions.mysql_text_size(col.sql_type) if mysql?),
          collation: (col.collation unless col.collation.nil? || col.collation == table_collation(table))
        }
      end

      TABLE_COLLATIONS = "SELECT table_name, table_collation FROM information_schema.tables WHERE table_schema = DATABASE()"

      # MySQL gives every text column the table's collation; the dump names only a different one.
      def table_collation(table)
        return unless mysql?

        @table_collations ||= connection.select_rows(TABLE_COLLATIONS).to_h
        @table_collations[table]
      end

      def extract_columns(table)
        schema_defaults = parse_schema_defaults_for_table(table)

        connection.columns(table).map do |col|
          # schema.rb's dumper names a bigint `bigint`, not integer with limit 8;
          # the static tier reads that name, so the booted one says it too.
          bigint = col.respond_to?(:bigint?) && col.bigint?
          entry = {
            name: col.name,
            type: bigint ? "bigint" : dumped_type(col),
            null: col.null,
            default: col.default,
            **column_detail(table, col, bigint),
            comment: col.comment
          }
          if col.respond_to?(:virtual?) && col.virtual?
            entry[:generated] = (col.default_function || declared_generated(table, col.name)).to_s
            entry[:stored] = stored_generated?(col)
          end
          entry[:enum_type] = col.sql_type.to_s if col.type == :enum
          entry[:default] = boolean_default(col) if col.type == :boolean
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

      # MySQL keeps a boolean's default as 1 or 0, which schema.rb, the static
      # tier and PostgreSQL all spell true or false: Active Model's boolean
      # type reads it, as the column's own cast type does on every adapter.
      def boolean_default(col)
        return col.default unless col.default.is_a?(String)

        value = ActiveModel::Type::Boolean.new.cast(col.default)
        value.nil? ? col.default : value.to_s
      rescue StandardError => e
        RailsAiContext.debug_fail(e, col.default, label: "boolean_default")
      end

      # MySQL's dumper writes an enum or set column by its full SQL type, and a timestamp as one.
      def dumped_type(col)
        return col.type.to_s unless mysql?
        return col.sql_type.to_s if col.sql_type.to_s.match?(/\A(?:enum|set)\b/)

        col.sql_type.to_s.match?(/\Atimestamp\b/) ? "timestamp" : col.type.to_s
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
          SchemaConventions.foreign_key_entry(fk.from_table, fk.to_table, fk.column, fk.primary_key, on_delete: fk.on_delete, on_update: fk.on_update,
                                                                                                    deferrable: fk.deferrable, validate: fk.validate?)
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
        @schema_reader ||= SchemaReader.new(schema_file_path, partitions: @partitions.to_a, search_path: RailsAiContext::DatabaseYml.schema_search_path(app.root),
                                                              user_schema: RailsAiContext::DatabaseYml.user_schema(app.root),
                                                              rails_version: rails_version)
      end

      # The configured dump, whatever its format: a view's SQL and a MySQL generated expression are not on the connection.
      def declared_dump
        format, = present_dump
        format == :sql ? SchemaReader.for(app.root) : schema_reader
      end

      # MySQL keeps a generated column's expression out of the column, so the dump says it.
      def declared_generated(table, name)
        column = declared_dump.tables.dig(table, :columns)&.find { |c| c[:name] == name }
        column && (column.dig(:options, :as) || column[:generated])
      end

      # PostgreSQL before Rails 7.1 had only stored generated columns.
      def stored_generated?(col)
        return col.virtual_stored? if col.respond_to?(:virtual_stored?)
        return col.extra.to_s.match?(/\b(?:STORED|PERSISTENT)\b/) if col.respond_to?(:extra)

        true
      end

      # PostgreSQL's, from the connection: 7.0 gives the labels as one string, 7.1+ as an array.
      def enum_types
        return schema_reader.enums unless connection.respond_to?(:enum_types)

        connection.enum_types.map do |name, values|
          { name: name.to_s, values: values.is_a?(String) ? values.delete("{}").split(",") : Array(values).map(&:to_s) }
        end.sort_by { |enum| enum[:name] }
      rescue => e
        RailsAiContext.debug_fail(e, schema_reader.enums, label: "enum_types")
      end

      # The tables db/schema.rb declares, or nil when there is no dump to
      # read - nil is "unknown", which is not the claim that the dump
      # declares nothing. A structure.sql app answers nil: reading it costs a
      # full parse on every booted call, and a missing note is better than a
      # slow one.
      def declared_table_names
        return nil unless schema_file_path && File.exist?(schema_file_path)

        # Virtual tables and tables the dumper skipped count as tables, as the connection lists them.
        names = (schema_reader.tables.keys + schema_reader.virtual_tables.keys + schema_reader.not_dumped.keys).map(&:to_s).uniq
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

      def dump_candidates
        @dump_candidates ||= SchemaDumpPath.candidates(app.root)
      end

      # The dump Rails loads for this app, whether or not it is on disk.
      def schema_dump_name
        dump_candidates.first.last
      end

      # The first dump on disk, as the static tier reads it; the configured name when none is.
      def present_dump
        @present_dump ||= SchemaDumpPath.present(app.root) || dump_candidates.first
      end

      # The schema.rb dump the readers answer from, or nil when it is structure.sql.
      def schema_file_path
        format, path = present_dump
        path if format == :ruby
      end

      # A secondary dump's name says its database; the primary's, whatever schema_dump calls it, does not.
      def secondary_dump(path)
        path unless dump_candidates.any? { |_, candidate| candidate == path }
      end

      def migrate_dir_for_dump(path)
        RailsAiContext::PendingMigrations.migrate_dirs_for(app.root, secondary_dump(path))
      end

      def relative_dump_path(path)
        path.delete_prefix("#{app.root.to_s.chomp('/')}/")
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
        @migration_files ||= MigrationReplay.migration_files(migrations_dirs, root: app.root)
      end

      # Fallback when no database answers: the dump file, then the migrations.
      # Every key the booted answer carries, answered from the files, and
      # meaning the same thing: `declared_tables` is what the schema.rb dump
      # declares and `declared_in` names that dump, both nil for an app whose
      # tables come from structure.sql or the migrations.
      def static_schema_parse
        result = static_schema_sources
        return result unless result.is_a?(Hash) && result[:tables].is_a?(Hash)

        result.merge(declaration_keys)
      end

      def declaration_keys
        declared = declared_table_names
        { declared_tables: declared, declared_in: (relative_dump_path(schema_file_path) if declared) }
      end

      # The configured dump first (database.yml's schema_dump, schema_format), then the default files.
      def static_schema_sources
        if (reason = RailsAiContext::AppKind.without_active_record(app.root) || RailsAiContext::AppKind.sequel_schema(app.root))
          return { unavailable: "#{reason}; ActiveRecord schema introspection does not apply" }
        end

        present = dump_candidates.select { |_, path| File.exist?(path) }
        present.each do |format, path|
          result = parse_dump(format, path)
          return result if result[:tables].present? || result[:error]
        end

        return parse_migrations if migration_files.any?

        # An empty schema.rb is a fresh app right after `db:create`, not a missing source.
        format, path = present.first
        if format == :ruby
          return {
            total_tables: 0,
            tables: {},
            note: "Schema file exists but is empty - no migrations have been run yet. " \
                  "Run `bin/rails db:migrate` after generating migrations to populate #{relative_dump_path(path)}."
          }
        elsif format == :sql
          return { total_tables: 0, tables: {}, note: "#{relative_dump_path(path)} has no CREATE TABLE statement this reader could read." }
        end

        if RailsAiContext::AppKind.mongoid?(app.root)
          return { unavailable: "this app uses Mongoid; ActiveRecord schema introspection does not apply" }
        end

        if secondary_database_dumps.any?
          return { total_tables: 0, tables: {}, note: "The primary database has no tables yet: no #{relative_dump_path(schema_dump_name)} or migrations found." }
        end

        # An absent data source, not a failure: :unavailable keeps a fresh
        # greenfield app out of the "introspection failed" warnings banner.
        { unavailable: "No #{relative_dump_path(schema_dump_name)} or migrations found" }
      end

      # Rails multi-database setups dump each secondary database to its own
      # file named after the database.yml entry (db/queue_schema.rb for the
      # queue database, db/cache_structure.sql for sql format). The primary
      # dump keeps the top-level :tables shape; secondaries ride their own
      # key so single-database consumers are unaffected.
      def secondary_database_dumps
        @secondary_database_dumps ||= read_secondary_database_dumps
      end

      # [name, format, path] for each secondary database's dump on disk, the configured first.
      def secondary_dump_files
        primary = dump_candidates.map(&:last)
        configured = SchemaDumpPath.secondaries(app.root).map { |name, (format, path)| [ name, format, path ] }
        taken = primary + configured.map(&:last)
        globbed = SchemaDumpPath::FILE_NAMES.flat_map do |format, file|
          kind, ext = file.split(".")
          Dir.glob(File.join(app.root.to_s, "db", "*_#{kind}.#{ext}")).sort
            .reject { |path| taken.include?(path) }
            .map { |path| [ File.basename(path, ".#{ext}").delete_suffix("_#{kind}"), format, path ] }
        end
        (configured + globbed).reject { |_, _, path| primary.include?(path) || !File.exist?(path) }
      end

      def read_secondary_database_dumps
        dumps = secondary_dump_files.each_with_object({}) do |(name, format, path), found|
          next if found.key?(name)

          parsed = parse_dump(format, path)
          next if parsed[:tables].blank?

          parsed[:note] = "Parsed from #{relative_dump_path(path)} (from committed dump, not a live connection)"
          found[name] = parsed.merge(database_files(path, migrate_dir_for_dump(path)))
        end
        replay_secondary_migrations(dumps)
      end

      # Where a secondary database's schema lives, app-relative, so a rule
      # file can name its dump and the migrations directories it has.
      def database_files(dump, migrate_dirs)
        dirs = migrate_dirs.select { |dir| Dir.exist?(dir) }.map { |dir| relative_dump_path(dir) }
        { dump: (relative_dump_path(dump) if dump), migrations_paths: (dirs if dirs.any?) }.compact
      end

      # A database whose dump is not written yet answers from its own migrations_paths.
      def replay_secondary_migrations(dumps)
        RailsAiContext::DatabaseYml.task_secondaries(app.root).each do |name, entry|
          next if dumps.key?(name)

          dirs = MigrationReplay.configured_dirs(app.root.to_s, entry) or next
          pk_type = SchemaConventions.implicit_pk_type(app.root.to_s, database: name)
          tables = MigrationReplay.tables(dirs, pk_type: pk_type, root: app.root.to_s)
          next if tables.empty?

          tables.each_value { |table| SchemaConventions.mark_primary_key(table) }
          _, dump = SchemaDumpPath.secondaries(app.root)[name]
          dumps[name] = {
            adapter: "static_parse", tables: tables, total_tables: SchemaConventions.table_count(tables),
            note: "Reconstructed from the migrations in #{dirs.map { |dir| relative_dump_path(dir) }.join(', ')} (#{connection_state}, no #{dump ? relative_dump_path(dump) : "#{name}_schema.rb"})"
          }.merge(database_files(dump, dirs))
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
        if column[:virtual]
          entry[:generated] = options[:as].is_a?(String) ? options[:as] : ""
          entry[:stored] = options[:stored] == true
        end
        entry[:enum_type] = options[:enum_type].to_s if options[:enum_type].is_a?(Symbol) || options[:enum_type].is_a?(String)
        entry[:null] = false if options[:null] == false
        entry[:default] = column[:default] unless column[:default].nil?
        entry[:array] = true if options[:array] == true
        %i[limit precision scale].each { |key| entry[key] = options[key] if options[key].is_a?(Integer) }
        entry[:unsigned] = true if options[:unsigned] == true
        entry[:size] = options[:size].to_s if options[:size].is_a?(Symbol)
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

      def parse_dump(format, path)
        read_dump(format, path).first
      end

      # [the schema answer, a DumpLookup over the same parse]
      def read_dump(format, path)
        read_at = Time.now
        stamp = lookup_stamp(path)
        found = format == :ruby ? read_schema_rb(path) : read_structure_sql(path)
        # A same-size rewrite inside one mtime tick keeps the whole stat, as AstCache knows.
        DUMP_LOOKUPS[path] = [ stamp, found.last ] if found.last && stamp.first < read_at - RailsAiContext::AstCache::RACY_WINDOW
        found
      end

      # Every input the reader takes besides the file; pk_type is bigint for every PostgreSQL dump.
      def lookup_stamp(path)
        stat = File.stat(path)
        [ stat.mtime, stat.size, stat.ino, search_path_for(path), rails_version,
          RailsAiContext::DatabaseYml.user_schema(app.root, database_name_for(path)) ]
      end

      # The tables of one dump by the names a lookup may ask for.
      DumpLookup = Struct.new(:listed, :qualified, :names, :missing, :placed) do
        def table(name)
          shown = names.relation(name)
          return [ name, qualified[shown] ] if shown.include?(".")

          [ shown, listed[shown] ] if placed
        end
      end

      def dump_lookup(database)
        adapter = SchemaConventions.database_adapter_for(app.root.to_s, database || "primary")
        return if adapter && !adapter.start_with?("postg")

        _, format, path = database ? secondary_dump_files.find { |name, _, _| name == database } : [ nil, *present_dump ]
        return unless path && File.exist?(path)

        cached = DUMP_LOOKUPS[path]
        cached && cached.first == lookup_stamp(path) ? cached.last : read_dump(format, path).last
      end

      def read_schema_rb(path)
        content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
        return [ { error: "#{relative_dump_path(path)} too large (#{File.size(path)} bytes, over max_schema_file_size)" }, nil ] unless content

        search_path = search_path_for(path)
        schema = SchemaReader.new(path, pk_type: SchemaConventions.implicit_pk_type(app.root.to_s, secondary_dump(path)), search_path: search_path,
                                        user_schema: RailsAiContext::DatabaseYml.user_schema(app.root, database_name_for(path)), rails_version: rails_version)

        tables = static_tables(schema.tables)
        qualified = static_tables(schema.qualified_tables)
        every = tables.merge(qualified)

        schema.foreign_keys.each do |fk|
          every[fk[:from]]&.dig(:foreign_keys)&.push(
            SchemaConventions.foreign_key_entry(fk[:from], fk[:to], fk[:column], fk[:primary_key], **fk.slice(*SchemaConventions::FOREIGN_KEY_OPTIONS))
          )
        end

        schema.check_constraints.each do |constraint|
          table = every[constraint[:table]] or next
          (table[:check_constraints] ||= []) << constraint.slice(:name, :expression)
        end
        views = schema.views.transform_values { |view| view.merge(indexes: Array(view[:indexes]).filter_map { |i| static_index(i) }) }
        SchemaConventions.add_relations(tables, views: views, virtual_tables: schema.virtual_tables, not_dumped: schema.not_dumped)
        # A view outside the search path is findable only by its qualified name, as a table is.
        tables.keys.select { |name| name.include?(".") }.each { |name| qualified[name] = tables.delete(name) }

        version = schema_version_for(path)

        result = {
          adapter: "static_parse",
          tables: tables,
          total_tables: SchemaConventions.table_count(tables),
          schema_version: version,
          check_constraints: SchemaConventions.check_constraints_of(tables),
          enum_types: schema.enums,
          generated_columns: SchemaConventions.generated_columns_of(tables),
          note: "Parsed from #{relative_dump_path(path)} (#{connection_state})"
        }
        result[:search_path] = schema.search_path unless schema.search_path == PgNaming::DEFAULT_SEARCH_PATH
        result[:extensions] = schema.extensions.sort if schema.extensions.any?
        # schema.rb records only the max applied version, so pending here
        # means "migration files newer than the schema version" - exact for
        # linear histories, best-effort for out-of-order merges. With no
        # version recorded there is no answer, so the key stays absent.
        if version
          migrate_dir = migrate_dir_for_dump(path)
          result[:pending_migrations] = RailsAiContext::PendingMigrations.for(migrate_dir: migrate_dir, applied: version, root: app.root)
        end
        missing = ->(name) { PgNaming.missing_from_schema_rb(name, search_path, schema.schemas, schema.dump_version, relative_dump_path(path)) }
        placed = PgNaming.dump_places_names?(schema.dump_version, schema.search_path)
        [ result, DumpLookup.new(tables, qualified, schema.names, missing, placed) ]
      end

      def static_tables(declared_tables)
        declared_tables.each_with_object({}) do |(table_name, declared), tables|
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
          SchemaConventions.mark_primary_key(tables[table_name])
        end
      end

      def read_structure_sql(path)
        content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
        return [ { error: "#{relative_dump_path(path)} too large (#{File.size(path)} bytes, over max_schema_file_size)" }, nil ] unless content

        parsed = StructureSqlReader.parse(content, search_path: search_path_for(path), rails_version: rails_version)
        dialect = parsed[:dialect]
        tables = parsed[:tables]
        tables.each_value { |table| SchemaConventions.mark_primary_key(table) }
        parsed[:qualified_tables].each_value { |table| SchemaConventions.mark_primary_key(table) }
        SchemaConventions.add_relations(tables, views: parsed[:views], virtual_tables: parsed[:virtual_tables])

        applied = RailsAiContext::SchemaVersion.applied_versions(content)

        result = {
          adapter: "static_parse",
          dialect: dialect.to_s,
          tables: tables,
          total_tables: SchemaConventions.table_count(tables),
          check_constraints: SchemaConventions.check_constraints_of(tables),
          enum_types: parsed[:enums],
          generated_columns: SchemaConventions.generated_columns_of(tables),
          note: "Parsed from #{relative_dump_path(path)} (#{connection_state})"
        }
        result[:search_path] = parsed[:names].path unless parsed[:names].path == PgNaming::DEFAULT_SEARCH_PATH
        result[:extensions] = parsed[:extensions].sort if parsed[:extensions].any?
        if applied.any?
          result[:schema_version] = applied.map(&:to_i).max.to_s
          migrate_dir = migrate_dir_for_dump(path)
          result[:pending_migrations] = RailsAiContext::PendingMigrations.for(migrate_dir: migrate_dir, applied: applied, root: app.root)
        end
        [ result, DumpLookup.new(tables, parsed[:qualified_tables], parsed[:names], ->(_) { }, true) ]
      end

      def rails_version
        @rails_version ||= PgNaming.rails_version(app.root)
      end

      def search_path_for(dump_path)
        RailsAiContext::DatabaseYml.schema_search_path(app.root, database_name_for(dump_path))
      end

      def database_name_for(dump_path)
        SchemaDumpPath.database_name(app.root.to_s, secondary_dump(dump_path))
      end

      def connection_state
        @connection_state || "no DB connection"
      end

      # A table whose create_table names it through the class has no literal to read, so the
      # count says how many names came from the file instead.
      def replay_note(tables, counts)
        inferred = tables.count { |_, data| data[:inferred_name] }
        _, dump = SchemaDumpPath.present(app.root.to_s)
        note = "Reconstructed from #{CountPhrase.call(migration_files.size, "migration file")} " \
               "(#{connection_state}, #{dump ? "#{relative_dump_path(dump)} declares no tables" : "no schema.rb"})"
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
        pk_type = SchemaConventions.implicit_pk_type(app.root.to_s)
        replayed = MigrationReplay.replayed(migrations_dirs, pk_type: pk_type, root: app.root.to_s)
        tables = replayed.tables
        tables.each_value { |table| SchemaConventions.mark_primary_key(table) }

        {
          adapter: "static_parse",
          tables: tables,
          total_tables: SchemaConventions.table_count(tables),
          note: replay_note(tables, replayed.counts)
        }
      end
    end
  end
end
