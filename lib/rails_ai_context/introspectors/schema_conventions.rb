# frozen_string_literal: true

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
          column: column&.to_s || "#{to.to_s.singularize}_id",
          primary_key: primary_key&.to_s || "id"
        }
      end

      # A reference declares the foreign key column, not a column of its own name.
      def reference_column_name(name)
        "#{name}_id"
      end

      def timestamps_columns
        [
          { name: "created_at", type: "datetime", null: false },
          { name: "updated_at", type: "datetime", null: false }
        ]
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

      def format_default(value)
        case value
        when NilClass then nil
        else value.to_s
        end
      end
    end
  end
end
