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
        return from_tables({}, source: :none, path: nil) if RailsAiContext::AppKind.sequel_schema(root)

        candidates = SchemaDumpPath.candidates(root)
        candidates.each do |format, path|
          next unless File.exist?(path)

          if format == :ruby
            reader = new(path, pk_type: SchemaConventions.implicit_pk_type(root), search_path: search_path)
            return reader.with_source(:schema_rb) if reader.tables.any?
          else
            content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
            parsed = content && StructureSqlReader.parse(content, search_path: search_path)
            return from_tables(parsed[:tables], source: :structure_sql, path: path, views: parsed[:views]) if parsed && parsed[:tables].any?
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
      def self.from_tables(tables, source:, path:, views: {})
        reader = allocate
        reader.send(:initialize_from_tables, tables, source, path, views)
        reader
      end

      attr_reader :source

      # partitions: the tables the database says are partitions, which a
      # schema.rb from before Rails 8 dumps as plain tables.
      # search_path: the database's configured schema_search_path, which decides the bare names.
      def initialize(path, pk_type: nil, partitions: [], search_path: SchemaConventions::DEFAULT_SEARCH_PATH)
        @path = path
        @search_path = search_path
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

      def initialize_from_tables(tables, source, path, views)
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
          virtual_tables: {},
          not_dumped: {}
        }
      end

      def columns_for(table)
        tables.dig(table, :columns) || []
      end

      def parse
        @parse ||= build
      end

      def empty_schema
        { tables: {}, foreign_keys: [], enums: [], check_constraints: [], extensions: [], views: {}, virtual_tables: {}, not_dumped: {} }
      end

      def build
        schema = empty_schema
        current = nil

        events.sort_by { |e| e[:location] }.each do |event|
          current = absorb(event, schema, current)
        end
        # The connection lists a name once, from the first schema on the search path holding it.
        schema[:tables].reject! { |name, _| @shadowed.include?(name) } if @shadowed

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

        search_path, shadowed = naming
        listeners = { schema: -> { Listeners::SchemaDslListener.new(search_path: search_path, shadowed: shadowed) } }
        results = if size <= RailsAiContext::AstCache::MAX_PARSE_SIZE
          SourceIntrospector.walk(path, listeners)
        else
          source = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
          source ? SourceIntrospector.walk_source(source, listeners) : {}
        end

        results[:schema] || []
      end

      # The search path less schemas the dump never creates, and the names an earlier schema hides.
      def naming
        return [ @search_path, nil ] if @search_path == SchemaConventions::DEFAULT_SEARCH_PATH

        source = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size).to_s

        path = SchemaConventions.existing_search_path(@search_path, source.scan(/^\s*create_schema\s+"([^"]+)"/).flatten)
        relations = source.scan(/^\s*create_(?:table|view|virtual_table)\s+"([^"]+\.[^"]+)"/).flatten
        @shadowed = SchemaConventions.shadowed_names(relations, path) if path.size > 1
        [ path, @shadowed ]
      end

      # Returns the table each subsequent column and index belongs to.
      def absorb(event, schema, current)
        case event[:type]
        when :create_table
          options = event[:options] || {}
          # With a pk_type, the implied id is a column like any other - the
          # convention lives in SchemaConventions, shared with the replay.
          implied = @pk_type ? SchemaConventions.implicit_primary_key(options, @pk_type) : []
          schema[:tables][event[:table]] ||= { options: options, columns: implied, indexes: [] }
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
