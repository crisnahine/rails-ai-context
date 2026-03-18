# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetSchema < BaseTool
      tool_name "rails_get_schema"
      description "Get the database schema for the Rails app including tables, columns, indexes, and foreign keys. Optionally filter by table name."

      input_schema(
        properties: {
          table: {
            type: "string",
            description: "Optional: specific table name to inspect. Omit for full schema."
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

      def self.call(table: nil, format: "markdown", server_context: nil)
        schema = cached_context[:schema]
        return text_response("Schema introspection not available: #{schema[:error]}") if schema[:error]

        if table
          table_data = schema.dig(:tables, table)
          return text_response("Table '#{table}' not found. Available: #{schema[:tables].keys.join(', ')}") unless table_data

          output = format == "json" ? table_data.to_json : format_table_markdown(table, table_data)
        else
          output = format == "json" ? schema.to_json : format_schema_markdown(schema)
        end

        text_response(output)
      end

      private_class_method def self.format_table_markdown(name, data)
        lines = [ "## Table: #{name}", "" ]
        lines << "| Column | Type | Nullable | Default |"
        lines << "|--------|------|----------|---------|"

        data[:columns].each do |col|
          lines << "| #{col[:name]} | #{col[:type]} | #{col[:null] ? 'yes' : 'no'} | #{col[:default] || '-'} |"
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

        schema[:tables].each do |name, data|
          cols = data[:columns].map { |c| "#{c[:name]}:#{c[:type]}" }.join(", ")
          lines << "### #{name}"
          lines << cols
          lines << ""
        end

        lines.join("\n")
      end
    end
  end
end
