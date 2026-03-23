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
            description: "Max tables to return when listing. Default: 50 for summary, 15 for standard, 5 for full."
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
        schema = cached_context[:schema]
        return text_response("Schema introspection not available. Add :schema to introspectors.") unless schema
        return text_response("Schema introspection not available: #{schema[:error]}") if schema[:error]

        tables = schema[:tables] || {}

        # Return full JSON if requested (existing behavior)
        return text_response(schema.to_json) if format == "json" && detail == "full"

        total = tables.size
        offset = [ offset.to_i, 0 ].max

        # Single table — case-insensitive lookup
        if table
          table_key = tables.keys.find { |k| k.downcase == table.downcase } || table
          table_data = tables[table_key]
          unless table_data
            return not_found_response("Table", table, tables.keys.sort,
              recovery_tool: "Call rails_get_schema(detail:\"summary\") to see all tables")
          end
          output = format == "json" ? table_data.to_json : format_table_markdown(table_key, table_data)
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
          limit ||= 15
          limit = 15 if limit.to_i < 1
          paginated = tables.keys.sort.drop(offset).first(limit)
          if paginated.empty?
            return text_response("No tables at offset #{offset}. Total tables: #{total}. Use `offset:0` to start from the beginning.")
          end
          lines = [ "# Schema (#{total} tables, showing #{paginated.size})", "" ]
          paginated.each do |name|
            data = tables[name]
            timestamp_cols = %w[id created_at updated_at]
            cols = (data[:columns] || [])
              .reject { |c| timestamp_cols.include?(c[:name]) }
              .map { |c| "#{c[:name]}:#{c[:type]}" }.join(", ")
            lines << "### #{name}"
            lines << cols
            lines << ""
          end
          lines << "_Use `detail:\"summary\"` for all #{total} tables, `detail:\"full\"` for indexes/FKs, or `table:\"name\"` for one table._" if total > limit
          text_response(lines.join("\n"))

        when "full"
          limit ||= 5
          limit = 5 if limit.to_i < 1
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

      private_class_method def self.format_table_markdown(name, data)
        columns = data[:columns] || []
        # Always show Nullable and Default — agents need these for migrations and validations
        has_defaults = columns.any? { |c| c.key?(:default) && !c[:default].nil? }

        lines = [ "## Table: #{name}", "" ]

        header = "| Column | Type | Null"
        sep = "|--------|------|-----"
        header += " | Default" if has_defaults
        sep += "-|---------" if has_defaults
        lines << "#{header} |" << "#{sep}|"

        columns.each do |col|
          nullable = col.key?(:null) ? (col[:null] ? "yes" : "**NO**") : "yes"
          col_type = col[:array] ? "#{col[:type]}[]" : col[:type].to_s
          line = "| #{col[:name]} | #{col_type} | #{nullable}"
          line += " | #{col[:default]}" if has_defaults
          lines << "#{line} |"
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
