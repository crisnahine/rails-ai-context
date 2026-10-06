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

      # Rails omits column:/primary_key: only where the convention holds, so
      # the fallback is what was declared rather than a guess. PostgreSQL's
      # convention drops the schema of a qualified target. validate: true and
      # deferrable: false are the defaults the dump leaves out; Rails 7.0 reads
      # DEFERRABLE INITIALLY IMMEDIATE back as true, which 7.1 names :immediate.
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
      # names a secondary database's dump; nil is the primary's.
      def implicit_pk_type(root, dump_path = nil)
        db_name = SchemaDumpPath.database_name(root, dump_path)
        adapter = database_adapter_for(root, db_name)
        adapter&.start_with?("sqlite") ? "integer" : "bigint"
      end

      # Best-effort adapter lookup without booting: a URL Rails would merge in
      # wins, as DatabaseYml.url_adapter rules; then in database.yml a keyed entry for this database name wins; a file with exactly one
      # distinct adapter is unambiguous; anything else falls back to the
      # first adapter (the primary comes first in generated configs).
      def database_adapter_for(root, db_name)
        entry = RailsAiContext::DatabaseYml.entry(root, db_name)
        url_adapter = RailsAiContext::DatabaseYml.url_adapter(db_name, entry.is_a?(Hash) ? entry["url"] : nil)
        return url_adapter if url_adapter

        content = database_yml_content(root)
        return nil if content.empty?

        adapters = content.scan(/^\s*adapter:\s*(\w+)/).flatten
        return adapters.first if adapters.uniq.size <= 1

        # Mixed adapters: find the block keyed by this database's name and
        # take the first adapter that follows at deeper indentation. The
        # block ends at the first non-blank line at the key's indent or
        # shallower; blank/whitespace-only lines don't end it (and must not
        # let it bleed into a sibling block).
        if (m = content.match(/^([ \t]*)#{Regexp.escape(db_name)}:[ \t]*\n((?:(?:[ \t]*|\1[ \t]+\S[^\n]*)\n)*)/))
          block_adapter = m[2][/^[ \t]*adapter:[ \t]*(\w+)/, 1]
          return block_adapter if block_adapter
        end
        adapters.first
      end

      # Normalized so the line-anchored block regex above works on files with
      # Windows endings or no final newline.
      def database_yml_content(root)
        db_yml = File.join(root.to_s, "config", "database.yml")
        content = RailsAiContext::SafeFile.read(db_yml).to_s.gsub("\r\n", "\n")
        content.empty? || content.end_with?("\n") ? content : "#{content}\n"
      end

      # A dump of more than one schema qualifies every name (relation_name, 8.1);
      # the app sees a public table by its bare name under the default search_path.
      def local_name(name)
        name.delete_prefix("public.")
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

      # Views, virtual tables and tables the dumper skipped, listed beside the tables
      # under the names Rails gives them. A view replaces a table of its name: mysqldump
      # writes a placeholder table before the view it stands in for.
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
