# frozen_string_literal: true

require "digest"
require "set"

module RailsAiContext
  module Introspectors
    # The Rails schema conventions every static source must agree on: what a
    # `create_table` implies, what a reference declares, what `t.timestamps`
    # expands to, and how the implicit key is typed per adapter. #140 proved
    # the shape - the foreign-key convention forked across two readers and
    # both invented column names - so each convention lives here once.
    module SchemaConventions
      module_function

      # create_table implies an id primary key unless disabled; the runtime
      # tier reports it, so every static source must too. Composite primary
      # keys (primary_key: [...]) dump their columns as explicit t.* lines -
      # synthesizing an id there would invent a column that does not exist.
      def implicit_primary_key(options, pk_type)
        pk_opt = options[:primary_key]
        composite_pk = !pk_opt.nil? && !pk_opt.is_a?(String) && !pk_opt.is_a?(Symbol)
        return [] if options[:id] == false || composite_pk

        # set_primary_key (7.0 to 8.1): an id: hash gives the type, its other keys the column's options.
        id = options[:id]
        id_options = id.is_a?(Hash) ? id.except(:type).reject { |_, value| value == RailsAiContext::Confidence::INFERRED } : {}
        id = id[:type] if id.is_a?(Hash)
        id_type = (id.is_a?(String) || id.is_a?(Symbol)) && id.to_s != "primary_key" ? id.to_s : pk_type
        [ { name: pk_opt ? pk_opt.to_s : "id", type: id_type, default: nil,
            options: { null: false }.merge(id_options), primary_key: true } ]
      end

      # The dump leaves out column:, primary_key:, validate: true and deferrable: false where they are Rails'
      # defaults; Rails 7.0 reads DEFERRABLE INITIALLY IMMEDIATE back as true, which 7.1 names :immediate.
      def foreign_key_entry(from, to, column, primary_key, on_delete: nil, on_update: nil, deferrable: nil, validate: nil)
        known = ->(value) { value unless value == RailsAiContext::Confidence::INFERRED }
        {
          from_table: from, to_table: to,
          column: primary_key_value(column) || "#{to.to_s.split('.').last.to_s.singularize}_id",
          primary_key: primary_key_value(primary_key) || "id",
          on_delete: known.(on_delete)&.to_s, on_update: known.(on_update)&.to_s,
          deferrable: (deferrable == true ? "immediate" : known.(deferrable)&.to_s if deferrable), validate: (false if validate == false)
        }.compact
      end

      FOREIGN_KEY_OPTIONS = %i[on_delete on_update deferrable validate].freeze

      # An index's options past name, columns, unique and where, as schema.rb
      # writes them; btree is every adapter's default, so the dump leaves it out.
      def index_detail(columns, using: nil, type: nil, include: nil, order: nil, opclass: nil, length: nil, nulls_not_distinct: nil)
        {
          using: (using.to_s unless using.nil? || using.to_s == "btree"),
          type: (type.to_s unless type.nil? || type.to_s.empty?),
          include: (Array(include).map(&:to_s) unless Array(include).empty?),
          order: per_key(order, columns),
          opclass: per_key(opclass, columns),
          length: per_key(length, columns),
          nulls_not_distinct: (true if nulls_not_distinct == true)
        }.compact
      end

      # An index option given per key, or once for every key (`order: :desc`).
      def per_key(value, columns)
        value = Array(columns).to_h { |column| [ column, value ] } unless value.is_a?(Hash)
        value = value.reject { |_, v| v.nil? || v.to_s.empty? }
        value.to_h { |key, v| [ key.to_s, v.is_a?(Integer) ? v : v.to_s ] } unless value.empty?
      end

      # deferrable: false is the default the dump leaves out.
      def unique_constraint_entry(name, columns, deferrable)
        {
          name: name&.to_s,
          columns: Array(columns).map(&:to_s),
          deferrable: (deferrable.to_s if deferrable)
        }.compact
      end

      # Rails' limit before it shortens an index name (max_index_name_size).
      MAX_INDEX_NAME_SIZE = 62

      # Rails' name for an unnamed index (index_name, 7.0 to 8.1), shortened past
      # 62 bytes as 7.1+ does; a longer name could not exist before 7.1.
      def default_index_name(table, columns)
        # A String key with a non-word character is an expression, named by its
        # words (index_name_options, 7.0 and 8.1); an Array is joined as written.
        columns = columns.scan(/\w+/).join("_") if columns.is_a?(String) && columns.match?(/\W/)
        cols = Array(columns).map(&:to_s)
        name = "index_#{table}_on_#{cols.join('_and_')}"
        return name if name.bytesize <= MAX_INDEX_NAME_SIZE

        hashed = "_#{Digest::SHA256.hexdigest(name)[0, 10]}"
        "idx_on_#{cols.join('_')}".byteslice(0, MAX_INDEX_NAME_SIZE - hashed.bytesize) + hashed
      end

      # The columns an index serves on their own: each index's leading key
      # (the leftmost-prefix rule), the primary key's included.
      def lookup_indexed_columns(table)
        leading = Array(table[:indexes]).filter_map { |idx| Array(idx[:columns]).first&.to_s }
        # The payload keeps it on the table; the schema.rb reader in its options.
        key = Array(table[:primary_key] || table.dig(:options, :primary_key)).first
        (key ? leading << key.to_s : leading).to_set
      end

      # A table whose block called what no reader interprets may have indexes
      # the static schema lacks.
      def note_unread_call(table, name)
        return unless table

        table[:unread_calls] = Array(table[:unread_calls]) | [ name.to_s ]
      end

      # A key as a reader writes it beside another key: `id`, or `(id, day)`, so
      # the two sides of a foreign key stay apart.
      def key_text(value)
        columns = Array(value).map(&:to_s)
        columns.size > 1 ? "(#{columns.join(", ")})" : columns.first.to_s
      end

      # A partial index's condition as the dump wrote it, for the end of a line.
      def where_clause(where)
        where ? " where #{where}" : ""
      end

      # Whether some index leads with exactly these columns, in any order: a
      # lookup on all of them uses it, one sitting behind another key cannot.
      def leading_index?(indexes, columns)
        wanted = Array(columns).map(&:to_s).to_set
        Array(indexes).any? { |idx| Array(idx[:columns]).first(wanted.size).map(&:to_s).to_set == wanted }
      end

      # ReferenceDefinition's columns and index (7.0 to 8.1), as the migration's
      # version runs it: no index by default to 4.2, the default pair name to 6.0.
      def reference_definition(table, name, options, pk_type, version: nil)
        options ||= {}
        options = { index: false }.merge(options) if version && (version <=> [ 4, 2 ]) <= 0
        null = options[:null] == false ? { null: false } : {}
        columns = []
        columns << { name: "#{name}_type", type: "string" }.merge(null) if options[:polymorphic]
        id_type = options[:type] ? options[:type].to_s : pk_type
        columns << { name: reference_column_name(name), type: id_type }.merge(null)

        index = options.fetch(:index, true)
        return { columns: columns, index: nil } if index == false || index.nil?

        index_opts = index.is_a?(Hash) ? index : {}
        names = columns.map { |col| col[:name] }
        polymorphic_name = options[:polymorphic] && !(version && (version <=> [ 6, 0 ]) <= 0)
        index_name = index_opts[:name]&.to_s ||
                     (polymorphic_name ? "index_#{table}_on_#{name}" : default_index_name(table, names))
        { columns: columns, index: { name: index_name, columns: names, unique: index_opts[:unique] == true } }
      end

      # A reference declares the foreign key column, not a column of its own name.
      def reference_column_name(name)
        "#{name}_id"
      end

      # TableDefinition#timestamps and add_timestamps (7.0 and 8.1): NOT NULL
      # unless null: says otherwise, and a 4.2 migration allows NULL.
      def timestamps_columns(options = {}, version: nil)
        null = options[:null]
        null = !!(version && (version <=> [ 4, 2 ]) <= 0) if null.nil?
        %w[created_at updated_at].map do |name|
          column = { name: name, type: "datetime" }
          column[:null] = false if null == false
          column[:default] = format_default(options[:default]) if options.key?(:default)
          column
        end
      end

      # The implicit primary key's type is adapter-specific: bigint everywhere
      # since Rails 5.1, except SQLite where it stays integer. The dump does
      # not record it, but config/database.yml names the adapter - looked up
      # per database, because a multi-db app can mix adapters (postgres
      # primary, sqlite queue) and each dump must be typed by its own. dump_path
      # names a secondary database's dump, nil the primary's; database: names the database outright.
      def implicit_pk_type(root, dump_path = nil, database: SchemaDumpPath.database_name(root, dump_path))
        adapter = database_adapter_for(root, database)
        adapter&.start_with?("sqlite") ? "integer" : "bigint"
      end

      # The running environment's adapter for one database, as database.yml and a merged URL name it.
      # A database it does not configure (Rails 8's queue outside production) takes the adapter of the
      # environment that does, else the running primary's.
      def database_adapter_for(root, db_name)
        yml = RailsAiContext::DatabaseYml
        entry = yml.entry(root, db_name) || yml.elsewhere(root, db_name)&.last
        yml.adapter(db_name, entry).first || (yml.adapter("primary", yml.primary(root)).first unless entry)
      end

      DEFAULT_SEARCH_PATH = %w[public].freeze

      # A dump of more than one schema qualifies every name (relation_name, 8.1); the app
      # sees a relation in a search path schema by its bare name (current_schemas(false)),
      # unless `shadowed` says an earlier schema on the path holds the same name.
      def local_name(name, search_path = DEFAULT_SEARCH_PATH, shadowed = nil)
        schema, dot, bare = name.rpartition(".")
        dot.empty? || !search_path.include?(schema) || shadowed&.include?(name) ? name : bare
      end

      # The qualified names a schema earlier on the search path hides by holding the same name.
      def shadowed_names(names, search_path)
        ranked = names.uniq.filter_map do |name|
          schema, _, bare = name.rpartition(".")
          rank = search_path.index(schema)
          [ rank, bare, name ] if rank
        end
        first = ranked.sort_by(&:first).reverse.to_h { |_, bare, name| [ bare, name ] }
        ranked.filter_map { |_, bare, name| name unless first[bare] == name }.to_set
      end

      # An enum list as the connection's enum_types gives it, sorted: the types on the search path,
      # bare in the current schema; before 7.1 every type, by its bare name.
      def enum_list(enums, search_path, legacy: false)
        listed = enums.filter_map do |name, values|
          schema, dot, bare = name.rpartition(".")
          shown = if dot.empty? || legacy then bare
          elsif search_path.include?(schema) then schema == search_path.first ? bare : name
          end
          { name: shown, values: values } if shown
        end
        listed.uniq { |enum| enum[:name] }.sort_by { |enum| enum[:name] }
      end

      # The enum types a table's columns use, from the list: a column's bare type resolves to the
      # first schema on the search path holding it, and a bare list name is in the current schema.
      def enums_used(enum_types, column_types, search_path)
        path = Array(search_path).presence || DEFAULT_SEARCH_PATH
        listed = Array(enum_types).to_h { |enum| [ enum[:name].to_s.include?(".") ? enum[:name].to_s : "#{path.first}.#{enum[:name]}", enum ] }
        used = column_types.map do |type|
          type.include?(".") ? type : path.map { |schema| "#{schema}.#{type}" }.find { |key| listed.key?(key) }
        end
        listed.select { |key, _| used.include?(key) }.values
      end

      # The configured search path less the schemas the dump never creates, as PostgreSQL
      # skips a schema that does not exist. public is assumed, since pg_dump does not create it.
      def existing_search_path(search_path, created)
        search_path.select { |schema| schema == "public" || created.include?(schema) }
      end

      # A primary key as connection.primary_key gives it: the column's name, or
      # the names in order for a composite key; nil for none.
      def primary_key_value(key)
        names = Array(key).map(&:to_s).reject(&:empty?)
        names.size > 1 ? names : names.first
      end

      # The key on the table and a flag on each of its columns, from whichever
      # side the source gave; a table with no key keeps neither.
      def mark_primary_key(table)
        table[:primary_key] ||= primary_key_value(Array(table[:columns]).select { |c| c[:primary_key] }.map { |c| c[:name] })
        keys = Array(table[:primary_key]).map(&:to_s)
        Array(table[:columns]).each { |column| column[:primary_key] = true if keys.include?(column[:name].to_s) }
        table.delete(:primary_key) if table[:primary_key].nil?
        table
      end

      # Every table's check constraints in one list, each naming its table.
      def check_constraints_of(tables)
        tables.flat_map { |name, table| Array(table[:check_constraints]).map { |constraint| { table: name, **constraint } } }
      end

      def generated_columns_of(tables)
        tables.flat_map do |name, table|
          Array(table[:columns]).filter_map do |column|
            { table: name, column: column[:name], expression: column[:generated], stored: column[:stored] }.compact if column.key?(:generated)
          end
        end
      end

      # Views, virtual tables and skipped tables beside the tables. A view replaces a table
      # of its name: mysqldump writes a placeholder table before the view.
      def add_relations(tables, views: {}, virtual_tables: {}, not_dumped: {})
        views.each { |name, view| tables[name] = view_entry(view[:sql], materialized: view[:materialized], indexes: view[:indexes]) }
        virtual_tables.each { |name, table| tables[name] = virtual_table_entry(table[:module], table[:arguments]) }
        not_dumped.each { |name, reason| tables[name] ||= { columns: [], indexes: [], foreign_keys: [], not_dumped: reason } }
        tables
      end

      def view?(table)
        table.is_a?(Hash) && %w[view materialized_view].include?(table[:kind])
      end

      # Views sit beside the tables in one Hash, and a table count leaves them out.
      def table_count(tables)
        tables.count { |_, table| !view?(table) }
      end

      # How a header counts the listed entries: "116 tables and 2 views".
      def relations_phrase(tables)
        tables ||= {}
        count = table_count(tables)
        phrase = CountPhrase.call(count, "table")
        views = tables.size - count
        views.positive? ? "#{phrase} and #{CountPhrase.call(views, "view")}" : phrase
      end

      # A dump holds a view's SQL, not its columns; only a connection lists those.
      def view_entry(sql, materialized:, columns: [], indexes: [])
        { kind: materialized ? "materialized_view" : "view", columns: columns, indexes: Array(indexes), foreign_keys: [], sql: sql }.compact
      end

      # A virtual table's columns are its module arguments that set no option (fts5's tokenize=...).
      def virtual_table_entry(mod, arguments)
        columns = Array(arguments).filter_map { |arg| arg.strip[/\A["`]?(\w+)["`]?(?:\s+UNINDEXED)?\z/i, 1] }
        { kind: "virtual_table", module: mod, columns: columns.map { |name| { name: name } }, indexes: [], foreign_keys: [] }.compact
      end

      # MySQL's dumper writes a tiny, medium or long text or blob type as size:.
      def mysql_text_size(sql_type)
        sql_type.to_s[/\A(tiny|medium|long)(?:text|blob)/i, 1]&.downcase
      end

      # How a primary key reads to a person: `id`, or `tag_id, account_id`.
      def primary_key_label(key)
        Array(key || "id").join(", ")
      end

      def format_default(value)
        value&.to_s
      end
    end
  end
end
