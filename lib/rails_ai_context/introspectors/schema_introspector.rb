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
        return static_schema_parse if table_names.empty?

        schema_content = File.exist?(schema_file_path) ? File.read(schema_file_path) : ""

        {
          adapter: adapter_name,
          tables: extract_tables,
          total_tables: table_names.size,
          schema_version: current_schema_version,
          check_constraints: parse_check_constraints(schema_content),
          enum_types: parse_enum_types(schema_content),
          generated_columns: parse_generated_columns(schema_content)
        }
      end

      private

      def active_record_connected?
        defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
      rescue => e
        $stderr.puts "[rails-ai-context] active_record_connected? failed: #{e.message}" if ENV["DEBUG"]
        false
      end

      def adapter_name
        ActiveRecord::Base.connection.adapter_name
      rescue => e
        $stderr.puts "[rails-ai-context] adapter_name failed: #{e.message}" if ENV["DEBUG"]
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
        schema_defaults = parse_schema_defaults_for_table(table)

        connection.columns(table).map do |col|
          entry = {
            name: col.name,
            type: col.type.to_s,
            null: col.null,
            default: col.default,
            limit: col.limit,
            precision: col.precision,
            scale: col.scale,
            comment: col.comment
          }
          # Supplement with schema.rb default when live DB returns nil
          if entry[:default].nil? && schema_defaults[col.name]
            entry[:default] = schema_defaults[col.name]
          end
          entry.compact
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
      rescue => e
        $stderr.puts "[rails-ai-context] extract_foreign_keys failed: #{e.message}" if ENV["DEBUG"]
        [] # Some adapters don't support foreign_keys
      end

      # Parse default values from schema.rb for a specific table.
      # Used to supplement live DB column data when the adapter returns nil defaults.
      # Caches the schema.rb content to avoid re-reading once per table.
      def parse_schema_defaults_for_table(table)
        return {} unless File.exist?(schema_file_path)

        @schema_rb_content ||= File.read(schema_file_path)
        defaults = {}
        in_table = false

        @schema_rb_content.each_line do |line|
          if line.match?(/create_table\s+"#{Regexp.escape(table)}"/)
            in_table = true
          elsif in_table && line.match?(/\A\s*end\b/)
            break
          elsif in_table
            # Match column with a simple default value (skip proc defaults like -> { })
            if (match = line.match(/t\.\w+\s+"(\w+)".*,\s*default:\s*("[^"]*"|\d+(?:\.\d+)?|true|false)/))
              col_name = match[1]
              raw = match[2]
              defaults[col_name] = raw.start_with?('"') ? raw[1..-2] : raw
            end
          end
        end

        defaults
      rescue => e
        $stderr.puts "[rails-ai-context] parse_schema_defaults_for_table failed: #{e.message}" if ENV["DEBUG"]
        {}
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

      def migrations_dir
        File.join(app.root, "db", "migrate")
      end

      def max_schema_file_size
        RailsAiContext.configuration.max_schema_file_size
      end

      # Fallback: parse schema file as text when DB isn't connected.
      # Tries db/schema.rb first, then db/structure.sql, then migrations.
      # This enables introspection in CI, Claude Code, etc.
      def static_schema_parse
        if File.exist?(schema_file_path)
          result = parse_schema_rb(schema_file_path)
          return result if result[:total_tables].to_i > 0
        end

        if File.exist?(structure_file_path)
          result = parse_structure_sql(structure_file_path)
          return result if result[:total_tables].to_i > 0
        end

        if Dir.exist?(migrations_dir) && Dir.glob(File.join(migrations_dir, "*.rb")).any?
          return parse_migrations
        end

        { error: "No db/schema.rb, db/structure.sql, or migrations found" }
      end

      def parse_schema_rb(path)
        return { error: "schema.rb too large (#{File.size(path)} bytes)" } if File.size(path) > max_schema_file_size
        content = File.read(path)
        tables = {}
        current_table = nil

        content.each_line do |line|
          if (match = line.match(/create_table\s+"(\w+)"/))
            current_table = match[1]
            if current_table.start_with?("ar_internal_metadata", "schema_migrations")
              current_table = nil
              next
            end
            tables[current_table] = { columns: [], indexes: [], foreign_keys: [] }
          elsif current_table && (match = line.match(/t\.(\w+)\s+"(\w+)"/))
            col = { name: match[2], type: match[1] }
            col[:null] = false if line.include?("null: false")
            if (default_match = line.match(/default:\s*("[^"]*"|\{[^}]*\}|\[[^\]]*\]|-?\d+(?:\.\d+)?|true|false)/))
              raw = default_match[1]
              col[:default] = raw.start_with?('"') ? raw[1..-2] : raw
            end
            col[:array] = true if line.include?("array: true")
            tables[current_table][:columns] << col
          elsif current_table && (match = line.match(/t\.index\s+\[([^\]]*)\]/))
            cols = match[1].scan(/["'](\w+)["']/).flatten
            unique = line.include?("unique: true")
            idx_name = line.match(/name:\s*["']([^"']+)["']/)&.send(:[], 1)
            tables[current_table][:indexes] << { name: idx_name, columns: cols, unique: unique }.compact if cols.any?
          elsif (match = line.match(/add_index\s+"(\w+)",\s+(.+)/))
            table_name = match[1]
            rest = match[2]
            # Extract columns only from the [...] array portion, not option keys
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
          elsif (match = line.match(/add_foreign_key\s+"(\w+)",\s+"(\w+)"/))
            from_table = match[1]
            to_table = match[2]
            column_match = line.match(/column:\s*"(\w+)"/)
            column = column_match ? column_match[1] : "#{to_table.singularize}_id"
            pk_match = line.match(/primary_key:\s*"(\w+)"/)
            primary_key = pk_match ? pk_match[1] : "id"
            tables[from_table]&.dig(:foreign_keys)&.push({
              from_table: from_table, to_table: to_table,
              column: column, primary_key: primary_key
            })
          end
        end

        {
          adapter: "static_parse",
          tables: tables,
          total_tables: tables.size,
          schema_version: current_schema_version,
          check_constraints: parse_check_constraints(content),
          enum_types: parse_enum_types(content),
          generated_columns: parse_generated_columns(content),
          note: "Parsed from db/schema.rb (no DB connection)"
        }
      end

      def parse_structure_sql(path) # rubocop:disable Metrics/MethodLength
        return { error: "structure.sql too large (#{File.size(path)} bytes)" } if File.size(path) > max_schema_file_size
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

      # Parse check constraints from schema.rb content
      # Matches t.check_constraint "expression" and add_check_constraint "table", "expression"
      def parse_check_constraints(content)
        return [] if content.nil? || content.empty?

        constraints = []
        current_table = nil

        content.each_line do |line|
          if (table_match = line.match(/create_table\s+"(\w+)"/))
            current_table = table_match[1]
          elsif line.match?(/\A\s*end\b/) && current_table
            current_table = nil
          end

          # t.check_constraint "expression", name: "..."
          if current_table && (match = line.match(/t\.check_constraint\s+"([^"]+)"/))
            constraints << { table: current_table, expression: match[1] }
          end

          # add_check_constraint "table", "expression"
          if (match = line.match(/add_check_constraint\s+"(\w+)",\s+"([^"]+)"/))
            constraints << { table: match[1], expression: match[2] }
          end
        end

        constraints
      rescue => e
        $stderr.puts "[rails-ai-context] parse_check_constraints failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Parse create_enum statements from schema.rb
      # Matches create_enum "name", ["value1", "value2"]
      def parse_enum_types(content)
        return [] if content.nil? || content.empty?

        enums = []
        content.each_line do |line|
          if (match = line.match(/create_enum\s+"(\w+)",\s*\[([^\]]+)\]/))
            name = match[1]
            values = match[2].scan(/"([^"]+)"/).flatten
            enums << { name: name, values: values }
          end
        end

        enums
      rescue => e
        $stderr.puts "[rails-ai-context] parse_enum_types failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Parse generated/virtual columns from schema.rb
      # Detects virtual: true or stored: true column options
      def parse_generated_columns(content)
        return [] if content.nil? || content.empty?

        columns = []
        current_table = nil

        content.each_line do |line|
          if (table_match = line.match(/create_table\s+"(\w+)"/))
            current_table = table_match[1]
          elsif line.match?(/\A\s*end\b/) && current_table
            current_table = nil
          end

          next unless current_table

          if line.match?(/virtual:\s*true/) || line.match?(/stored:\s*true/)
            col_match = line.match(/t\.\w+\s+"(\w+)"/)
            next unless col_match
            stored = line.match?(/stored:\s*true/)
            columns << { table: current_table, column: col_match[1], stored: stored }
          end
        end

        columns
      rescue => e
        $stderr.puts "[rails-ai-context] parse_generated_columns failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Reconstruct schema by replaying migrations in order.
      # Handles: create_table, add_column, remove_column, rename_column,
      # rename_table, drop_table, change_column, add_index, add_reference,
      # add_foreign_key, add_timestamps.
      def parse_migrations
        tables = {}
        migration_files = Dir.glob(File.join(migrations_dir, "*.rb")).sort

        migration_files.each do |path|
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
          replay_migration(content, tables)
        rescue => e
          next # Skip unparseable migrations
        end

        # Remove internal Rails tables
        tables.delete("ar_internal_metadata")
        tables.delete("schema_migrations")

        {
          adapter: "static_parse",
          tables: tables,
          total_tables: tables.size,
          note: "Reconstructed from #{migration_files.size} migration files (no DB connection, no schema.rb)"
        }
      end

      def replay_migration(content, tables) # rubocop:disable Metrics
        current_table = nil

        content.each_line do |line|
          stripped = line.strip

          # create_table :name / create_table "name"
          if (match = stripped.match(/create_table\s+[:"'](\w+)/))
            table_name = match[1]
            current_table = table_name
            tables[table_name] ||= { columns: [], indexes: [], foreign_keys: [] }
            # create_table implicitly adds id and timestamps in some cases
          elsif stripped.match?(/\A\s*end\b/) && current_table
            current_table = nil

          # t.references / t.belongs_to inside create_table (must be before general column match)
          elsif current_table && (match = stripped.match(/t\.(?:references|belongs_to)\s+[:"'](\w+)/))
            ref_name = match[1]
            col = { name: "#{ref_name}_id", type: "bigint" }
            col[:null] = false if stripped.include?("null: false")
            tables[current_table][:columns] << col

          # t.timestamps inside create_table
          elsif current_table && stripped.match?(/t\.timestamps/)
            tables[current_table][:columns] << { name: "created_at", type: "datetime", null: false }
            tables[current_table][:columns] << { name: "updated_at", type: "datetime", null: false }

          # t.index inside create_table
          elsif current_table && (match = stripped.match(/t\.index\s+\[([^\]]*)\]/))
            cols = match[1].scan(/[:"'](\w+)/).flatten
            unique = stripped.include?("unique: true")
            idx_name = stripped.match(/name:\s*[:"']([^"'\s,]+)/)&.send(:[], 1)
            tables[current_table][:indexes] << { name: idx_name, columns: cols, unique: unique }.compact if cols.any?

          # t.type :name / t.type "name" (general column match inside create_table block)
          elsif current_table && (match = stripped.match(/t\.(\w+)\s+[:"'](\w+)/))
            col_type = match[1]
            col_name = match[2]
            next if %w[index check_constraint].include?(col_type)
            col = { name: col_name, type: col_type }
            col[:null] = false if stripped.include?("null: false")
            if (def_match = stripped.match(/default:\s*("[^"]*"|\d+(?:\.\d+)?|true|false)/))
              raw = def_match[1]
              col[:default] = raw.start_with?('"') ? raw[1..-2] : raw
            end
            col[:array] = true if stripped.include?("array: true")
            tables[current_table][:columns] << col

          # add_column :table, :column, :type
          elsif (match = stripped.match(/add_column\s+[:"'](\w+)['"']?,\s*[:"'](\w+)['"']?,\s*[:"'](\w+)/))
            table_name, col_name, col_type = match[1], match[2], match[3]
            if tables[table_name]
              tables[table_name][:columns].reject! { |c| c[:name] == col_name }
              col = { name: col_name, type: col_type }
              col[:null] = false if stripped.include?("null: false")
              if (def_match = stripped.match(/default:\s*("[^"]*"|\d+(?:\.\d+)?|true|false)/))
                raw = def_match[1]
                col[:default] = raw.start_with?('"') ? raw[1..-2] : raw
              end
              tables[table_name][:columns] << col
            end

          # remove_column :table, :column
          elsif (match = stripped.match(/remove_column\s+[:"'](\w+)['"']?,\s*[:"'](\w+)/))
            table_name, col_name = match[1], match[2]
            tables[table_name][:columns]&.reject! { |c| c[:name] == col_name } if tables[table_name]

          # rename_column :table, :old, :new
          elsif (match = stripped.match(/rename_column\s+[:"'](\w+)['"']?,\s*[:"'](\w+)['"']?,\s*[:"'](\w+)/))
            table_name, old_name, new_name = match[1], match[2], match[3]
            if tables[table_name]
              col = tables[table_name][:columns].find { |c| c[:name] == old_name }
              col[:name] = new_name if col
            end

          # change_column :table, :column, :new_type
          elsif (match = stripped.match(/change_column\s+[:"'](\w+)['"']?,\s*[:"'](\w+)['"']?,\s*[:"'](\w+)/))
            table_name, col_name, new_type = match[1], match[2], match[3]
            if tables[table_name]
              col = tables[table_name][:columns].find { |c| c[:name] == col_name }
              col[:type] = new_type if col
            end

          # rename_table :old, :new
          elsif (match = stripped.match(/rename_table\s+[:"'](\w+)['"']?,\s*[:"'](\w+)/))
            old_name, new_name = match[1], match[2]
            tables[new_name] = tables.delete(old_name) if tables[old_name]

          # drop_table :name
          elsif (match = stripped.match(/drop_table\s+[:"'](\w+)/))
            tables.delete(match[1])

          # add_reference / add_belongs_to :table, :ref
          elsif (match = stripped.match(/add_(?:reference|belongs_to)\s+[:"'](\w+)['"']?,\s*[:"'](\w+)/))
            table_name, ref_name = match[1], match[2]
            if tables[table_name]
              col_name = "#{ref_name}_id"
              tables[table_name][:columns].reject! { |c| c[:name] == col_name }
              col = { name: col_name, type: "bigint" }
              col[:null] = false if stripped.include?("null: false")
              tables[table_name][:columns] << col
            end

          # add_index :table, [:cols]
          elsif (match = stripped.match(/add_index\s+[:"'](\w+)['"']?,\s*\[([^\]]*)\]/))
            table_name = match[1]
            cols = match[2].scan(/[:"'](\w+)/).flatten
            unique = stripped.include?("unique: true")
            idx_name = stripped.match(/name:\s*[:"']([^"'\s,]+)/)&.send(:[], 1)
            tables[table_name][:indexes]&.push({ name: idx_name, columns: cols, unique: unique }.compact) if tables[table_name] && cols.any?

          # add_index :table, :single_col
          elsif (match = stripped.match(/add_index\s+[:"'](\w+)['"']?,\s*[:"'](\w+)/))
            table_name, col_name = match[1], match[2]
            unique = stripped.include?("unique: true")
            idx_name = stripped.match(/name:\s*[:"']([^"'\s,]+)/)&.send(:[], 1)
            tables[table_name][:indexes]&.push({ name: idx_name, columns: [ col_name ], unique: unique }.compact) if tables[table_name]

          # add_foreign_key :from, :to
          elsif (match = stripped.match(/add_foreign_key\s+[:"'](\w+)['"']?,\s*[:"'](\w+)/))
            from_table, to_table = match[1], match[2]
            col_match = stripped.match(/column:\s*[:"'](\w+)/)
            column = col_match ? col_match[1] : "#{to_table.chomp('s')}_id"
            if tables[from_table]
              tables[from_table][:foreign_keys] << { from_table: from_table, to_table: to_table, column: column, primary_key: "id" }
            end

          # add_timestamps :table
          elsif (match = stripped.match(/add_timestamps\s+[:"'](\w+)/))
            table_name = match[1]
            if tables[table_name]
              tables[table_name][:columns] << { name: "created_at", type: "datetime", null: false }
              tables[table_name][:columns] << { name: "updated_at", type: "datetime", null: false }
            end
          end
        end
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
