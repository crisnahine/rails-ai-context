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

      # The default create_table gives its implicit key: `id: { default: }` wins over `default:`, and
      # an expression counts only as a proc's text, the one form a dump writes.
      def key_default(options, event)
        id = options[:id]
        value = id.is_a?(Hash) && id.key?(:default) ? id[:default] : options[:default]
        return event[:default_source] if value == RailsAiContext::Confidence::INFERRED && event[:default_proc]

        format_default(value) unless value == RailsAiContext::Confidence::INFERRED
      end

      # create_table implies an id primary key unless disabled; the runtime
      # tier reports it, so every static source must too. Composite primary
      # keys (primary_key: [...]) dump their columns as explicit t.* lines -
      # synthesizing an id there would invent a column that does not exist.
      def implicit_primary_key(options, pk_type, default: nil)
        pk_opt = options[:primary_key]
        composite_pk = !pk_opt.nil? && !pk_opt.is_a?(String) && !pk_opt.is_a?(Symbol)
        return [] if options[:id] == false || composite_pk

        # set_primary_key (7.0 to 8.1): an id: hash gives the type, its other keys the column's options.
        id = options[:id]
        id_options = id.is_a?(Hash) ? id.except(:type).reject { |_, value| value == RailsAiContext::Confidence::INFERRED } : {}
        id = id[:type] if id.is_a?(Hash)
        id_type = (id.is_a?(String) || id.is_a?(Symbol)) && id.to_s != "primary_key" ? id.to_s : pk_type
        [ { name: pk_opt ? pk_opt.to_s : "id", type: id_type, default: default,
            options: { null: false }.merge(id_options), primary_key: true } ]
      end

      # The dump leaves out column:, primary_key:, validate: true and deferrable: false where they are Rails'
      # defaults; Rails 7.0 reads DEFERRABLE INITIALLY IMMEDIATE back as true, which 7.1 names :immediate.
      # A name is kept only where the dumper writes it: not one that matches SchemaDumper.fk_ignore_pattern (ignore:), as the
      # ones Rails makes up and the ones an old hash left do. A hidden name that is not the one Rails would make for the
      # columns stays as actual_name, for SQL that names the constraint.
      def foreign_key_entry(from, to, column, primary_key, on_delete: nil, on_update: nil, deferrable: nil, validate: nil, name: nil, ignore: FOREIGN_KEY_IGNORE)
        known = ->(value) { value unless value == RailsAiContext::Confidence::INFERRED }
        column = primary_key_value(column) || "#{to.to_s.split('.').last.to_s.singularize}_id"
        name = known.(name)&.to_s
        hidden = name if !name.nil? && !name.empty? && ignore.match?(name) && name != foreign_key_name(from, column)
        {
          from_table: from, to_table: to, column: column,
          primary_key: primary_key_value(primary_key) || "id",
          on_delete: known.(on_delete)&.to_s, on_update: known.(on_update)&.to_s,
          deferrable: (deferrable == true ? "immediate" : known.(deferrable)&.to_s if deferrable), validate: (false if validate == false),
          name: (name unless name.nil? || name.empty? || ignore.match?(name)), actual_name: hidden
        }.compact
      end

      # A table or column name as a Ruby symbol literal, quoted where the name is not a plain identifier.
      def source_symbol(name)
        name.to_s.to_sym.inspect
      end

      # The name the database holds for a key: the dump-facing name, else the hidden one, else the one Rails makes.
      def real_foreign_key_name(table, fk)
        (fk[:name] || fk[:actual_name] || foreign_key_name(table, fk[:column])).to_s
      end

      FOREIGN_KEY_OPTIONS = %i[on_delete on_update deferrable validate name].freeze

      # SchemaDumper.fk_ignore_pattern's default (7.0 to 8.1).
      FOREIGN_KEY_IGNORE = /\Afk_rails_[0-9a-f]{10}\z/

      # What an answer says where the replay took MySQL's key order for a MySQL-family server it could not name.
      def mysql_order_assumed_phrase(count)
        "#{RailsAiContext::CountPhrase.call(count, "table")} whose remove_foreign_key with no column took the key MySQL " \
          "lists first (assuming MySQL; MariaDB lists another first)"
      end

      # Rails' name for an unnamed foreign key (foreign_key_name, 7.1 to 8.1; 7.0 has one column only, which hashes the same).
      def foreign_key_name(table, columns)
        "fk_rails_#{Digest::SHA256.hexdigest("#{table}_#{Array(columns).map(&:to_s).join("_and_")}_fk")[0, 10]}"
      end

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

      # An exclusion constraint as schema.rb writes it (exclusion_constraints_in_create, 7.1 to 8.1): its elements, the
      # index method, the predicate and how it defers; deferrable: false is the default the dump leaves out.
      def exclusion_constraint_entry(name, expression, using: nil, where: nil, deferrable: nil)
        known = ->(value) { value.to_s unless value.nil? || value == false || value == RailsAiContext::Confidence::INFERRED }
        { name: known.(name), expression: expression, using: known.(using), where: known.(where), deferrable: known.(deferrable) }.compact
      end

      # deferrable: false is the default the dump leaves out.
      def unique_constraint_entry(name, columns, deferrable, nulls_not_distinct = nil)
        {
          name: name&.to_s,
          columns: Array(columns).map(&:to_s),
          deferrable: (deferrable.to_s if deferrable),
          nulls_not_distinct: (true if nulls_not_distinct == true)
        }.compact
      end

      # Rails' own bookkeeping tables. ar_internal_metadata.key ends in "key": counted as a secret,
      # it would refuse every statement whose text holds the word "key".
      BOOKKEEPING_TABLES = %w[ar_internal_metadata schema_migrations].freeze

      # Whether SchemaDumper#ignored? skips the table: a bookkeeping name, bare or with the booted
      # app's table_name_prefix and suffix. Any other name, schema_migrations_archive too, is dumped.
      def bookkeeping_table?(name)
        return BOOKKEEPING_TABLES.include?(name) if RailsAiContext.static_tier? || !defined?(ActiveRecord::Base)

        base = ActiveRecord::Base
        [ base.schema_migrations_table_name, base.internal_metadata_table_name ].any? do |bare|
          name == bare || name == "#{base.table_name_prefix}#{bare}#{base.table_name_suffix}"
        end
      end

      # Rails' name for an unnamed check constraint (check_constraint_name, 7.0 to 8.1).
      def check_constraint_name(table, expression)
        "chk_rails_#{Digest::SHA256.hexdigest("#{table}_#{expression}_chk")[0, 10]}"
      end

      # Rails' name for an unnamed unique constraint (unique_constraint_name, 7.1 to 8.1).
      def unique_constraint_name(table, columns)
        "uniq_rails_#{Digest::SHA256.hexdigest("#{table}_#{Array(columns).join("_and_")}_unique")[0, 10]}"
      end

      # Rails' limit before it shortens an index name (max_index_name_size).
      MAX_INDEX_NAME_SIZE = 62

      # Rails' name for an unnamed index (index_name, 7.0 to 8.1), shortened past 62 bytes from 7.1.
      # legacy: 7.0's rule, which never shortens (Rails 7.0, or Compatibility::V7_0 on a later one).
      def default_index_name(table, columns, legacy: false)
        # A String key with a non-word character is an expression, named by its
        # words (index_name_options, 7.0 and 8.1); an Array is joined as written.
        columns = columns.scan(/\w+/).join("_") if columns.is_a?(String) && columns.match?(/\W/)
        cols = Array(columns).map(&:to_s)
        name = "index_#{table}_on_#{cols.join('_and_')}"
        return name if legacy || name.bytesize <= MAX_INDEX_NAME_SIZE

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

      # An index a migration declares; a Symbol where: is SQL naming a column (add_index_options, 7.0 to 8.1).
      def index_entry(name, columns, options)
        where = options[:where]
        where = where.to_s if where.is_a?(Symbol)
        detail = options.slice(:using, :type, :include, :order, :opclass, :length, :nulls_not_distinct)
                        .reject { |_, value| value == RailsAiContext::Confidence::INFERRED }
        { name: name, columns: columns, unique: options[:unique] == true, where: (where if where.is_a?(String)) }.compact
          .merge(index_detail(columns, **detail))
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
      def reference_definition(table, name, options, pk_type, version: nil, legacy: false)
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
                     (polymorphic_name ? "index_#{table}_on_#{name}" : default_index_name(table, names, legacy: legacy))
        { columns: columns, index: index_entry(index_name, names, index_opts) }
      end

      # A reference declares the foreign key column, not a column of its own name.
      def reference_column_name(name)
        "#{name}_id"
      end

      # [major, minor] of a `Migration[7.1]` or `Schema[7.1]` version, the shape the version: options here take.
      def version_parts(text)
        text.to_s.split(".").map(&:to_i) if text
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

      # Compatibility::V6_1 and older give a datetime written without a precision: nil (7.0 made it 6), and V5_2 and
      # older do the same to timestamps (6.0 made them 6); a precision the call gives stays.
      def compat_precision(options, type, version, timestamps: false)
        return options if options.key?(:precision) || version.nil? || type.to_s != "datetime"

        (version <=> (timestamps ? [ 5, 2 ] : [ 6, 1 ])).positive? ? options : options.merge(precision: nil)
      end

      # The implicit primary key's type is adapter-specific: bigint everywhere
      # since Rails 5.1, except SQLite where it stays integer. The dump does
      # not record it, but config/database.yml names the adapter - looked up
      # per database, because a multi-db app can mix adapters (postgres
      # primary, sqlite queue) and each dump must be typed by its own. dump_path
      # names a secondary database's dump, nil the primary's; database: names the database outright.
      def implicit_pk_type(root, dump_path = nil, database: SchemaDumpPath.database_name(root, dump_path))
        RailsAiContext::DatabaseFamily.of(database_adapter_for(root, database)).implicit_pk_type
      end

      # One app database's adapter, the primary's for no name. A database only another environment configures (Rails 8's queue
      # outside production) takes that environment's; one only a dump names, the primary's.
      def database_adapter_for(root, db_name)
        databases = RailsAiContext::AppDatabases.for(root)
        found = databases.of_dump_name(db_name)
        found&.config ? found.adapter : databases.primary&.adapter
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

      # A virtual table argument that is a column: a bare or quoted name (double quotes, backticks, single quotes or
      # brackets, a quote doubled inside), then fts5's UNINDEXED.
      VIRTUAL_COLUMN = /\A(?:"((?:[^"]|"")+)"|`((?:[^`]|``)+)`|'((?:[^']|'')+)'|\[([^\]]+)\]|(\w+))(?:\s+UNINDEXED)?\z/i

      # A virtual table's columns are its module arguments that set no option (fts5's tokenize=...).
      def virtual_table_entry(mod, arguments)
        columns = Array(arguments).filter_map do |arg|
          double, back, single, bracket, plain = arg.strip.match(VIRTUAL_COLUMN)&.captures
          double&.gsub('""', '"') || back&.gsub("``", "`") || single&.gsub("''", "'") || bracket || plain
        end
        { kind: "virtual_table", module: mod, columns: columns.map { |name| { name: name } }, indexes: [], foreign_keys: [] }.compact
      end

      # MySQL makes a column a statement declares serial unique, apart from the table's whole key (serial_index).
      def serial_index?(family, type, column, key)
        family == :mysql && type.to_s.casecmp?("serial") && column[:primary_key] != true && Array(key) != [ column[:name] ]
      end

      # The unique index MySQL adds for a serial column or an unnamed UNIQUE: named after its first column, or <column>_2 on when that name is taken.
      # shortcut: none is listed for a serial that is the whole key, where MySQL adds one and MariaDB none; tell the servers apart if a tool needs it.
      def serial_index(indexes, columns)
        column = Array(columns).first.to_s
        column = "functional_index" if column.start_with?("(")
        name = column
        suffix = 1
        name = "#{column}_#{suffix += 1}" while indexes.any? { |index| index[:name] == name }
        index_entry(name, Array(columns), unique: true)
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
