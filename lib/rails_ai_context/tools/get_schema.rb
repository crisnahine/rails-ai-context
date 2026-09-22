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
              return not_found_response("Table", table, tables.keys.sort,
                recovery_tool: "Call rails_get_schema(detail:\"summary\") to see all tables")
            end
            return json_response(table_data) if format == "json"

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
            return json_page_response(schema, tables, paginated) if format == "json"

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
            return json_page_response(schema, tables, paginated) if format == "json"

            if paginated.empty?
              return text_response("No tables at offset #{page[:offset]}. Total tables: #{total}. Use `offset:0` to start from the beginning.")
            end

            lines = [ "# Schema (#{count_phrase(total, "table")}, showing #{paginated.size})", "" ]
            lines.concat(static_source_lines(schema))
            paginated.each do |name|
              data = tables[name]
              timestamp_cols = %w[id created_at updated_at]

              # Build indexed/unique column sets for inline hints
              indexed_cols = Set.new
              unique_cols = Set.new
              (data[:indexes] || []).each do |idx|
                Array(idx[:columns]).each do |col|
                  idx[:unique] ? unique_cols.add(col) : indexed_cols.add(col)
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
                  hints << "unique" if unique_cols.include?(c[:name])
                  hints << "indexed" if indexed_cols.include?(c[:name]) && !unique_cols.include?(c[:name])
                  hints << "encrypted" if encrypted_cols.include?(c[:name])
                  # Show default value if present
                  if c.key?(:default) && !c[:default].nil? && c[:default] != ""
                    hints << "default: #{c[:default]}"
                  end
                  hint_str = hints.any? ? " [#{hints.join(', ')}]" : ""
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
              lines << "### #{name}#{model_info}"
              lines << cols
              lines << ""
            end

            unclaimed = paginated.select { |name| models_for_table(name, models_data).empty? } - habtm_join_tables(models_data).to_a
            if unclaimed.any?
              lines << "\u26A0 **Tables with no model file in this app**: #{unclaimed.join(', ')}"
              lines << "A gem that owns a table declares its model in the gem, so check the Gemfile before " \
                       "treating one of these as dead."
              lines << ""
            end

            lines.concat(secondary_databases_lines(schema))
            lines << "_Use `detail:\"summary\"` for all #{count_phrase(total, "table")}, `detail:\"full\"` for indexes/FKs, or `table:\"name\"` for one table._" if total > page[:limit]
            text_response(lines.join("\n"))

          when "full"
            page = paginate(tables.keys.sort, offset: offset, limit: limit, default_limit: 10)
            paginated = page[:items]
            return json_page_response(schema, tables, paginated) if format == "json"

            if paginated.empty? && total > 0
              return text_response("No tables at offset #{page[:offset]}. Total: #{total}. Use `offset:0` to start over.")
            end

            lines = [ "# Schema Full Detail (#{paginated.size} of #{count_phrase(total, "table")})", "" ]
            paginated.each do |name|
              lines << format_table_markdown(name, tables[name], models_data)
              lines << ""
            end
            lines.concat(secondary_databases_lines(schema))
            if page[:offset] + page[:limit] < total
              lines << "_Showing #{paginated.size} of #{total}. Use `offset:#{page[:offset] + page[:limit]}` for more._"
              lines << "_cache_key: #{cache_key}_"
            end
            text_response(lines.join("\n"))
          else
            # Fallback to full dump (backward compat)
            text_response(format_schema_markdown(schema, ctx))
          end
        end
      end

      # The same seam the generated context files use. Answering this question
      # locally is how one app came to be told it runs on PostgreSQL by
      # CLAUDE.md and on "unknown" by this tool, in the same session.
      private_class_method def self.adapter_label(ctx)
        RailsAiContext::SchemaAdapter.label(ctx)
      end

      # Rails builds no model for a has_and_belongs_to_many join table, so one
      # is not a table whose model is missing. The name is the two tables
      # sorted, unless the association writes :join_table itself.
      private_class_method def self.habtm_join_tables(models)
        models.each_with_object(Set.new) do |(_name, data), found|
          next unless data.is_a?(Hash)

          Array(data[:associations]).each do |assoc|
            next unless assoc[:type].to_s == "has_and_belongs_to_many"

            options = assoc[:options].is_a?(Hash) ? assoc[:options] : {}
            if options[:join_table]
              found << options[:join_table].to_s
              next
            end
            next unless data[:table_name]

            other = (assoc[:class_name] || options[:class_name] || assoc[:name]).to_s.tableize
            found << [ data[:table_name].to_s, other ].sort.join("_")
          end
        end
      rescue => e
        RailsAiContext.debug_fail(e, Set.new, label: "habtm_join_tables")
      end

      private_class_method def self.models_for_table(table_name, models)
        models.select { |_, d| d.is_a?(Hash) && d[:table_name] == table_name }.keys
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "models_for_table")
      end

      # Rails 8 multi-database apps dump each secondary database (queue,
      # cache, cable) to its own schema/structure file. This tool targets
      # the primary database's tables in detail, so secondaries get a
      # compact one-line-per-database summary rather than full column detail.
      # Static-parse extras: the SQL dialect the dump was written in, the
      # schema version recorded by the dump, and migration files it doesn't
      # cover - the static-tier stand-ins for a live connection's answers.
      private_class_method def self.static_source_lines(schema)
        lines = []
        lines << "**Dialect:** #{schema[:dialect]} (db/structure.sql)" if schema[:dialect] && schema[:dialect] != "unknown"
        lines << "**Schema version:** #{schema[:schema_version]}" if schema[:schema_version]
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
      private_class_method def self.json_page_response(schema, tables, names)
        page = names.to_h { |name| [ name, tables[name] ] }
        json_response(schema.merge(tables: page))
      end

      private_class_method def self.format_table_markdown(name, data, models)
        columns = data[:columns] || []
        # Always show Nullable and Default - agents need these for migrations and validations
        has_defaults = columns.any? { |c| c.key?(:default) && !c[:default].nil? }

        model_refs = models_for_table(name, models)
        lines = [ "## Table: #{name}", "" ]
        lines << "**Models:** #{model_refs.join(', ')}" if model_refs.any?

        header = "| Column | Type | Null"
        sep = "|--------|------|-----"
        header += " | Default" if has_defaults
        sep += "-|---------" if has_defaults
        lines << "#{header} |" << "#{sep}|"

        has_comments = columns.any? { |c| c[:comment] && !c[:comment].to_s.empty? }

        columns.each do |col|
          nullable = col.key?(:null) ? (col[:null] ? "yes" : "**NO**") : "yes"
          col_type = col[:array] ? "#{col[:type]}[]" : col[:type].to_s
          line = "| #{col[:name]} | #{col_type} | #{nullable}"
          if has_defaults
            default_val = col[:default]
            display_default = default_val == "" ? '""' : default_val
            line += " | #{display_default}"
          end
          lines << "#{line} |"
          lines << "  _#{col[:comment]}_" if has_comments && col[:comment] && !col[:comment].to_s.empty?
        end

        if data[:indexes]&.any?
          lines << "" << "### Indexes"
          data[:indexes].each do |idx|
            unique = idx[:unique] ? " (unique)" : ""
            lines << "- `#{idx[:name]}` on (#{Array(idx[:columns]).join(', ')})#{unique}"
          end
        end

        if data[:foreign_keys]&.any?
          lines << "" << "### Foreign keys"
          data[:foreign_keys].each do |fk|
            lines << "- `#{fk[:column]}` → `#{fk[:to_table]}.#{fk[:primary_key]}`"
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

      private_class_method def self.format_schema_markdown(schema, ctx)
        lines = [
          "# Database Schema",
          "",
          "- Adapter: #{adapter_label(ctx)}",
          "- Tables: #{schema[:total_tables]}",
          ""
        ]

        (schema[:tables] || {}).each do |name, data|
          cols = (data[:columns] || []).map { |c| "#{c[:name]}:#{c[:type]}" }.join(", ")
          lines << "### #{name}"
          lines << cols
          lines << ""
        end

        lines.concat(secondary_databases_lines(schema))
        lines.join("\n")
      end
    end
  end
end
