# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetSchema < BaseTool
      tool_name "rails_get_schema"
      description "Get database schema: tables, columns, types, indexes, foreign keys. " \
        "Use when: writing migrations, checking column types/constraints, understanding table relationships. " \
        "Filter to one table with table:\"users\", control detail with detail:\"summary\"|\"standard\"|\"full\"."

      input_schema(
        properties: {
          table: {
            type: "string",
            description: "Specific table name for full detail. Omit for overview."
          },
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: table names + column counts. standard: table names + column names/types (default). full: everything including indexes, FKs, comments."),
          limit: {
            type: "integer",
            description: "Max tables to return when listing. Default: 50 for summary, 25 for standard, 10 for full."
          },
          offset: {
            type: "integer",
            description: "Skip this many tables for pagination. Default: 0."
          },
          format: {
            type: "string",
            enum: %w[json markdown],
            description: "Output format. Default: markdown."
          }
        }
      )

      guide_row(
        order: 6,
        mcp: "rails_get_schema(table:\"X\")",
        cli_args: "table=X",
        summary: "Columns with [indexed]/[unique]/[encrypted]/[default] hints"
      )

      annotations(
        read_only_hint: true,
        destructive_hint: false,
        idempotent_hint: true,
        open_world_hint: false
      )

      def self.call(table: nil, detail: "standard", limit: nil, offset: 0, format: "markdown", server_context: nil)
        fetch_section(:schema, subject: "Schema introspection") do |schema|
          tables = schema[:tables] || {}

          # Every read of the shared cache deep-copies the whole payload, so
          # the listing reads it once and hands the copy down.
          ctx = cached_context
          models_data = Payload.models(ctx)

          total = tables.size
          offset = [ offset.to_i, 0 ].max
          limit = [ limit.to_i, 0 ].max if limit && limit.to_i < 0

          # Single table - case-insensitive lookup with model name normalization
          # Accepts: "users", "Users", "User" (model name → pluralized+underscored table)
          if table
            table_down = table.downcase
            # "Post" and "Admin::ActionLog" are model names here, and the model
            # tier knows the table each of them reads.
            table_as_table = RailsAiContext::Introspectors::TableName.for_model_name(table, models_data)
            table_key = tables.keys.find { |k|
              k.downcase == table_down || k == table_as_table || k == table.underscore
            } || table
            table_data = tables[table_key]
            unless table_data
              # A table db/schema.rb declares and the connection does not have
              # is not a misspelling: the migration that adds it has not run
              # here, and "Did you mean 'comments'?" sends the reader to fix
              # the wrong thing.
              # The key is the caller's own string when nothing matched, and
              # the declared names are table names: `OrderComments` and
              # `order_comments` are the same request.
              declared = table_key.to_s.underscore
              if declared_not_connected(schema).include?(declared)
                return text_response(
                  "Table '#{declared}' is declared in db/schema.rb and missing from the connected database. " \
                  "#{pending_for_table(schema, declared)}" \
                  "Run `rails db:migrate`, or pass `--no-boot` to read the declaration instead."
                )
              end

              return not_found_response("Table", table, tables.keys.sort,
                recovery_tool: "Call rails_get_schema(detail:\"summary\") to see all tables")
            end
            return json_response(table_data.except(:unread_calls)) if format == "json"

            output = format_table_markdown(table_key, table_data, models_data)
            # Cross-reference hint for AI: suggest next tool call
            model_refs = models_for_table(table_key, models_data)
            if model_refs.any?
              output += "\n\n_Next: `rails_get_model_details(model:\"#{model_refs.first}\")` for associations, validations, scopes._"
            end
            return text_response(output)
          end

          case detail
          when "summary"
            page = paginate(tables.keys.sort, offset: offset, limit: limit, default_limit: 50)
            paginated = page[:items]
            return json_page_response(schema, tables, paginated, models_data) if format == "json"

            if paginated.empty? && total > 0
              return text_response("No tables at offset #{page[:offset]}. Total: #{total}. Use `offset:0` to start over.")
            end

            lines = [ "# Schema Summary (#{count_phrase(total, "table")})", "" ]
            lines << "**Adapter:** #{adapter_label(ctx)}" if schema[:adapter]
            lines.concat(static_source_lines(schema))
            paginated.each do |name|
              data = tables[name]
              col_count = data[:columns]&.size || 0
              idx_count = data[:indexes]&.size || 0
              lines << "- **#{name}** - #{count_phrase(col_count, "column")}, #{count_phrase(idx_count, "index", plural: "indexes")}"
            end
            coverage = model_coverage_lines(tables, models_data)
            lines.concat([ "" ] + coverage) if coverage.any?
            lines.concat(secondary_databases_lines(schema))
            if page[:offset] + page[:limit] < total
              lines << "" << "_Showing #{paginated.size} of #{total}. Use `offset:#{page[:offset] + page[:limit]}` for more, or `table:\"name\"` for full detail._"
              lines << "_cache_key: #{cache_key}_"
            end
            text_response(lines.join("\n"))

          when "standard"
            # Sort by column count (most complex first) - AI agents care about big tables first
            sorted = tables.keys.sort_by { |name| -(tables[name][:columns]&.size || 0) }
            page = paginate(sorted, offset: offset, limit: limit, default_limit: 25)
            paginated = page[:items]
            return json_page_response(schema, tables, paginated, models_data) if format == "json"

            if paginated.empty?
              return text_response("No tables at offset #{page[:offset]}. Total tables: #{total}. Use `offset:0` to start from the beginning.")
            end

            lines = [ "# Schema (#{count_phrase(total, "table")}, showing #{paginated.size})", "" ]
            lines.concat(static_source_lines(schema))
            paginated.each do |name|
              data = tables[name]
              timestamp_cols = %w[id created_at updated_at]

              # A unique index on several columns constrains the set, so each names its partners.
              # [indexed] means the column leads an index; a trailing one names what it sits behind.
              indexed_cols = RailsAiContext::Introspectors::SchemaConventions.lookup_indexed_columns(data)
              # A partial unique index constrains only the rows its WHERE
              # picks; each column keeps every condition, and nil for none wins.
              unique_cols = {}
              unique_with = Hash.new { |hash, key| hash[key] = [] }
              trailing = Hash.new { |hash, key| hash[key] = [] }
              column_names = (data[:columns] || []).to_set { |col| col[:name].to_s }
              shown = ->(key) { column_names.include?(key) ? key : "`#{key}`" }
              (data[:indexes] || []).each do |idx|
                idx_cols = Array(idx[:columns]).map(&:to_s)
                # An expression key hints no column of its own, but it is a
                # partner, named as the expression.
                columns_in = idx_cols.select { |col| column_names.include?(col) }
                if idx[:unique] && idx_cols.size == 1
                  columns_in.each do |col|
                    (unique_cols[col] ||= []) << idx[:where]
                  end
                elsif idx[:unique]
                  columns_in.each { |col| unique_with[col] << [ (idx_cols - [ col ]).map(&shown), idx[:where] ] }
                else
                  idx_cols.each_with_index do |col, i|
                    trailing[col] << idx_cols.first(i).map(&shown) if i.positive? && column_names.include?(col)
                  end
                end
              end

              # Detect encrypted columns from model data
              encrypted_cols = Set.new
              model_refs = models_for_table(name, models_data)
              model_refs.each do |model_name|
                (models_data.dig(model_name, :encrypts) || []).each { |f| encrypted_cols.add(f) }
              end

              cols = (data[:columns] || [])
                .reject { |c| timestamp_cols.include?(c[:name]) }
                .map do |c|
                  hints = []
                  wheres = unique_cols[c[:name]]
                  wheres = [ nil ] if wheres&.include?(nil)
                  wheres&.uniq&.each { |where| hints << "unique#{RailsAiContext::Introspectors::SchemaConventions.where_clause(where)}" }
                  hints << "indexed" if indexed_cols.include?(c[:name]) && !unique_cols.key?(c[:name])
                  partners = unique_cols.key?(c[:name]) ? [] : unique_with.fetch(c[:name], []).uniq { |others, where| [ others.sort, where ] }
                  partners.each { |others, where| hints << "unique with #{others.join(', ')}#{RailsAiContext::Introspectors::SchemaConventions.where_clause(where)}" }
                  # Only for a column no other hint places in an index.
                  unless indexed_cols.include?(c[:name]) || unique_cols.key?(c[:name]) || partners.any?
                    trailing.fetch(c[:name], []).uniq.each { |before| hints << "in index after #{before.join(', ')}" }
                  end
                  hints << "encrypted" if encrypted_cols.include?(c[:name])
                  # Show default value if present
                  if c.key?(:default) && !c[:default].nil? && c[:default] != ""
                    hints << "default: #{c[:default]}"
                  end
                  # A clause can hold a column list, so clauses part with a semicolon.
                  hint_str = hints.any? ? " [#{hints.join('; ')}]" : ""
                  "#{c[:name]}:#{c[:type]}#{hint_str}"
                end.join(", ")
              # Inline model info so AI doesn't need a separate get_model_details call
              # Every model on the table, richest first: an STI child or a
              # namespaced second model shares the table, and stopping at the
              # first in payload order can name the emptier one.
              usable = model_refs.filter_map do |mname|
                md = models_data[mname]
                next unless md.is_a?(Hash) && !md[:error]

                [ mname, md[:associations]&.size || 0, md[:validations]&.size || 0 ]
              end
              usable = usable.sort_by.with_index { |(_, a, v), i| [ -(a + v), i ] }
              model_info = if usable.any?
                shown = usable.first(5).map { |mname, a, v| "**#{mname}** (#{a} assoc, #{v} val)" }.join(", ")
                more = usable.size > 5 ? " (+#{usable.size - 5} more)" : ""
                " → #{shown}#{more}"
              else
                ""
              end
              key = data[:primary_key] && data[:primary_key] != "id" ? " (primary key: #{RailsAiContext::Introspectors::SchemaConventions.primary_key_label(data[:primary_key])})" : ""
              lines << "### #{name}#{key}#{model_info}"
              lines << cols
              lines << ""
            end

            coverage = model_coverage_lines(tables, models_data)
            lines.concat(coverage + [ "" ]) if coverage.any?
            lines.concat(secondary_databases_lines(schema))
            lines << "_Use `detail:\"summary\"` for all #{count_phrase(total, "table")}, `detail:\"full\"` for indexes/FKs, or `table:\"name\"` for one table._" if total > page[:limit]
            text_response(lines.join("\n"))

          when "full"
            page = paginate(tables.keys.sort, offset: offset, limit: limit, default_limit: 10)
            paginated = page[:items]
            return json_page_response(schema, tables, paginated, models_data) if format == "json"

            if paginated.empty? && total > 0
              return text_response("No tables at offset #{page[:offset]}. Total: #{total}. Use `offset:0` to start over.")
            end

            lines = [ "# Schema Full Detail (#{paginated.size} of #{count_phrase(total, "table")})", "" ]
            lines.concat(note_lines(schema))
            paginated.each do |name|
              lines << format_table_markdown(name, tables[name], models_data)
              lines << ""
            end
            coverage = model_coverage_lines(tables, models_data)
            lines.concat(coverage + [ "" ]) if coverage.any?
            lines.concat(secondary_databases_lines(schema))
            if page[:offset] + page[:limit] < total
              lines << "_Showing #{paginated.size} of #{total}. Use `offset:#{page[:offset] + page[:limit]}` for more._"
              lines << "_cache_key: #{cache_key}_"
            end
            text_response(lines.join("\n"))
          end
        end
      end

      # The same seam the generated context files use. Answering this question
      # locally is how one app came to be told it runs on PostgreSQL by
      # CLAUDE.md and on "unknown" by this tool, in the same session.
      private_class_method def self.adapter_label(ctx)
        RailsAiContext::SchemaAdapter.label_with_reason(ctx)
      end

      # Rails builds no model for a has_and_belongs_to_many join table, so one
      # is not a table whose model is missing. The name is the two tables
      # sorted, unless the association writes :join_table itself.
      private_class_method def self.habtm_join_tables(models)
        models.each_with_object(Set.new) do |(name, data), found|
          next unless data.is_a?(Hash)

          Array(data[:associations]).each do |assoc|
            next unless assoc[:type].to_s == "has_and_belongs_to_many"

            options = assoc[:options].is_a?(Hash) ? assoc[:options] : {}
            if (declared = assoc[:join_table] || options[:join_table])
              found << declared.to_s
              next
            end
            next unless data[:table_name]

            written = assoc[:class_name] || options[:class_name] || assoc[:name].to_s.camelize.singularize
            other = RailsAiContext::Introspectors::TableName.resolve_class(written, name) { |candidate| candidate if models.key?(candidate) }
            found << RailsAiContext::Introspectors::HabtmJoinTables.join_table_name(
              data[:table_name], RailsAiContext::Introspectors::TableName.for_model_name(other, models)
            )
          end
        end
      rescue => e
        RailsAiContext.debug_fail(e, Set.new, label: "habtm_join_tables")
      end

      # Tables a gem creates and declares its model for, by the names its install migration uses.
      GEM_TABLES = {
        "good_job" => /\Agood_job/, "doorkeeper" => /\Aoauth_(?:applications|access_grants|access_tokens|openid_requests)\z/,
        "solid_queue" => /\Asolid_queue_/, "solid_cache" => /\Asolid_cache_/, "solid_cable" => /\Asolid_cable_/,
        "activestorage" => /\Aactive_storage_/, "actiontext" => /\Aaction_text_/, "actionmailbox" => /\Aaction_mailbox_/,
        "noticed" => /\Anoticed_/, "delayed_job_active_record" => /\Adelayed_jobs\z/,
        "friendly_id" => /\Afriendly_id_slugs\z/, "closure_tree" => /_hierarchies\z/,
        "paper_trail" => /\Aversions\z/, "acts-as-taggable-on" => /\A(?:tags|taggings)\z/, "pghero" => /\Apghero_/
      }.freeze

      # {gem => its tables}, for each gem the app's lockfile or Gemfile has.
      private_class_method def self.gem_owned(tables)
        lock = RailsAiContext::GemLock.for(rails_app.root)
        GEM_TABLES.each_with_object({}) do |(gem, pattern), found|
          owned = tables.grep(pattern)
          found[gem] = owned if owned.any? && lock.present?(gem)
        end
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "gem_owned")
      end

      # The same, for a habtm declared outside the model files: a lib patch, an engine.
      private_class_method def self.declared_join_tables(models)
        RailsAiContext::Introspectors::HabtmJoinTables.declared(rails_app.root, models)
      rescue => e
        RailsAiContext.debug_fail(e, Set.new, label: "declared_join_tables")
      end

      private_class_method def self.models_for_table(table_name, models)
        models.select { |_, d| d.is_a?(Hash) && d[:table_name] == table_name }.keys
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "models_for_table")
      end

      # The pending migrations named after the table, or all of them when none
      # is: a migration that adds a table is not always named for it.
      private_class_method def self.pending_for_table(schema, table)
        pending = Array(schema[:pending_migrations])
        return "" if pending.empty?

        named = pending.select { |m| m[:name].to_s.underscore.include?(table) }
        named = pending if named.empty?
        shown = named.first(5).map { |m| "#{m[:version]} #{m[:name]}".strip }.join(", ")
        more = named.size > 5 ? " (+#{named.size - 5} more)" : ""
        "Pending: #{shown}#{more}. "
      end

      # The tables db/schema.rb declares that the connected database does not
      # have. Empty unless both sides are known, which is the booted tier
      # with a schema file to read.
      private_class_method def self.declared_not_connected(schema)
        declared = schema[:declared_tables]
        return [] unless declared.is_a?(Array)

        declared.map(&:to_s) - (schema[:tables] || {}).keys.map(&:to_s)
      end

      # Static-parse extras: the SQL dialect the dump was written in, the
      # schema version recorded by the dump, and migration files it doesn't
      # cover - the static-tier stand-ins for a live connection's answers.
      private_class_method def self.note_lines(schema)
        lines = schema[:note].to_s.empty? ? [] : [ "_#{schema[:note]}_" ]
        lines << "**Extensions:** #{schema[:extensions].join(', ')}" if schema[:extensions]&.any?
        lines
      end

      private_class_method def self.static_source_lines(schema)
        lines = note_lines(schema)
        lines << "**Dialect:** #{schema[:dialect]} (db/structure.sql)" if schema[:dialect] && schema[:dialect] != "unknown"
        lines << "**Schema version:** #{schema[:schema_version]}" if schema[:schema_version]
        # The header pairs a live table count with the version stamp read off
        # db/schema.rb, and nothing joined the two: at that migration the app
        # has the table the database is missing.
        missing = declared_not_connected(schema)
        if missing.any?
          declared_total = Array(schema[:declared_tables]).size
          lines << "_db/schema.rb declares #{count_phrase(declared_total, "table")}; the connected database has " \
                   "#{(schema[:tables] || {}).size}. Missing: #{missing.sort.first(5).join(', ')}" \
                   "#{missing.size > 5 ? " (+#{missing.size - 5} more)" : ""}. Run `rails db:migrate`._"
        end
        if schema[:pending_migrations].is_a?(Array)
          pending = schema[:pending_migrations]
          if pending.any?
            shown = pending.first(5).map { |m| m[:version] }.join(", ")
            more = pending.size > 5 ? " (+#{pending.size - 5} more)" : ""
            lines << "**Pending migrations:** #{pending.size} - #{shown}#{more}"
          elsif schema[:schema_version]
            lines << "**Pending migrations:** none"
          end
        end
        lines
      end

      # Rails 8 multi-database apps dump each secondary database (queue,
      # cache, cable) to its own schema/structure file. This tool targets the
      # primary database's tables in detail, so secondaries get a compact
      # one-line-per-database summary rather than full column detail.
      private_class_method def self.secondary_databases_lines(schema)
        secondary = schema[:secondary_databases]
        return [] unless secondary

        lines = [ "", "## Secondary databases", "" ]
        secondary.each do |name, db|
          count = db[:total_tables]
          lines << "- **#{name}**: #{count_phrase(count, "table")} (#{db[:tables].keys.join(', ')}) - #{db[:note]}"
        end
        lines
      end

      # One JSON shape for every detail level: the schema as introspected,
      # with :tables cut down to the page the same pagination produced for
      # markdown. `detail` still decides how many tables a page holds.
      private_class_method def self.json_page_response(schema, tables, names, models = {})
        # unread_calls is the static reader's note to validate; the booted tier has none.
        page = names.to_h { |name| [ name, tables[name].is_a?(Hash) ? tables[name].except(:unread_calls) : tables[name] ] }
        coverage = model_coverage(tables, models)
        json_response(schema.merge(tables: page, gem_owned_tables: coverage[:gems], tables_without_model_file: coverage[:unclaimed]))
      end

      COVERAGE_CAP = 15

      # Over every table, not the page: which ones no model file claims, and
      # of those, which a gem the app bundles owns.
      private_class_method def self.model_coverage(tables, models)
        unclaimed = tables.keys.sort.select { |name| models_for_table(name, models).empty? } - habtm_join_tables(models).to_a
        unclaimed -= declared_join_tables(models).to_a if unclaimed.any?
        # A file the walk could not read claims no table, but it is still a model file.
        unclaimed -= models.filter_map { |_, d| d[:table_name] || Introspectors::TableName.stem(d[:file]) if d.is_a?(Hash) && d[:error] && d[:file] }
        gems = gem_owned(unclaimed)
        { gems: gems, unclaimed: unclaimed - gems.values.flatten }
      end

      private_class_method def self.model_coverage_lines(tables, models)
        coverage = model_coverage(tables, models)
        lines = coverage[:gems].map { |gem, owned| "Tables the #{gem} gem owns: #{capped(owned)}" }
        unclaimed = coverage[:unclaimed]
        if unclaimed.any?
          lines << "\u26A0 **Tables with no model file in this app**: #{capped(unclaimed)}"
          lines << "A gem that owns a table declares its model in the gem, so check the Gemfile before " \
                   "treating one of these as dead."
        end
        lists = [ unclaimed, *coverage[:gems].values ]
        if lists.any? { |list| list.size > COVERAGE_CAP }
          lines << "_`format:\"json\"` lists all #{unclaimed.size} in `tables_without_model_file` and the gems' in `gem_owned_tables`._"
        end
        lines
      end

      private_class_method def self.capped(names)
        return names.join(", ") if names.size <= COVERAGE_CAP

        "#{names.first(COVERAGE_CAP).join(', ')}, and #{names.size - COVERAGE_CAP} more"
      end

      # The type as a migration declares it: `decimal(10,2)`, `string, limit: 20`.
      private_class_method def self.column_type_label(col)
        label = col[:type].to_s
        sizes = [ col[:precision], col[:scale] ].compact
        label += "(#{sizes.join(',')})" if col[:precision]
        label += "[]" if col[:array]
        label += ", limit: #{col[:limit]}" if col[:limit]
        label += ", unsigned" if col[:unsigned]
        label += ", collation: #{col[:collation]}" if col[:collation]
        label
      end

      # Options are joined by semicolons because a value can list columns.
      private_class_method def self.index_options_text(idx)
        parts = []
        parts << "using: #{idx[:using]}" if idx[:using]
        parts << "type: #{idx[:type]}" if idx[:type]
        parts << "include: #{idx[:include].join(', ')}" if idx[:include]
        %i[order opclass length].each do |key|
          parts << "#{key}: #{idx[key].map { |column, value| "#{column} #{value}" }.join(', ')}" if idx[key]
        end
        parts << "nulls not distinct" if idx[:nulls_not_distinct]
        parts.any? ? " - #{parts.join('; ')}" : ""
      end

      private_class_method def self.format_table_markdown(name, data, models)
        columns = data[:columns] || []
        # Always show Nullable and Default - agents need these for migrations and validations
        has_defaults = columns.any? { |c| c.key?(:default) && !c[:default].nil? }

        model_refs = models_for_table(name, models)
        lines = [ "## Table: #{name}", "" ]
        lines << "**Models:** #{model_refs.join(', ')}" if model_refs.any?
        lines << "**Primary key:** #{RailsAiContext::Introspectors::SchemaConventions.primary_key_label(data[:primary_key])}" if data[:primary_key]
        lines << "**Comment:** #{data[:comment]}" if data[:comment]
        # A table right after a paragraph line would read as part of it.
        lines << "" if lines.size > 2

        header = "| Column | Type | Null"
        sep = "|--------|------|-----"
        header += " | Default" if has_defaults
        sep += "-|---------" if has_defaults
        lines << "#{header} |" << "#{sep}|"

        has_comments = columns.any? { |c| c[:comment] && !c[:comment].to_s.empty? }

        columns.each do |col|
          nullable = col.key?(:null) ? (col[:null] ? "yes" : "**NO**") : "yes"
          line = "| #{col[:name]} | #{column_type_label(col)} | #{nullable}"
          if has_defaults
            default_val = col[:default]
            display_default = default_val == "" ? '""' : default_val
            line += " | #{display_default}"
          end
          lines << "#{line} |"
          lines << "  _#{col[:comment]}_" if has_comments && col[:comment] && !col[:comment].to_s.empty?
        end
        if data[:inherits_unresolved]&.any?
          parents = data[:inherits_unresolved].map { |parent| "`#{parent}`" }.join(", ")
          lines << "" << "Inherits from #{parents}, which the structure.sql dump does not define: its columns are not shown."
        end

        if data[:indexes]&.any?
          lines << "" << "### Indexes"
          data[:indexes].each do |idx|
            unique = idx[:unique] ? " (unique)" : ""
            lines << "- `#{idx[:name]}` on (#{Array(idx[:columns]).join(', ')})#{unique}#{RailsAiContext::Introspectors::SchemaConventions.where_clause(idx[:where])}#{index_options_text(idx)}"
          end
        end

        if data[:unique_constraints]&.any?
          lines << "" << "### Unique constraints"
          data[:unique_constraints].each do |constraint|
            deferrable = constraint[:deferrable] ? ", deferrable: #{constraint[:deferrable]}" : ""
            lines << "- `#{constraint[:name]}` on (#{Array(constraint[:columns]).join(', ')})#{deferrable}"
          end
        end

        if data[:foreign_keys]&.any?
          lines << "" << "### Foreign keys"
          data[:foreign_keys].each do |fk|
            actions = fk.slice(:on_delete, :on_update).map { |key, value| "#{key}: #{value}" }
            lines << "- `#{RailsAiContext::Introspectors::SchemaConventions.key_text(fk[:column])}` → " \
                     "`#{fk[:to_table]}.#{RailsAiContext::Introspectors::SchemaConventions.key_text(fk[:primary_key])}`" \
                     "#{" (#{actions.join(', ')})" if actions.any?}"
          end
        end

        # Check constraints (full detail)
        if data[:check_constraints]&.any?
          lines << "" << "### Check Constraints"
          data[:check_constraints].each do |cc|
            label = cc[:name] ? "`#{cc[:name]}`" : ""
            lines << "- #{label} #{cc[:expression]}"
          end
        end

        # Enum types (full detail)
        if data[:enum_types]&.any?
          lines << "" << "### Enum Types"
          data[:enum_types].each do |et|
            values = et[:values]&.join(", ") || ""
            lines << "- `#{et[:name]}`: #{values}"
          end
        end

        # Generated columns (full detail)
        if data[:generated_columns]&.any?
          lines << "" << "### Generated Columns"
          data[:generated_columns].each do |gc|
            lines << "- `#{gc[:name]}` - #{gc[:expression]}"
          end
        end

        lines.join("\n")
      end
    end
  end
end
