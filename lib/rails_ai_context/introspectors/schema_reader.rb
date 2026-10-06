# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # AST-backed view of a schema.rb dump: which tables it declares, their
    # columns, defaults and indexes, plus the foreign keys, enum types and
    # check constraints declared alongside them.
    #
    # The listener emits a flat, ordered event list, so columns, in-table
    # indexes and in-table constraints are attached to the most recent
    # create_table. Top-level add_index and add_check_constraint name their
    # own table.
    #
    # Callers keep their own output shapes: this reads the dump, it does not
    # decide how a table is reported.
    #
    # `SchemaReader.for(root)` answers the question-level API (tables,
    # column?, any_column?, defaults_for) from whichever source the app
    # committed - schema.rb, structure.sql, or a migration replay - so no
    # caller has to name a file or go empty-handed on a structure.sql app.
    class SchemaReader
      # The source-choosing entry. Mirrors the schema introspector's cascade:
      # a dump that parses to zero tables falls through to the next source.
      def self.for(root)
        root = root.to_s
        # One parse per run however many introspectors ask.
        RailsAiContext::RunCache.fetch([ :schema_reader, root ]) { choose(root) }
      end

      def self.choose(root)
        search_path = RailsAiContext::DatabaseYml.schema_search_path(root)
        user_schema = RailsAiContext::DatabaseYml.user_schema(root)
        version = PgNaming.rails_version(root)
        return from_tables({}, source: :none, path: nil) if RailsAiContext::AppKind.sequel_schema(root)

        candidates = SchemaDumpPath.candidates(root)
        candidates.each do |format, path|
          next unless File.exist?(path)

          if format == :ruby
            reader = new(path, pk_type: SchemaConventions.implicit_pk_type(root), search_path: search_path, user_schema: user_schema,
                                    rails_version: version)
            return reader.with_source(:schema_rb) if reader.tables.any?
          else
            content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
            parsed = content && StructureSqlReader.parse(content, search_path: search_path, rails_version: version)
            if parsed && parsed[:tables].any?
              return from_tables(parsed[:tables], source: :structure_sql, path: path, views: parsed[:views], qualified_tables: parsed[:qualified_tables])
            end
          end
        end

        migrate_dirs = MigrationReplay.migration_dirs(root)
        if MigrationReplay.migration_files(migrate_dirs, root: root).any?
          pk_type = SchemaConventions.implicit_pk_type(root)
          return from_tables(MigrationReplay.tables(migrate_dirs, pk_type: pk_type, root: root),
                             source: :migrations, path: migrate_dirs.first)
        end

        from_tables({}, source: :none, path: nil)
      end

      # A reader over an already-parsed tables hash, for the sources that do
      # not go through the schema.rb event fold.
      def self.from_tables(tables, source:, path:, views: {}, qualified_tables: {})
        reader = allocate
        reader.send(:initialize_from_tables, tables, source, path, views, qualified_tables)
        reader
      end

      attr_reader :source

      # partitions: the tables the database says are partitions, which a
      # schema.rb from before Rails 8 dumps as plain tables.
      # search_path: the database's configured schema_search_path; rails_version: the app's, else the
      # dump's stamp. Together they decide the names the booted app reads. user_schema: the one "$user" names.
      def initialize(path, pk_type: nil, partitions: [], search_path: PgNaming::DEFAULT_SEARCH_PATH, user_schema: nil, rails_version: nil)
        @path = path
        @search_path = search_path
        @user_schema = user_schema
        @rails_version = rails_version
        @pk_type = pk_type
        @partitions = partitions
        @source = File.exist?(path.to_s) ? :schema_rb : :none
      end

      def with_source(source)
        @source = source
        self
      end

      # @return [Hash] table name => { options:, columns: [...], indexes: [...] }
      def tables
        parse[:tables]
      end

      # @return [Hash] the tables the search path does not show bare, by schema-qualified name
      def qualified_tables
        parse[:qualified_tables]
      end

      # The configured search path less the schemas the dump never creates.
      def search_path
        names.path
      end

      # How the booted app names this dump's relations and types.
      def names
        parse[:names]
      end

      # @return [Array<String>] the schemas the dump creates
      def schemas
        parse[:schemas]
      end

      # The app's Rails version, else the one the dump is stamped with: the connection's naming.
      def rails_version
        parse[:rails_version]
      end

      # The Rails version that wrote the dump, from its stamp, else the app's: the dump's naming.
      def dump_version
        parse[:dump_version]
      end

      def table?(name)
        tables.key?(name) || qualified_tables.key?(name)
      end

      # @return [Array<Hash>] { from:, to:, column:, primary_key: } per declared
      #   foreign key, whichever source the schema was read from
      def foreign_keys
        parse[:foreign_keys]
      end

      # @return [Array<Hash>] { name:, values: } per declared enum type
      def enums
        parse[:enums]
      end

      # @return [Array<Hash>] { table:, name:, expression: } per declared constraint, name when given
      def check_constraints
        parse[:check_constraints]
      end

      # @return [Array<String>] the extensions the dump enables
      def extensions
        parse[:extensions]
      end

      # @return [Hash] view name => { materialized:, sql: }
      def views
        parse[:views]
      end

      # @return [Hash] virtual table name => { module:, arguments: }
      def virtual_tables
        parse[:virtual_tables]
      end

      # @return [Hash] table name => why the dumper wrote a comment in its place
      def not_dumped
        parse[:not_dumped]
      end

      # Declared defaults for one table, as source text. Callers report these
      # verbatim when the live database returns no default.
      def defaults_for(table)
        columns_for(table).each_with_object({}) do |column, defaults|
          defaults[column[:name]] = column[:default] unless column[:default].nil?
        end
      end

      def column?(table, name)
        columns_for(table).any? { |c| c[:name] == name }
      end

      def any_column?(name)
        tables.any? { |table, _| column?(table, name) }
      end

      private

      attr_reader :path

      def initialize_from_tables(tables, source, path, views, qualified_tables)
        @path = path
        @pk_type = nil
        @source = source
        @parse = {
          tables: tables,
          # structure.sql and the replay keep from_table/to_table on the table;
          # every reader answers the schema.rb shape, so no consumer checks both.
          foreign_keys: tables.flat_map { |_name, t| t[:foreign_keys] || [] }.map do |fk|
            { from: fk[:from_table], to: fk[:to_table], column: fk[:column], primary_key: fk[:primary_key],
              on_delete: fk[:on_delete], on_update: fk[:on_update] }.compact
          end,
          enums: [],
          check_constraints: [],
          extensions: [],
          views: views,
          qualified_tables: qualified_tables,
          virtual_tables: {},
          not_dumped: {},
          schemas: [],
          names: PgNaming.names(PgNaming::DEFAULT_SEARCH_PATH)
        }
      end

      def columns_for(table)
        tables.dig(table, :columns) || qualified_tables.dig(table, :columns) || []
      end

      def parse
        @parse ||= build
      end

      def empty_schema
        { tables: {}, qualified_tables: {}, foreign_keys: [], enums: [], check_constraints: [], extensions: [], views: {}, virtual_tables: {},
          not_dumped: {}, schemas: [], names: PgNaming.names(@search_path || PgNaming::DEFAULT_SEARCH_PATH), rails_version: @rails_version }
      end

      def build
        schema = empty_schema
        current = nil

        events.sort_by { |e| e[:location] }.each do |event|
          current = absorb(event, schema, current)
        end
        # The same loop writes that table's foreign keys twice (8.0 schema_dumper.rb:134-156).
        schema[:foreign_keys].uniq!
        name_relations(schema)
        # The connection lists a table only when the search path shows it bare.
        schema[:tables].keys.select { |name| name.include?(".") }.each { |name| schema[:qualified_tables][name] = schema[:tables].delete(name) }

        drop_partitions(schema)
      rescue => e
        RailsAiContext.debug_fail(e, empty_schema, label: "SchemaReader")
      end

      # Rails dumps a partition as a table inheriting its parent, and PostgreSQL
      # lets only a partition inherit a partitioned table.
      def drop_partitions(schema)
        table_options = schema[:tables].transform_values { |t| t.dig(:options, :options).to_s }
        partitioned = table_options.select { |_, o| o.start_with?("PARTITION BY") }.keys
        dumped_partitions = []
        loop do
          found = table_options.select { |_, o| partitioned.include?(o[/\AINHERITS \(([^,]+)\)\z/, 1]) }.keys - dumped_partitions
          break if found.empty?

          dumped_partitions.concat(found)
          partitioned.concat(found)
        end
        partitions = dumped_partitions | @partitions

        partitions.each { |name| schema[:tables].delete(name) }
        schema[:foreign_keys].reject! { |fk| partitions.include?(fk[:from]) || partitions.include?(fk[:to]) }
        schema[:check_constraints].reject! { |c| partitions.include?(c[:table]) }
        schema
      end

      # AstCache caps parses below the configured schema limit, so a dump
      # between the two has to be parsed directly. Everything under the cap
      # goes through the cache, which the other introspectors share.
      def events
        return [] unless path && File.exist?(path)

        size = File.size(path)
        return [] if size > RailsAiContext.configuration.max_schema_file_size

        listeners = { schema: -> { Listeners::SchemaDslListener.new(raw_names: true) } }
        results = if size <= RailsAiContext::AstCache::MAX_PARSE_SIZE
          SourceIntrospector.walk(path, listeners)
        else
          source = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
          source ? SourceIntrospector.walk_source(source, listeners) : {}
        end

        results[:schema] || []
      end

      # The booted app's names: a dump before 8.1 already holds them, a later one qualifies them.
      def name_relations(schema)
        # ActiveRecord::Schema[x.y] is Migration.current_version when dumped (schema_dumper.rb:90).
        stamp = schema.delete(:stamp)
        schema[:rails_version] ||= stamp
        version = schema[:dump_version] = stamp || schema[:rails_version]
        # A 7.0 dump names no schema, so only the "$user" one, which rarely exists, is taken as missing.
        created = PgNaming.dump_lists_schemas?(version) ? schema[:schemas] : @search_path - [ @user_schema ]
        path = PgNaming.existing_path(@search_path, created)
        schema[:names] = PgNaming.names(path)
        return unless PgNaming.dump_qualifies_names?(version)

        names = schema[:names] = PgNaming.names(path, relations: schema[:tables].keys + schema[:views].keys + schema[:virtual_tables].keys,
                                                      types: schema[:enums].map { |enum| enum[:name] })
        %i[tables views virtual_tables not_dumped].each { |key| schema[key] = schema[key].transform_keys { |name| names.relation(name) } }
        schema[:foreign_keys].each { |fk| fk.merge!(from: names.relation(fk[:from]), to: names.relation(fk[:to])) }
        schema[:check_constraints].each { |constraint| constraint[:table] = names.relation(constraint[:table]) if constraint[:table] }
        schema[:enums] = PgNaming.enum_list(schema[:enums].to_h { |enum| [ enum[:name], enum[:values] ] }, path, schema[:rails_version])
        schema[:tables].each_value do |table|
          table[:columns].each do |column|
            type = column.dig(:options, :enum_type)
            column[:options] = column[:options].merge(enum_type: names.type(type)) if type.is_a?(String)
          end
        end
      end

      # Returns the table each subsequent column and index belongs to.
      def absorb(event, schema, current)
        case event[:type]
        when :create_table
          options = event[:options] || {}
          # With a pk_type, the implied id is a column like any other - the
          # convention lives in SchemaConventions, shared with the replay.
          implied = @pk_type ? SchemaConventions.implicit_primary_key(options, @pk_type) : []
          # Before 8.1 the dumper writes a name once per search path schema holding it; loading, the last stands.
          schema[:check_constraints].reject! { |constraint| constraint[:table] == event[:table] } if schema[:tables].key?(event[:table])
          schema[:tables][event[:table]] = { options: options, columns: implied, indexes: [] }
          return event[:table]
        when :column
          schema[:tables][current]&.dig(:columns)&.push(column_entry(event)) if current
        when :index
          schema[:tables][current]&.dig(:indexes)&.push(index_entry(event)) if current
        when :unread_call
          SchemaConventions.note_unread_call(schema[:tables][current], event[:name]) if current
        when :add_index
          target = schema[:tables][event[:table]] || schema[:views][event[:table]]
          (target[:indexes] ||= []) << index_entry(event) if target
        when :foreign_key
          schema[:foreign_keys] << event.slice(:from, :to, :column, :primary_key, *SchemaConventions::FOREIGN_KEY_OPTIONS)
        when :unique_constraint
          table = schema[:tables][current] if current
          (table[:unique_constraints] ||= []) << event.slice(:columns, :options) if table
        when :extension
          schema[:extensions] << event[:name]
        when :enum
          schema[:enums] << { name: event[:name], values: event[:values] }
        when :create_schema
          schema[:schemas] << event[:name]
        when :stamp
          schema[:stamp] = event[:version] || PgNaming::UNSTAMPED_DUMP
        when :check_constraint
          schema[:check_constraints] << { table: current, **event.slice(:name, :expression) } if current
        when :add_check_constraint
          schema[:check_constraints] << event.slice(:table, :name, :expression)
        when :view
          schema[:views][event[:name]] = { materialized: event[:materialized], sql: event[:sql] }
        when :virtual_table
          schema[:virtual_tables][event[:name]] = event.slice(:module, :arguments)
        when :not_dumped
          schema[:not_dumped][event[:table]] = event[:reason]
        end

        current
      end

      def column_entry(event)
        options = event[:options] || {}
        {
          name:    column_name(event),
          type:    event[:column_type],
          default: default_for(event, options),
          options: options,
          virtual: event[:virtual]
        }.compact
      end

      def index_entry(event)
        { columns: event[:columns].map(&:to_s), options: event[:options] || {} }
      end

      # A reference declares the foreign key column, not a column of its own name.
      def column_name(event)
        return "#{event[:name]}_id" if %w[references belongs_to].include?(event[:column_type])

        event[:name]
      end

      def default_for(event, options)
        return nil unless options.key?(:default)

        value = options[:default]
        # A non-literal default (a proc, a constant) parses to the confidence
        # marker, so fall back to what the column actually declared.
        return event[:default_source] if value == RailsAiContext::Confidence::INFERRED
        return nil if value.nil?

        value.to_s
      end
    end
  end
end
