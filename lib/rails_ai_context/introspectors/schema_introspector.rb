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

        schema_content = File.exist?(schema_file_path) ? (RailsAiContext::SafeFile.read(schema_file_path, max_size: RailsAiContext.configuration.max_schema_file_size) || "") : ""

        check_constraints = []
        enum_types = []
        if File.exist?(schema_file_path) && defined?(Listeners::SchemaDslListener)
          ast_results = SourceIntrospector.walk(schema_file_path, { schema: -> { Listeners::SchemaDslListener.new } })
          schema_results = ast_results[:schema]

          current_table = nil
          schema_results.sort_by { |r| r[:location] }.each do |entry|
            case entry[:type]
            when :create_table then current_table = entry[:table]
            when :check_constraint
              check_constraints << { table: current_table, expression: entry[:expression] } if current_table
            when :add_check_constraint
              check_constraints << { table: entry[:table], expression: entry[:expression] }
            when :enum
              enum_types << { name: entry[:name], values: entry[:values] }
            end
          end
        end

        {
          adapter: adapter_name,
          tables: extract_tables,
          total_tables: table_names.size,
          schema_version: current_schema_version,
          check_constraints: check_constraints,
          enum_types: enum_types,
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

        @schema_rb_content ||= RailsAiContext::SafeFile.read(schema_file_path, max_size: RailsAiContext.configuration.max_schema_file_size)
        return {} unless @schema_rb_content
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
          content = RailsAiContext::SafeFile.read(schema_file_path, max_size: RailsAiContext.configuration.max_schema_file_size)
          return nil unless content
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
        schema_rb_exists = File.exist?(schema_file_path)

        if schema_rb_exists
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

        # schema.rb exists but has no tables — happens on fresh Rails apps right
        # after `db:create` where no migrations have been run yet. Return a
        # legitimate empty-schema state instead of a misleading "not found" error.
        if schema_rb_exists
          return {
            total_tables: 0,
            tables: {},
            note: "Schema file exists but is empty — no migrations have been run yet. " \
                  "Run `bin/rails db:migrate` after generating migrations to populate schema.rb."
          }
        end

        { error: "No db/schema.rb, db/structure.sql, or migrations found" }
      end

      def parse_schema_rb(path)
        content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
        return { error: "schema.rb too large (#{File.size(path)} bytes)" } unless content

        ast_data = SourceIntrospector.walk(path, { schema: -> { Listeners::SchemaDslListener.new } })
        results = ast_data[:schema].sort_by { |r| r[:location] }

        tables = {}
        current_table = nil

        results.each do |entry|
          case entry[:type]
          when :create_table
            table_name = entry[:table]
            if table_name.start_with?("ar_internal_metadata", "schema_migrations")
              current_table = nil
            else
              current_table = table_name
              tables[current_table] = { columns: [], indexes: [], foreign_keys: [] }
            end
          when :column
            next unless current_table && tables[current_table]
            col = { name: entry[:name], type: entry[:column_type] }
            opts = entry[:options] || {}
            col[:null] = false if opts[:null] == false
            unless opts[:default].nil? || opts[:default] == RailsAiContext::Confidence::INFERRED
              raw = opts[:default]
              col[:default] = raw.is_a?(String) ? raw : raw.to_s
            end
            col[:array] = true if opts[:array] == true
            col[:comment] = opts[:comment] if opts[:comment].is_a?(String)
            tables[current_table][:columns] << col
          when :index
            next unless current_table && tables[current_table]
            cols = entry[:columns].map(&:to_s)
            opts = entry[:options] || {}
            unique = opts[:unique] == true
            idx_name = opts[:name]&.to_s
            if cols.size == 1 && !cols.first.match?(/\A\w+\z/)
              # Expression index (e.g. "lower(email)")
              tables[current_table][:indexes] << { name: idx_name, columns: cols, unique: unique, expression: true }.compact
            else
              tables[current_table][:indexes] << { name: idx_name, columns: cols, unique: unique }.compact if cols.any?
            end
          when :foreign_key
            from_table = entry[:from]
            to_table = entry[:to]
            # SchemaDslListener doesn't capture column/primary_key options for
            # add_foreign_key; fall back to convention.
            column = "#{to_table.singularize}_id"
            tables[from_table]&.dig(:foreign_keys)&.push({
              from_table: from_table, to_table: to_table,
              column: column, primary_key: "id"
            })
          end
        end

        # Handle top-level add_index statements via AST (SchemaDslListener :add_index type)
        results.select { |r| r[:type] == :add_index }.each do |entry|
          table_name = entry[:table]
          cols = entry[:columns].map(&:to_s)
          opts = entry[:options] || {}
          unique = opts[:unique] == true
          idx_name = opts[:name]&.to_s
          tables[table_name]&.dig(:indexes)&.push({ name: idx_name, columns: cols, unique: unique }.compact) if cols.any?
        end

        # Extract check constraints via AST
        check_constraints = extract_check_constraints_from_ast(results, tables)

        # Extract enum types via AST (SchemaDslListener :enum type)
        enum_types = results.select { |r| r[:type] == :enum }.map do |entry|
          { name: entry[:name], values: entry[:values] }
        end

        {
          adapter: "static_parse",
          tables: tables,
          total_tables: tables.size,
          schema_version: current_schema_version,
          check_constraints: check_constraints,
          enum_types: enum_types,
          generated_columns: parse_generated_columns(content),
          note: "Parsed from db/schema.rb (no DB connection)"
        }
      end

      def parse_structure_sql(path) # rubocop:disable Metrics/MethodLength
        content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
        return { error: "structure.sql too large (#{File.size(path)} bytes)" } unless content
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

      # Extract check constraints from AST results (SchemaDslListener).
      # Handles both t.check_constraint (inside create_table) and
      # top-level add_check_constraint.
      def extract_check_constraints_from_ast(ast_results, tables)
        constraints = []
        current_table = nil

        ast_results.sort_by { |r| r[:location] }.each do |entry|
          case entry[:type]
          when :create_table
            current_table = entry[:table]
          when :check_constraint
            constraints << { table: current_table, expression: entry[:expression] } if current_table
          when :add_check_constraint
            constraints << { table: entry[:table], expression: entry[:expression] }
          end
        end

        constraints
      rescue => e
        $stderr.puts "[rails-ai-context] extract_check_constraints_from_ast failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Extract generated/virtual columns from AST results (SchemaDslListener).
      # Detects columns with virtual: true or stored: true options.
      def parse_generated_columns(content)
        return [] if content.nil? || content.empty?

        # Parse with SchemaDslListener if not already done
        path = schema_file_path
        return [] unless File.exist?(path)

        ast_results = SourceIntrospector.walk(path, { schema: -> { Listeners::SchemaDslListener.new } })
        results = ast_results[:schema].sort_by { |r| r[:location] }

        columns = []
        current_table = nil

        results.each do |entry|
          case entry[:type]
          when :create_table
            current_table = entry[:table]
          when :column
            next unless current_table
            opts = entry[:options] || {}
            if opts[:virtual] == true || opts[:stored] == true
              stored = opts[:stored] == true
              columns << { table: current_table, column: entry[:name], stored: stored }
            end
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
          content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size) or next
          replay_migration(content, tables)
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

      def replay_migration(content, tables)
        ast_data = SourceIntrospector.walk_source(content, {
          migration: -> { Listeners::MigrationDslListener.new },
          schema: -> { Listeners::SchemaDslListener.new }
        })

        current_table = nil
        all_entries = (ast_data[:migration] + ast_data[:schema]).sort_by { |r| r[:location] }

        # Also detect t.timestamps via direct AST walk (SchemaDslListener skips it
        # because timestamps has no column name arg)
        timestamps_lines = Set.new
        find_timestamps_calls(AstCache.parse_string(content).value, timestamps_lines)

        all_entries.each do |entry|
          # MigrationDslListener entries
          if entry.key?(:action)
            if entry[:action] == :create_table
              current_table = entry[:table]
            elsif entry[:action] == :drop_table || entry[:action] == :rename_table
              current_table = nil
            end
            apply_migration_action(entry, tables)
          # SchemaDslListener entries (columns, indexes inside create_table blocks)
          elsif entry[:type] == :create_table
            current_table = entry[:table]
            tables[current_table] ||= { columns: [], indexes: [], foreign_keys: [] }
          elsif entry[:type] == :column && current_table
            apply_schema_column(entry, current_table, tables)
          elsif entry[:type] == :index && current_table
            apply_schema_index(entry, current_table, tables)
          end
        end

        # Apply timestamps where detected
        timestamps_lines.each do |line_num|
          # Find the enclosing create_table by checking which table's location range includes this line
          table_for_line = nil
          all_entries.select { |e| (e.key?(:action) && e[:action] == :create_table) || e[:type] == :create_table }
            .each do |ct|
              table_for_line = ct[:table] if ct[:location] < line_num
            end
          if table_for_line && tables[table_for_line]
            tables[table_for_line][:columns] << { name: "created_at", type: "datetime", null: false }
            tables[table_for_line][:columns] << { name: "updated_at", type: "datetime", null: false }
          end
        end
      end

      # Walk AST to find t.timestamps calls (not captured by SchemaDslListener).
      def find_timestamps_calls(node, lines)
        case node
        when Prism::CallNode
          if node.name == :timestamps && node.receiver
            receiver = node.receiver
            is_t = case receiver
            when Prism::LocalVariableReadNode then receiver.name == :t
            when Prism::CallNode then receiver.name == :t && receiver.receiver.nil?
            else false
            end
            lines << node.location.start_line if is_t
          end
        end
        node.child_nodes.compact.each { |child| find_timestamps_calls(child, lines) }
      end

      def apply_migration_action(entry, tables)
        case entry[:action]
        when :create_table
          table = entry[:table]
          tables[table] ||= { columns: [], indexes: [], foreign_keys: [] }

        when :drop_table
          tables.delete(entry[:table])

        when :rename_table
          old = entry[:table]
          new_name = entry[:new_name]
          tables[new_name] = tables.delete(old) if old && new_name && tables[old]

        when :add_column
          table = entry[:table]
          return unless tables[table]
          col_name = entry[:column]
          col_type = entry[:column_type]
          tables[table][:columns].reject! { |c| c[:name] == col_name }
          col = { name: col_name, type: col_type }
          opts = entry[:options] || {}
          col[:null] = false if opts[:null] == false
          col[:default] = format_default(opts[:default]) if opts.key?(:default)
          tables[table][:columns] << col

        when :remove_column
          table = entry[:table]
          tables[table][:columns]&.reject! { |c| c[:name] == entry[:column] } if tables[table]

        when :rename_column
          table = entry[:table]
          if tables[table]
            col = tables[table][:columns].find { |c| c[:name] == entry[:column] }
            col[:name] = entry[:new_name] if col
          end

        when :change_column
          table = entry[:table]
          if tables[table]
            col = tables[table][:columns].find { |c| c[:name] == entry[:column] }
            col[:type] = entry[:column_type] if col && entry[:column_type]
          end

        when :change_column_default
          table = entry[:table]
          if tables[table]
            col = tables[table][:columns].find { |c| c[:name] == entry[:column] }
            if col
              opts = entry[:options] || {}
              if opts.key?(:to)
                raw = opts[:to]
                col[:default] = raw == nil ? nil : format_default(raw)
              end
            end
          end

        when :change_column_null
          table = entry[:table]
          if tables[table]
            col = tables[table][:columns].find { |c| c[:name] == entry[:column] }
            if col
              opts = entry[:options] || {}
              # The third positional arg is the nullable boolean
              args = [ entry[:table], entry[:column] ]
              # MigrationDslListener puts the nullable value in options or we check the raw AST
              # For change_column_null, the third arg is a boolean (true/false)
              # It's captured in options by MigrationDslListener if passed as keyword
              # but it's typically a positional arg. Fall back to source inspection.
            end
          end

        when :add_index
          table = entry[:table]
          return unless tables[table]
          cols = entry[:columns]&.map(&:to_s) || []
          opts = entry[:options] || {}
          unique = opts[:unique] == true
          idx_name = opts[:name]&.to_s
          tables[table][:indexes] << { name: idx_name, columns: cols, unique: unique }.compact if cols.any?

        when :add_reference, :add_belongs_to
          table = entry[:table]
          return unless tables[table]
          ref_name = entry[:ref]
          col_name = "#{ref_name}_id"
          tables[table][:columns].reject! { |c| c[:name] == col_name }
          col = { name: col_name, type: "bigint" }
          opts = entry[:options] || {}
          col[:null] = false if opts[:null] == false
          tables[table][:columns] << col

        when :add_foreign_key
          from = entry[:table]
          to = entry[:to_table]
          return unless tables[from]
          opts = entry[:options] || {}
          column = opts[:column]&.to_s || "#{to&.to_s&.chomp('s')}_id"
          tables[from][:foreign_keys] << { from_table: from, to_table: to, column: column, primary_key: "id" }
        end
      end

      def apply_schema_column(entry, current_table, tables)
        return unless tables[current_table]
        col_type = entry[:column_type]

        # Handle references/belongs_to
        if %w[references belongs_to].include?(col_type)
          ref_name = entry[:name]
          col = { name: "#{ref_name}_id", type: "bigint" }
          opts = entry[:options] || {}
          col[:null] = false if opts[:null] == false
          tables[current_table][:columns] << col
          return
        end

        # Handle timestamps
        if col_type == "timestamps"
          tables[current_table][:columns] << { name: "created_at", type: "datetime", null: false }
          tables[current_table][:columns] << { name: "updated_at", type: "datetime", null: false }
          return
        end

        # Skip non-column types
        return if %w[index check_constraint].include?(col_type)

        col = { name: entry[:name], type: col_type }
        opts = entry[:options] || {}
        col[:null] = false if opts[:null] == false
        col[:default] = format_default(opts[:default]) if opts.key?(:default) && opts[:default] != RailsAiContext::Confidence::INFERRED
        col[:array] = true if opts[:array] == true
        tables[current_table][:columns] << col
      end

      def apply_schema_index(entry, current_table, tables)
        return unless tables[current_table]
        cols = entry[:columns]&.map(&:to_s) || []
        opts = entry[:options] || {}
        unique = opts[:unique] == true
        idx_name = opts[:name]&.to_s
        tables[current_table][:indexes] << { name: idx_name, columns: cols, unique: unique }.compact if cols.any?
      end

      def format_default(value)
        case value
        when String then value
        when Integer, Float then value.to_s
        when TrueClass, FalseClass then value.to_s
        when NilClass then nil
        else value.to_s
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
