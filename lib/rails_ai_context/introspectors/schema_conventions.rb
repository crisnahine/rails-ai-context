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

        id_type = options[:id].is_a?(String) || options[:id].is_a?(Symbol) ? options[:id].to_s : pk_type
        [ { name: pk_opt ? pk_opt.to_s : "id", type: id_type, default: nil,
            options: { null: false }, primary_key: true } ]
      end

      # Rails omits column:/primary_key: only where the convention holds, so
      # the fallback is what was declared rather than a guess.
      def foreign_key_entry(from, to, column, primary_key)
        {
          from_table: from, to_table: to,
          column: primary_key_value(column) || "#{to.to_s.singularize}_id",
          primary_key: primary_key_value(primary_key) || "id"
        }
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
      # primary, sqlite queue) and each dump must be typed by its own.
      def implicit_pk_type(root, dump_path)
        db_name = File.basename(dump_path.to_s).sub(/\.(rb|sql)\z/, "").sub(/_?(schema|structure)\z/, "")
        db_name = "primary" if db_name.empty?

        adapter = database_adapter_for(root, db_name)
        adapter&.start_with?("sqlite") ? "integer" : "bigint"
      end

      # Best-effort adapter lookup from config/database.yml without booting:
      # a keyed entry for this database name wins; a file with exactly one
      # distinct adapter is unambiguous; anything else falls back to the
      # first adapter (the primary comes first in generated configs).
      def database_adapter_for(root, db_name)
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

      # A primary key as connection.primary_key gives it: the column's name, or
      # the names in order for a composite key; nil for none.
      def primary_key_value(key)
        names = Array(key).map(&:to_s).reject(&:empty?)
        names.size > 1 ? names : names.first
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
