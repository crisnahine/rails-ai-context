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
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: table names + column counts. standard: table names + column names/types (default). full: everything including indexes, FKs, comments."
          },
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

      annotations(
        read_only_hint: true,
        destructive_hint: false,
        idempotent_hint: true,
        open_world_hint: false
      )

      def self.call(table: nil, detail: "standard", limit: nil, offset: 0, format: "markdown", server_context: nil)
        set_call_params(table: table, detail: detail)
        schema = cached_context[:schema]
        return text_response("Schema introspection not available. Add :schema to introspectors.") unless schema
        return text_response("Schema introspection not available: #{schema[:error]}") if schema[:error]

        tables = schema[:tables] || {}

        # Return full JSON if requested (existing behavior)
        return text_response(schema.to_json) if format == "json" && detail == "full"

        total = tables.size
        offset = [ offset.to_i, 0 ].max
        limit = [ limit.to_i, 0 ].max if limit && limit.to_i < 0

        # Single table — case-insensitive lookup with model name normalization
        # Accepts: "users", "Users", "User" (model name → pluralized+underscored table)
        if table
          table_down = table.downcase
          table_as_table = table.underscore.pluralize # Post → posts, UserProfile → user_profiles
          table_key = tables.keys.find { |k|
            k.downcase == table_down || k == table_as_table || k == table.underscore
          } || table
          table_data = tables[table_key]
          unless table_data
            return not_found_response("Table", table, tables.keys.sort,
              recovery_tool: "Call rails_get_schema(detail:\"summary\") to see all tables")
          end
          if format == "json"
            return text_response(table_data.to_json)
          end

          output = format_table_markdown(table_key, table_data)
          # Cross-reference hint for AI: suggest next tool call
          model_refs = models_for_table(table_key)
          if model_refs.any?
            output += "\n\n_Next: `rails_get_model_details(model:\"#{model_refs.first}\")` for associations, validations, scopes._"
          end
          return text_response(output)
        end

        case detail
        when "summary"
          limit ||= 50
          limit = 50 if limit.to_i < 1
          paginated = tables.keys.sort.drop(offset).first(limit)
          if paginated.empty? && total > 0
            return text_response("No tables at offset #{offset}. Total: #{total}. Use `offset:0` to start over.")
          end
          lines = [ "# Schema Summary (#{total} tables)", "" ]
          lines << "**Adapter:** #{schema[:adapter]}" if schema[:adapter]
          paginated.each do |name|
            data = tables[name]
            col_count = data[:columns]&.size || 0
            idx_count = data[:indexes]&.size || 0
            lines << "- **#{name}** — #{col_count} columns, #{idx_count} indexes"
          end
          if offset + limit < total
            lines << "" << "_Showing #{paginated.size} of #{total}. Use `offset:#{offset + limit}` for more, or `table:\"name\"` for full detail._"
            lines << "_cache_key: #{cache_key}_"
          end
          text_response(lines.join("\n"))

        when "standard"
          limit ||= 25
          limit = 25 if limit.to_i < 1
          # Sort by column count (most complex first) — AI agents care about big tables first
          sorted = tables.keys.sort_by { |name| -(tables[name][:columns]&.size || 0) }
          paginated = sorted.drop(offset).first(limit)
          if paginated.empty?
            return text_response("No tables at offset #{offset}. Total tables: #{total}. Use `offset:0` to start from the beginning.")
          end
          lines = [ "# Schema (#{total} tables, showing #{paginated.size})", "" ]
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
            model_refs = models_for_table(name)
            models_data = cached_context[:models] || {}
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
            model_info = ""
            if model_refs.any?
              model_refs.each do |mname|
                md = models_data[mname]
                next unless md.is_a?(Hash) && !md[:error]
                assoc_count = md[:associations]&.size || 0
                val_count = md[:validations]&.size || 0
                model_info = " → **#{mname}** (#{assoc_count} assoc, #{val_count} val)"
                break
              end
            end
            lines << "### #{name}#{model_info}"
            lines << cols
            lines << ""
          end

          # Detect orphaned tables (no ActiveRecord model maps to them)
          orphaned = paginated.select { |name| models_for_table(name).empty? }
          if orphaned.any?
            lines << "\u26A0 **Orphaned tables** (no ActiveRecord model): #{orphaned.join(', ')}"
            lines << ""
          end

          lines << "_Use `detail:\"summary\"` for all #{total} tables, `detail:\"full\"` for indexes/FKs, or `table:\"name\"` for one table._" if total > limit
          text_response(lines.join("\n"))

        when "full"
          limit ||= 10
          limit = 10 if limit.to_i < 1
          paginated = tables.keys.sort.drop(offset).first(limit)
          if paginated.empty? && total > 0
            return text_response("No tables at offset #{offset}. Total: #{total}. Use `offset:0` to start over.")
          end
          lines = [ "# Schema Full Detail (#{paginated.size} of #{total} tables)", "" ]
          paginated.each do |name|
            lines << format_table_markdown(name, tables[name])
            lines << ""
          end
          if offset + limit < total
            lines << "_Showing #{paginated.size} of #{total}. Use `offset:#{offset + limit}` for more._"
            lines << "_cache_key: #{cache_key}_"
          end
          text_response(lines.join("\n"))
        else
          # Fallback to full dump (backward compat)
          text_response(format_schema_markdown(schema))
        end
      end

      private_class_method def self.models_for_table(table_name)
        models = cached_context[:models]
        return [] unless models.is_a?(Hash)

        models.select { |_, d| d.is_a?(Hash) && d[:table_name] == table_name }.keys
      rescue => e
        $stderr.puts "[rails-ai-context] models_for_table failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      private_class_method def self.format_table_markdown(name, data)
        columns = data[:columns] || []
        # Always show Nullable and Default — agents need these for migrations and validations
        has_defaults = columns.any? { |c| c.key?(:default) && !c[:default].nil? }

        model_refs = models_for_table(name)
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
            lines << "- `#{gc[:name]}` — #{gc[:expression]}"
          end
        end

        lines.join("\n")
      end

      private_class_method def self.format_schema_markdown(schema)
        lines = [
          "# Database Schema",
          "",
          "- Adapter: #{schema[:adapter]}",
          "- Tables: #{schema[:total_tables]}",
          ""
        ]

        (schema[:tables] || {}).each do |name, data|
          cols = (data[:columns] || []).map { |c| "#{c[:name]}:#{c[:type]}" }.join(", ")
          lines << "### #{name}"
          lines << cols
          lines << ""
        end

        lines.join("\n")
      end
    end
  end
end
