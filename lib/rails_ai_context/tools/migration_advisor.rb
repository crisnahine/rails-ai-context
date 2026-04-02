# frozen_string_literal: true

module RailsAiContext
  module Tools
    class MigrationAdvisor < BaseTool
      tool_name "rails_migration_advisor"
      description "Generates migration code for schema changes. Given an action (add_column, " \
        "remove_column, rename_column, add_index, add_association, change_type), generates " \
        "the migration, flags irreversible operations, and shows affected models. " \
        "Use when: adding fields, changing schema, planning database changes. " \
        "Key params: action, table, column, type, new_name (for rename_column)."

      input_schema(
        properties: {
          action: {
            type: "string",
            enum: %w[add_column remove_column rename_column add_index add_association change_type create_table],
            description: "Migration action to perform"
          },
          table: {
            type: "string",
            description: "Table name (e.g., 'users', 'posts')"
          },
          column: {
            type: "string",
            description: "Column name (e.g., 'email', 'status')"
          },
          type: {
            type: "string",
            description: "Column type (e.g., 'string', 'integer', 'boolean', 'references')"
          },
          new_name: {
            type: "string",
            description: "New column name — only for rename_column action (e.g., 'full_name')"
          },
          options: {
            type: "string",
            description: "Additional options (e.g., 'null: false, default: 0')"
          }
        },
        required: %w[action table]
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      VALID_ACTIONS = %w[add_column remove_column rename_column add_index add_association change_type create_table].freeze

      def self.call(action: nil, table: nil, column: nil, type: nil, new_name: nil, options: nil, server_context: nil)
        action = action.to_s.strip
        table = table.to_s.strip
        column = column.to_s.strip if column

        # Normalize model names to table names: "Cook" → "cooks", "BrandProfile" → "brand_profiles"
        table = table.underscore.pluralize if table.match?(/\A[A-Z]/)

        return text_response("**Error:** `action` is required. Valid actions: #{VALID_ACTIONS.join(', ')}") if action.empty?
        return text_response("**Error:** `table` is required (e.g., 'users', 'posts').") if table.empty?

        # Validate identifier characters to produce valid migration code
        unless table.match?(/\A[a-z_][a-z0-9_]*\z/)
          return text_response("**Error:** Invalid table name `#{table}`. Use lowercase letters, digits, and underscores only.")
        end
        # create_table uses column param as a comma-separated column:type definition string
        if action != "create_table" && column && !column.empty? && !column.match?(/\A[a-z_][a-z0-9_]*\z/)
          return text_response("**Error:** Invalid column name `#{column}`. Use lowercase letters, digits, and underscores only.")
        end

        unless VALID_ACTIONS.include?(action)
          suggestion = VALID_ACTIONS.find { |a| a.start_with?(action) || a.include?(action) }
          hint = suggestion ? " Did you mean `#{suggestion}`?" : ""
          return text_response("**Error:** Unknown action `#{action}`.#{hint} Valid actions: #{VALID_ACTIONS.join(', ')}")
        end

        schema = cached_context[:schema]
        models = cached_context[:models]

        lines = [ "# Migration Advisor", "" ]

        # Check if table exists
        table_exists = schema.is_a?(Hash) && !schema[:error] && schema[:tables]&.key?(table)

        case action
        when "add_column"
          lines.concat(generate_add_column(table, column, type, options, table_exists))
        when "remove_column"
          lines.concat(generate_remove_column(table, column, type, schema, models))
        when "rename_column"
          rename_to = new_name&.to_s&.strip
          rename_to = type if rename_to.nil? || rename_to.empty?
          lines.concat(generate_rename_column(table, column, rename_to))
        when "add_index"
          lines.concat(generate_add_index(table, column, options))
        when "add_association"
          lines.concat(generate_add_association(table, column, type, options))
        when "change_type"
          lines.concat(generate_change_type(table, column, type, options))
        when "create_table"
          lines.concat(generate_create_table(table, column, options))
        end

        # Show affected models
        lines.concat(show_affected_models(table, models))

        text_response(lines.join("\n"))
      end

      class << self
        private

        def migration_class_name(action, table, column = nil)
          preposition = action == "remove" ? "From" : "To"
          parts = [ action.camelize, column&.camelize, preposition, table.camelize ].compact
          parts.join
        end

        def generate_add_column(table, column, type, options, table_exists)
          return [ "**Error:** column name is required for add_column" ] unless column
          type ||= "string"

          lines = []
          unless table_exists
            lines << "**Warning:** Table `#{table}` not found in current schema. Migration will fail if table doesn't exist."
            lines << ""
          end

          if table_exists && column_exists?(table, column)
            lines << "**Warning:** Column `#{column}` already exists on `#{table}`. This migration will fail with `DuplicateColumn` error."
            lines << ""
          end

          opts = options ? ", #{options}" : ""
          class_name = migration_class_name("add", table, column)

          lines << "**Run:** `bin/rails generate migration #{class_name} #{column}:#{type}`"
          lines << ""
          lines << "```ruby"
          lines << "# rails generate migration #{class_name} #{column}:#{type}"
          lines << "class #{class_name} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def change"
          lines << "    add_column :#{table}, :#{column}, :#{type}#{opts}"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          lines << "**Reversible:** Yes"
          lines << "**Index needed?** #{column.end_with?("_id") ? "Yes — add `add_index :#{table}, :#{column}`" : "Depends on query patterns"}"
          lines
        end

        def generate_remove_column(table, column, type, schema, models)
          return [ "**Error:** column name is required for remove_column" ] unless column

          lines = []

          table_exists = schema.is_a?(Hash) && !schema[:error] && schema[:tables]&.key?(table)
          unless table_exists
            lines << "**Warning:** Table `#{table}` not found in current schema. This migration will fail."
            lines << ""
          end

          if table_exists && !column_exists?(table, column)
            lines << "**Warning:** Column `#{column}` does not exist on `#{table}`. This migration will fail with `ActiveRecord::StatementInvalid`."
            lines << ""
          end

          class_name = migration_class_name("remove", table, column)

          # Check if column is referenced
          col_type = find_column_type(table, column, schema) || type || "string"

          lines << "**Run:** `bin/rails generate migration #{class_name} #{column}:#{col_type}`"
          lines << ""
          lines << "**Warning:** `remove_column` is irreversible without specifying the column type."
          lines << ""
          lines << "```ruby"
          lines << "class #{class_name} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def change"
          lines << "    remove_column :#{table}, :#{column}, :#{col_type}"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          lines << "**Reversible:** Only if type is specified (included above)"
          lines << "**Data loss:** Yes — all data in this column will be permanently deleted"

          if column.end_with?("_id")
            lines << "**Foreign key:** This looks like a foreign key column. Check for `has_many`/`belongs_to` that reference it."
          end

          lines
        end

        def generate_rename_column(table, column, new_name)
          return [ "**Error:** column (old name) and type (new name) are required" ] unless column && new_name

          lines = []

          if !column_exists?(table, column)
            lines << "**Warning:** Column `#{column}` does not exist on `#{table}`. This migration will fail with `ActiveRecord::StatementInvalid`."
            lines << ""
          end

          lines << "```ruby"
          lines << "class Rename#{column.camelize}To#{new_name.camelize}In#{table.camelize} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def change"
          lines << "    rename_column :#{table}, :#{column}, :#{new_name}"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          lines << "**Reversible:** Yes"
          lines << "**Action required:** Update all code references from `:#{column}` to `:#{new_name}`"
          lines
        end

        def generate_add_index(table, column, options)
          return [ "**Error:** column name is required for add_index" ] unless column

          lines = []

          if !column_exists?(table, column)
            lines << "**Warning:** Column `#{column}` does not exist on `#{table}`. This migration will fail with `PG::UndefinedColumn`."
            lines << ""
          end

          existing = index_exists?(table, column)
          if existing
            lines << "**Warning:** An index on `#{table}.#{column}` already exists. This migration will fail with `DuplicateIndex` error."
            lines << ""
          end

          opts = options ? ", #{options}" : ""

          lines << "```ruby"
          lines << "class AddIndexTo#{table.camelize}On#{column.camelize} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def change"
          lines << "    add_index :#{table}, :#{column}#{opts}"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          lines << "**Reversible:** Yes"
          lines << "**Note:** For large tables, consider `algorithm: :concurrently` (PostgreSQL) to avoid locking"
          lines
        end

        def generate_add_association(table, column, type, options)
          foreign_table = column || type
          return [ "**Error:** Specify the associated table in column param (e.g., column: 'users')" ] unless foreign_table

          lines = []
          fk_column = "#{foreign_table.singularize}_id"
          if column_exists?(table, fk_column)
            lines << "**Warning:** Column `#{fk_column}` already exists on `#{table}`. This migration will fail. Use `add_index` if you only need an index."
            lines << ""
          end

          lines << "```ruby"
          lines << "class Add#{foreign_table.camelize}To#{table.camelize} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def change"
          lines << "    add_reference :#{table}, :#{foreign_table.singularize}, foreign_key: true"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          lines << "**Reversible:** Yes"
          lines << "**Also add to models:**"
          lines << "```ruby"
          lines << "# app/models/#{table.singularize}.rb"
          lines << "belongs_to :#{foreign_table.singularize}"
          lines << ""
          lines << "# app/models/#{foreign_table.singularize}.rb"
          lines << "has_many :#{table}, dependent: :destroy"
          lines << "```"
          lines
        end

        def generate_change_type(table, column, type, options)
          return [ "**Error:** column and type are required" ] unless column && type

          lines = []

          if !column_exists?(table, column)
            lines << "**Warning:** Column `#{column}` does not exist on `#{table}`. This migration will fail with `ActiveRecord::StatementInvalid`."
            lines << ""
          end

          opts = options ? ", #{options}" : ""

          # Detect original column type from schema for a reversible down method
          original_type = find_column_type(table, column, cached_context[:schema]) || "string"

          lines << "**Warning:** Changing column type may cause data loss if types are incompatible."
          lines << ""
          lines << "```ruby"
          lines << "class Change#{column.camelize}TypeIn#{table.camelize} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def up"
          lines << "    change_column :#{table}, :#{column}, :#{type}#{opts}"
          lines << "  end"
          lines << ""
          lines << "  def down"
          lines << "    change_column :#{table}, :#{column}, :#{original_type}"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          lines << "**Reversible:** No (requires explicit `down` method with original type)"
          lines
        end

        def generate_create_table(table, columns_str, options)
          lines = []
          lines << "```ruby"
          lines << "class Create#{table.camelize} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def change"
          lines << "    create_table :#{table} do |t|"

          if columns_str
            columns_str.split(",").each do |col|
              parts = col.strip.split(":")
              name = parts[0]&.strip
              type = parts[1]&.strip || "string"
              if type == "references"
                lines << "      t.references :#{name}, foreign_key: true"
              else
                lines << "      t.#{type} :#{name}"
              end
            end
          end

          lines << "      t.timestamps"
          lines << "    end"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          lines << "**Reversible:** Yes"
          lines
        end

        def show_affected_models(table, models)
          lines = [ "", "## Affected Models", "" ]

          return lines unless models.is_a?(Hash) && !models[:error]

          model_name = table.singularize.camelize
          if models.key?(model_name.to_sym) || models.key?(model_name)
            lines << "- **#{model_name}** — directly affected (table: #{table})"
          end

          # Find models with associations pointing to this table
          models.each do |name, data|
            next unless data.is_a?(Hash)
            assocs = data[:associations] || []
            related = assocs.select { |a|
              a[:class_name]&.underscore&.pluralize == table ||
              a[:name]&.to_s&.pluralize == table ||
              a[:name]&.to_s&.singularize == table.singularize
            }
            related.each do |a|
              lines << "- **#{name}** — #{a[:macro] || a[:type]} :#{a[:name]}"
            end
          end

          lines
        end

        def column_exists?(table, column)
          schema = cached_context[:schema]
          return false unless schema.is_a?(Hash) && schema[:tables]

          table_data = schema[:tables][table]
          return false unless table_data

          col_str = column.to_s
          (table_data[:columns] || []).any? { |c| c[:name].to_s == col_str }
        end

        def index_exists?(table, column)
          schema = cached_context[:schema]
          return false unless schema.is_a?(Hash) && schema[:tables]

          table_data = schema[:tables][table]
          return false unless table_data

          (table_data[:indexes] || []).any? { |idx|
            cols = idx[:columns] || [ idx[:column] ].compact
            cols.map(&:to_s).include?(column.to_s)
          }
        end

        def find_column_type(table, column, schema)
          return nil unless schema.is_a?(Hash) && schema[:tables]

          table_data = schema[:tables][table]
          return nil unless table_data

          col = (table_data[:columns] || []).find { |c| c[:name] == column }
          col[:type] if col
        end

        def rails_version
          Rails.version.split(".").first(2).join(".")
        rescue => e
          $stderr.puts "[rails-ai-context] rails_version failed: #{e.message}" if ENV["DEBUG"]
          "7.1"
        end
      end
    end
  end
end
