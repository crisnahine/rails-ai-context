# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts database schema information including tables, columns,
    # indexes, and foreign keys from the Rails application.
    class SchemaIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] database schema context
      def call
        return static_schema_parse unless active_record_connected?

        {
          adapter: adapter_name,
          tables: extract_tables,
          total_tables: table_names.size,
          schema_version: current_schema_version
        }
      end

      private

      def active_record_connected?
        defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
      rescue
        false
      end

      def adapter_name
        ActiveRecord::Base.connection.adapter_name
      rescue
        "unknown"
      end

      def connection
        ActiveRecord::Base.connection
      end

      def table_names
        @table_names ||= connection.tables.reject { |t| t.start_with?("ar_internal_metadata", "schema_migrations") }
      end

      def extract_tables
        table_names.each_with_object({}) do |table, hash|
          hash[table] = {
            columns: extract_columns(table),
            indexes: extract_indexes(table),
            foreign_keys: extract_foreign_keys(table),
            primary_key: connection.primary_key(table)
          }
        end
      end

      def extract_columns(table)
        connection.columns(table).map do |col|
          {
            name: col.name,
            type: col.type.to_s,
            null: col.null,
            default: col.default,
            limit: col.limit,
            precision: col.precision,
            scale: col.scale,
            comment: col.comment
          }.compact
        end
      end

      def extract_indexes(table)
        connection.indexes(table).map do |idx|
          {
            name: idx.name,
            columns: idx.columns,
            unique: idx.unique,
            where: idx.where
          }.compact
        end
      end

      def extract_foreign_keys(table)
        connection.foreign_keys(table).map do |fk|
          {
            from_table: fk.from_table,
            to_table: fk.to_table,
            column: fk.column,
            primary_key: fk.primary_key,
            on_delete: fk.on_delete,
            on_update: fk.on_update
          }.compact
        end
      rescue
        [] # Some adapters don't support foreign_keys
      end

      def current_schema_version
        if File.exist?(schema_file_path)
          content = File.read(schema_file_path)
          match = content.match(/version:\s*([\d_]+)/)
          match ? match[1].delete("_") : nil
        end
      end

      def schema_file_path
        File.join(app.root, "db", "schema.rb")
      end

      def structure_file_path
        File.join(app.root, "db", "structure.sql")
      end

      # Fallback: parse schema file as text when DB isn't connected.
      # Tries db/schema.rb first, then db/structure.sql.
      # This enables introspection in CI, Claude Code, etc.
      def static_schema_parse
        if File.exist?(schema_file_path)
          parse_schema_rb(schema_file_path)
        elsif File.exist?(structure_file_path)
          parse_structure_sql(structure_file_path)
        else
          { error: "No db/schema.rb or db/structure.sql found" }
        end
      end

      def parse_schema_rb(path)
        content = File.read(path)
        tables = {}
        current_table = nil

        content.each_line do |line|
          if (match = line.match(/create_table\s+"(\w+)"/))
            current_table = match[1]
            next if current_table.start_with?("ar_internal_metadata", "schema_migrations")
            tables[current_table] = { columns: [], indexes: [], foreign_keys: [] }
          elsif current_table && (match = line.match(/t\.index\s+(.+)/))
            rest = match[1]
            cols = rest.match(/\[([^\]]+)\]/)&.[](1)&.scan(/"(\w+)"/)&.flatten || []
            unique = rest.include?("unique: true")
            idx_name = rest.match(/name:\s*"([\w]+)"/)&.[](1)
            tables[current_table][:indexes] << { name: idx_name, columns: cols, unique: unique }.compact if cols.any?
          elsif current_table && (match = line.match(/t\.(\w+)\s+"(\w+)"/))
            tables[current_table][:columns] << { name: match[2], type: match[1] }
          elsif (match = line.match(/add_index\s+"(\w+)",\s+(.+)/))
            table_name = match[1]
            rest = match[2]
            array_match = rest.match(/\[([^\]]+)\]/)
            cols = if array_match
              inside = array_match[1]
              inside.include?('"') ? inside.scan(/"(\w+)"/).flatten : inside.scan(/\b(\w+)\b/).flatten
            else
              rest.match(/(?::|")(\w+)/)&.[](1)&.then { |c| [ c ] } || []
            end
            unique = rest.include?("unique: true")
            idx_name = rest.match(/name:\s*"(\w+)"/)&.send(:[], 1)
            tables[table_name]&.dig(:indexes)&.push({ name: idx_name, columns: cols, unique: unique }.compact) if cols.any?
          end
        end

        {
          adapter: "static_parse",
          tables: tables,
          total_tables: tables.size,
          note: "Parsed from db/schema.rb (no DB connection)"
        }
      end

      def parse_structure_sql(path) # rubocop:disable Metrics/MethodLength
        content = File.read(path)
        tables = {}

        # Match CREATE TABLE blocks
        content.scan(/CREATE TABLE (?:public\.)?(\w+)\s*\((.*?)\);/m) do |table_name, body|
          next if table_name.start_with?("ar_internal_metadata", "schema_migrations")

          columns = parse_sql_columns(body)
          tables[table_name] = { columns: columns, indexes: [], foreign_keys: [] }
        end

        # Match CREATE INDEX / CREATE UNIQUE INDEX
        content.scan(/CREATE (UNIQUE )?INDEX (\w+) ON (?:public\.)?(\w+).*?\((.+?)\)/m) do |unique, idx_name, table, cols|
          col_list = cols.scan(/\w+/)
          tables[table]&.dig(:indexes)&.push({ name: idx_name, columns: col_list, unique: !!unique })
        end

        # Match ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY (handles multi-line)
        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?(?:public\.)?(\w+)\s+ADD CONSTRAINT.*?FOREIGN KEY\s*\((\w+)\)\s*REFERENCES\s+(?:public\.)?(\w+)\((\w+)\)/m) do |from, col, to, pk|
          tables[from]&.dig(:foreign_keys)&.push({ from_table: from, to_table: to, column: col, primary_key: pk })
        end

        {
          adapter: "static_parse",
          tables: tables,
          total_tables: tables.size,
          note: "Parsed from db/structure.sql (no DB connection)"
        }
      end

      # Parse column definitions from a CREATE TABLE body
      def parse_sql_columns(body)
        columns = []
        body.each_line do |line|
          line = line.strip.chomp(",").strip
          next if line.empty?
          next if line.match?(/\A(PRIMARY|CONSTRAINT|CHECK|UNIQUE|EXCLUDE|FOREIGN)\b/i)

          # Match: column_name type_with_params [constraints]
          if (match = line.match(/\A"?(\w+)"?\s+(.+)/))
            col_name = match[1]
            rest = match[2]
            # Extract type: everything before NOT NULL, NULL, DEFAULT, etc.
            col_type = rest.split(/\s+(?:NOT\s+NULL|NULL|DEFAULT|PRIMARY|UNIQUE|CONSTRAINT|CHECK)\b/i).first&.strip&.downcase
            next unless col_type && !col_type.empty?
            columns << { name: col_name, type: normalize_sql_type(col_type) }
          end
        end
        columns
      end

      def normalize_sql_type(type)
        case type
        when /\Ainteger\z/i, /\Aint\z/i, /\Aint4\z/i then "integer"
        when /\Abigint\z/i, /\Aint8\z/i then "bigint"
        when /\Asmallint\z/i, /\Aint2\z/i then "smallint"
        when /\Acharacter varying\z/i, /\Avarchar\z/i then "string"
        when /\Atext\z/i then "text"
        when /\Aboolean\z/i, /\Abool\z/i then "boolean"
        when /\Atimestamp/i then "datetime"
        when /\Adate\z/i then "date"
        when /\Atime\z/i then "time"
        when /\Anumeric\z/i, /\Adecimal\z/i then "decimal"
        when /\Afloat/i, /\Adouble/i then "float"
        when /\Ajsonb?\z/i then "json"
        when /\Auuid\z/i then "uuid"
        when /\Ainet\z/i then "inet"
        when /\Acitext\z/i then "citext"
        when /\Aarray\z/i then "array"
        when /\Ahstore\z/i then "hstore"
        else type
        end
      end
    end
  end
end
