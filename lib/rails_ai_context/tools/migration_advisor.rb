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
            description: "Column name (e.g., 'email', 'status'). For add_association, the reference (e.g., 'user', 'parent')."
          },
          type: {
            type: "string",
            description: "Column type (e.g., 'string', 'integer', 'boolean', 'references'). " \
                         "For add_association with column, the table the reference points at (e.g., 'users')."
          },
          new_name: {
            type: "string",
            description: "New column name - only for rename_column action (e.g., 'full_name')"
          },
          options: {
            type: "string",
            description: "Additional options (e.g., 'null: false, default: 0')"
          }
        },
        required: %w[action table]
      )

      guide_row(
        order: 25,
        mcp: "rails_migration_advisor(action:\"X\", table:\"Y\")",
        cli_args: "action=X table=Y",
        summary: "Generate migration code, flag irreversible ops"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      VALID_ACTIONS = %w[add_column remove_column rename_column add_index add_association change_type create_table].freeze

      # Stamped on generated migrations when neither the app's context nor a
      # loaded Rails names a version. The bracket selects a compatibility
      # mode, so the tool says so in its output when it falls back here.
      SUPPORTED_RAILS_FLOOR = "7.0"

      # Room for every option a column takes, a long `comment:` included.
      MAX_OPTIONS_LENGTH = 1_024

      def self.call(action: nil, table: nil, column: nil, type: nil, new_name: nil, options: nil, server_context: nil)
        action = action.to_s.strip
        table = table.to_s.strip
        column = column.to_s.strip.presence if column
        # A reference is a column plus its index and key, which add_column cannot write.
        action, type = "add_association", nil if action == "add_column" && %w[references belongs_to].include?(type.to_s.strip)

        # No database takes a name this long (PostgreSQL stops at 63 bytes,
        # MySQL at 64), and the generated code would carry it whole.
        names = { "table" => table, "type" => type, "new_name" => new_name }
        names["column"] = column unless action == "create_table"
        long_name = names.find { |_, value| name_too_long?(value) }
        if long_name || options.to_s.length > MAX_OPTIONS_LENGTH
          param, value = long_name || [ "options", options ]
          return text_response("**Error:** `#{param}` #{echo_input(value)} is longer than any migration takes.")
        end

        # Normalize model names to table names: "Post" → "posts", and
        # "Admin::ActionLog" → the table its model recorded, not the
        # `admin/action_logs` an underscore would build.
        if table.match?(/\A[A-Z]/)
          table = RailsAiContext::Introspectors::TableName.for_model_name(table, Payload.models(cached_context))
        end

        return text_response("**Error:** `action` is required. Valid actions: #{VALID_ACTIONS.join(', ')}") if action.empty?
        return text_response("**Error:** `table` is required (e.g., 'users', 'posts').") if table.empty?

        # Validate identifier characters to produce valid migration code
        unless table.match?(/\A[a-z_][a-z0-9_]*\z/)
          return text_response("**Error:** Invalid table name `#{echo_input(table)}`. Use lowercase letters, digits, and underscores only.")
        end
        rename_to = new_name.to_s.strip.presence || type.to_s.strip.presence if action == "rename_column"
        # create_table's column param is a comma-separated list of name:type definitions.
        written = action == "create_table" ? column.to_s.split(",").map { |definition| definition.split(":").first.to_s.strip } : [ column, rename_to ]
        if (invalid = written.compact.find { |name| !name.match?(/\A[a-z_][a-z0-9_]*\z/) })
          return text_response("**Error:** Invalid column name `#{echo_input(invalid)}`. Use lowercase letters, digits, and underscores only.")
        end

        unless VALID_ACTIONS.include?(action)
          suggestion = VALID_ACTIONS.find { |a| a.start_with?(action) || a.include?(action) }
          hint = suggestion ? " Did you mean `#{suggestion}`?" : ""
          return text_response("**Error:** Unknown action `#{echo_input(action)}`.#{hint} Valid actions: #{VALID_ACTIONS.join(', ')}")
        end

        schema = Payload.section(cached_context, :schema)
        models = Payload.models(cached_context)

        lines = [ "# Migration Advisor", "" ]

        if rails_version_unknown?
          lines << "**Note:** Could not determine this app's Rails version. " \
            "The migration below is stamped with #{SUPPORTED_RAILS_FLOOR}; check that against your app."
          lines << ""
        end

        databases = RailsAiContext::Payload.schema_databases(schema, table)
        table_exists = databases.any?
        database_lines, target = database_option(table, databases)
        lines.concat(database_lines)

        if (unknown = unknown_type(action, column, type))
          return text_response((lines + [ unknown ]).join("\n"))
        end
        # What the app's migrations already hold: a file the generator's name
        # collides with, and a pending one that makes the same change.
        prior = prior_migration_lines(action, table, column, rename_to, type, migration_files_for(target), pending_versions(schema, table, databases))
        lines.concat(prior)
        # The generator refuses a name another migration has, so its command is not offered.
        target = false if prior.any? { |line| line.start_with?("**Warning:** Another migration is already named") }

        generated = case action
        when "add_column" then generate_add_column(table, column, type, options, table_exists, target)
        when "remove_column" then generate_remove_column(table, column, type, schema, models, target)
        when "rename_column" then generate_rename_column(table, column, rename_to)
        when "add_index" then generate_add_index(table, column, options)
        when "add_association" then generate_add_association(table, column, type, options, schema)
        when "change_type" then generate_change_type(table, column, type, options)
        when "create_table" then generate_create_table(table, column, options, table_exists)
        end
        lines.concat(generated)
        # A missing param writes no migration, so nothing below applies to one.
        return text_response(lines.join("\n")) if generated.first.to_s.start_with?("**Error:**")

        # Show affected models
        lines.concat(show_affected_models(table, models, action: action, column: column))
        # A column change breaks the code that reads the column, which no
        # association names: that code is what the reader has to update.
        lines.concat(column_mention_lines(column)) if %w[remove_column rename_column change_type].include?(action) && column

        # Strong Migrations warnings (only when the gem is present in the project).
        lines.concat(strong_migrations_warnings(action, table, column, options)) if strong_migrations_gem_present?

        text_response(lines.join("\n"))
      end

      class << self
        private

        def migration_class_name(action, table, column = nil)
          preposition = action == "remove" ? "From" : "To"
          parts = [ action.camelize, column&.camelize, preposition, table.camelize ].compact
          parts.join
        end

        # The class each action's migration is named, which the generator
        # turns into its file name; nil when a needed param is missing.
        def migration_name(action, table, column, rename_to, type)
          case action
          when "add_column" then column && migration_class_name("add", table, column)
          when "remove_column" then column && migration_class_name("remove", table, column)
          when "rename_column" then column && rename_to && "Rename#{column.camelize}To#{rename_to.camelize}In#{table.camelize}"
          when "add_index" then column && "AddIndexTo#{table.camelize}On#{column.camelize}"
          when "add_association" then (reference = column || type) && "Add#{reference.camelize}To#{table.camelize}"
          when "change_type" then column && "Change#{column.camelize}TypeIn#{table.camelize}"
          when "create_table" then "Create#{table.camelize}"
          end
        end

        # The migration files of the database the migration goes to; none when
        # there is no app root to read them from.
        def migration_files_for(target)
          root = rails_app.root.to_s
          dirs = target.is_a?(Hash) && target[:dirs] ? target[:dirs] : RailsAiContext::PendingMigrations.migrate_dirs_for(root)
          RailsAiContext::PendingMigrations.migration_files(dirs, root: root)
        rescue StandardError => e
          RailsAiContext.debug_fail(e, [], label: "migration_files_for")
        end

        # The versions not yet run on that database; nil when unknown.
        def pending_versions(schema, table, databases)
          pending = if on_primary?(table)
            schema&.dig(:pending_migrations)
          else
            schema&.dig(:secondary_databases, databases.first, :pending_migrations)
          end
          pending.is_a?(Array) ? pending.map { |m| m[:version].to_s } : nil
        end

        # A file already named what the generator would name this one, and a
        # pending migration that already makes this change. Rails' generator
        # stops with "Another migration is already named ..." on the first;
        # the second means the change is written and only waits to run.
        def prior_migration_lines(action, table, column, rename_to, type, files, pending)
          lines = []
          name = migration_name(action, table, column, rename_to, type)
          if name && (clash = files.find { |m| migration_file_name(m[:path]) == name.underscore })
            waiting = pending&.include?(clash[:version].to_s)
            lines << "**Warning:** Another migration is already named `#{name.underscore}` " \
                     "(`#{RailsAiContext::PortablePath.relativize(clash[:path], rails_app.root.to_s)}`#{", not yet run" if waiting}), " \
                     "so `bin/rails generate migration #{name}` stops with \"Another migration is already named #{name.underscore}\". " \
                     "#{waiting ? "Edit that migration before it runs, or give this one another name." : "Give this one another name."}"
            lines << ""
          end

          changes = pending_changes(files, pending)
          wanted = case action
          when "add_column" then [ table, column ]
          when "add_association" then [ table, "#{(column || type).to_s.singularize}_id" ]
          when "create_table" then [ table, nil ]
          end
          if wanted && (found = changes.find { |c| c[:table] == wanted.first && c[:column] == wanted.last })
            what = wanted.last ? "adds `#{wanted.last}`#{" (#{found[:type]})" if found[:type]} to `#{table}`" : "creates `#{table}`"
            lines << "**Warning:** Pending migration `#{found[:version]} #{found[:name]}` already #{what}: " \
                     "run `bin/rails db:migrate` rather than generating another, or change that migration before it runs."
            lines << ""
          end
          lines
        end

        def migration_file_name(path)
          File.basename(path, ".rb").sub(/\A\d+_/, "").split(".", 2).first
        end

        # [{ table:, column:, type:, version:, name: }] for each column a pending
        # migration adds, and each table it creates (column nil).
        def pending_changes(files, pending)
          return [] unless pending

          files.select { |m| pending.include?(m[:version].to_s) }.flat_map do |m|
            source = RailsAiContext::SafeFile.read(m[:path]) or next []
            changes = []
            collect_changes(RailsAiContext::AstCache.parse_string(source).value, nil, changes)
            changes.map { |change| change.merge(version: m[:version], name: m[:name]) }
          end
        rescue => e
          RailsAiContext.debug_fail(e, [], label: "pending_changes")
        end

        TABLE_BLOCKS = %i[create_table change_table].freeze

        # What a migration does when it runs, not what it takes back on a
        # rollback: `def down`, a reversible's `dir.down` and a `revert`
        # block hold the undo.
        def undo?(node)
          return node.name == :down if node.is_a?(Prism::DefNode)
          return false unless node.is_a?(Prism::CallNode) && node.block

          node.receiver ? node.name == :down : node.name == :revert
        end

        def collect_changes(node, block_table, changes)
          return unless node.is_a?(Prism::Node)
          return if undo?(node)

          if node.is_a?(Prism::CallNode)
            args = Array(node.arguments&.arguments)
            literal = ->(arg) { arg.unescaped.to_s if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode) }
            if node.receiver.nil? && %i[add_column add_reference add_belongs_to].include?(node.name) && literal.(args[0]) && literal.(args[1])
              column = node.name == :add_column ? literal.(args[1]) : "#{literal.(args[1])}_id"
              changes << { table: literal.(args[0]), column: column, type: (literal.(args[2]) if node.name == :add_column) }
            elsif node.receiver.nil? && TABLE_BLOCKS.include?(node.name) && literal.(args[0])
              changes << { table: literal.(args[0]), column: nil } if node.name == :create_table
              return collect_changes(node.block, literal.(args[0]), changes)
            elsif block_table && node.receiver.is_a?(Prism::LocalVariableReadNode) && literal.(args[0])
              case node.name
              when :references, :belongs_to then changes << { table: block_table, column: "#{literal.(args[0])}_id" }
              when :column then changes << { table: block_table, column: literal.(args[0]), type: literal.(args[1]) }
              when :index, :remove, :rename, :change, :change_default, :change_null, :remove_references, :remove_belongs_to, :timestamps then nil
              else changes << { table: block_table, column: literal.(args[0]), type: node.name.to_s }
              end
            end
          end
          node.compact_child_nodes.each { |child| collect_changes(child, block_table, changes) }
        end

        # Migration column types: Rails' own, the adapters', and the
        # connection's when the app is booted.
        COLUMN_TYPES = %w[
          string text integer bigint float decimal numeric datetime timestamp time date binary blob boolean
          json virtual primary_key references belongs_to
          jsonb uuid inet cidr macaddr hstore citext ltree tsvector tsquery money point line lseg box path polygon
          circle bit bit_varying xml interval oid enum timestamptz int4range int8range numrange tsrange tstzrange daterange
          tinytext mediumtext longtext tinyblob mediumblob longblob unsigned_integer unsigned_bigint
          unsigned_float unsigned_decimal set year
        ].freeze

        def column_types
          types = COLUMN_TYPES.dup
          if defined?(ActiveRecord::Base) && !RailsAiContext.static_tier?
            types |= ActiveRecord::Base.connection.native_database_types.keys.map(&:to_s)
          end
          types
        rescue StandardError
          COLUMN_TYPES
        end

        # A create_table column's name, type and index modifier as GeneratedAttribute.parse reads them:
        # `title:index` is an indexed string.
        def column_definition(definition)
          name, type, *modifier = definition.strip.split(":").map(&:strip)
          modifier = modifier.join(":").presence
          modifier, type = type, nil if %w[index uniq].include?(type)
          [ name, type.presence || "string", modifier ]
        end

        # A type no adapter knows writes a migration that fails when it runs.
        def unknown_type(action, column, type)
          written = case action
          when "add_column", "change_type" then [ type ]
          when "create_table" then column.to_s.split(",").map { |definition| column_definition(definition)[1] }
          end
          bad = Array(written).compact.reject(&:empty?).find { |t| !column_types.include?(t) }
          return nil unless bad

          suggestion = find_closest_match(bad, column_types)
          "**Error:** Unknown column type `#{echo_input(bad)}`.#{" Did you mean `#{suggestion}`?" if suggestion} " \
            "Migration types include string, text, integer, bigint, decimal, boolean, date, datetime, json and references."
        end

        # A table only a secondary database holds needs its migration in that database's migrations_paths.
        # [lines, target]: target is nil for the primary, false when no environment configures the
        # database, else the generator's --database flag and the RAILS_ENV that configures it.
        def database_option(table, databases)
          return [ [], nil ] if on_primary?(table)

          root = rails_app.root
          listed = RailsAiContext::AppDatabases.for(root)
          found = databases.filter_map do |name|
            db = listed[name]
            [ name, [ (db.environments unless db.here), db.settings ] ] if db&.config
          end.to_h
          if found.empty?
            note = "**Database:** `#{table}` is in the #{databases.join(", ")} dump, which no environment in config/database.yml configures: " \
                   "no `--database` reaches it, and a migration generated here runs on the primary."
            return [ [ note, "" ], false ]
          end

          names = found.keys
          elsewhere = found.values.first.first
          env_name = elsewhere&.first
          configuring = "#{RailsAiContext::AppDatabases.environment_phrase(elsewhere)} #{elsewhere.one? ? "configures" : "configure"}" if elsewhere
          configured = Array(found.values.first.last["migrations_paths"])
          dirs = configured.any? ? configured.map { |path| File.expand_path(path, root.to_s) } : [ File.join(root.to_s, "db", "#{names.first}_migrate") ]
          target = { flag: " --database #{names.first}", env: env_name, dirs: dirs }
          paths = configured.join(", ")
          note = "**Database:** `#{table}` is in #{[ names[0..-2].join(", "), names.last ].reject(&:empty?).join(" and ")}" \
                 "#{", which #{configuring} and this environment does not" if env_name}: generate with #{"`RAILS_ENV=#{env_name}` and " if env_name}`#{target[:flag].strip}` " \
                 "so the migration lands in #{env_name && !paths.empty? ? paths : "that database's migrations_paths"} and " \
                 "#{"#{env_name}'s " if env_name}`bin/rails db:migrate` runs it there."
          groups = found.group_by { |_, (_, entry)| Array(entry["migrations_paths"]) }
          if groups.size > 1
            note += " Those databases read different migrations_paths, so generate it once per database: " \
                    "#{groups.values.map { |dbs| "`--database #{dbs.first.first}`" }.join(', ')}."
          end
          [ [ note, "" ], target ]
        end

        def generate_command(args, target)
          "#{"RAILS_ENV=#{target[:env]} " if target && target[:env]}bin/rails generate migration #{args}#{target && target[:flag]}"
        end

        def generate_add_column(table, column, type, options, table_exists, target = nil)
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

          if table_exists && options.to_s.match?(/\bnull:\s*false\b/) && !options.to_s.match?(/\bdefault:/)
            lines << not_null_warning(table, column)
            lines << ""
          end

          opts = options ? ", #{options}" : ""
          class_name = migration_class_name("add", table, column)

          command = generate_command("#{class_name} #{column}:#{type}", target) unless target == false
          lines.push("**Run:** `#{command}`", "") if command
          lines << "```ruby"
          lines << "# #{command.sub("bin/rails", "rails")}" if command
          lines << "class #{class_name} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def change"
          lines << "    add_column :#{table}, :#{column}, :#{type}#{opts}"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          lines << "**Reversible:** Yes"
          lines << "**Index needed?** #{column.end_with?("_id") ? "Yes - add `add_index :#{table}, :#{column}`" : "Depends on query patterns"}"
          lines
        end

        # NOT NULL with no default fails on a table that holds rows. The row count is the booted
        # primary's own estimate, so a table only another database holds has none.
        def not_null_warning(table, column)
          stats = (Array(Payload.section(cached_context, :database_stats)&.dig(:tables)).find { |t| t[:table].to_s == table } if on_primary?(table))
          rows = stats&.dig(:approximate_rows)
          held = if rows.nil? then "if `#{table}` holds any rows"
          elsif stats[:at_least] then "as `#{table}` holds at least #{count_phrase(rows, "row")}"
          else "as `#{table}` holds about #{count_phrase(rows, "row")}"
          end
          return "**Note:** `#{table}` is empty by the database's estimate, so `null: false` without a default runs; on a table with rows it fails." if rows&.zero?

          "**Warning:** `null: false` without a default fails #{held}: add a `default:`, or add `#{column}` nullable, " \
            "backfill it, then `change_column_null :#{table}, :#{column}, false`."
        end

        def generate_remove_column(table, column, type, schema, models, target = nil)
          return [ "**Error:** column name is required for remove_column" ] unless column

          lines = []

          table_exists = !RailsAiContext::Payload.schema_table(schema, table).nil?
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

          lines.push("**Run:** `#{generate_command("#{class_name} #{column}:#{col_type}", target)}`", "") unless target == false
          lines << "**Warning:** `remove_column` is irreversible without specifying the column type."
          lines << ""
          lines << "```ruby"
          lines << "class #{class_name} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def change"
          lines << "    remove_column :#{table}, :#{column}, :#{col_type}#{column_options(table, column)}"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          lines << "**Reversible:** Only if type is specified (included above)"
          lines << "**Data loss:** Yes - all data in this column will be permanently deleted"

          if column.end_with?("_id")
            lines << "**Foreign key:** This looks like a foreign key column. Check for `has_many`/`belongs_to` that reference it."
          end

          lines
        end

        def generate_rename_column(table, column, new_name)
          return [ "**Error:** `column` (the old name) and `new_name` are required for rename_column" ] unless column && new_name

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
            lines << "**Warning:** Column `#{column}` does not exist on `#{table}`. This migration will fail with `ActiveRecord::StatementInvalid`."
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
          lines << case family(table).key
          when :mysql
            "**Note:** MySQL/MariaDB add indexes to InnoDB tables via online DDL by default (`ALGORITHM=INPLACE`, no table lock) - there's no `algorithm: :concurrently` equivalent to reach for here (that option is PostgreSQL-only; Rails raises `ArgumentError` if you pass it on this adapter)."
          when :postgresql
            "**Note:** For large tables, consider `algorithm: :concurrently` (PostgreSQL) to avoid locking"
          else
            "**Note:** Building an index on a large table can block writes while it runs."
          end
          lines
        end

        # `column` names the reference and `type`, when given with it, the
        # table it points at; otherwise that table is the reference pluralized.
        # A name with no table of its own is a role: `parent` on `comments` is
        # a self-reference, which needs `to_table:`, and any other role needs
        # the table named before a foreign key can be written.
        def generate_add_association(table, column, type, options, schema = nil)
          written = column || type
          return [ "**Error:** Specify the associated table in column param (e.g., column: 'users')" ] unless written

          reference = written.to_s.singularize
          lines = []
          fk_column = "#{reference}_id"
          fk_column_exists = column_exists?(table, fk_column)
          if fk_column_exists
            lines << "**Warning:** Column `#{fk_column}` already exists on `#{table}`. This migration will fail. Use `add_index` if you only need an index."
            lines << ""
          end

          to_table = column && type ? type.to_s : reference.pluralize
          if schema_known?(schema) && !table_in_schema?(schema, to_table)
            if column && type
              lines << "**Warning:** No `#{to_table}` table in the schema, so a foreign key to it fails; the reference below has none."
              to_table = nil
            elsif reference == "parent"
              lines << "**Note:** No `#{to_table}` table: `parent` on `#{table}` reads as a reference to `#{table}` itself, " \
                       "written with `to_table:`. Call `add_association` with the table it points at as `type` to point it elsewhere."
              to_table = table
            else
              lines << "**Warning:** No `#{to_table}` table: `#{reference}` reads as a role. Call `add_association` with the table it points at as `type` " \
                       "(e.g. `type:\"users\"`); the reference below has no foreign key until then."
              to_table = nil
            end
            lines << ""
          end

          own = RailsAiContext::Payload.schema_databases(schema, table)
          theirs = to_table ? RailsAiContext::Payload.schema_databases(schema, to_table) : []
          across = own.any? && theirs.any? && !own.intersect?(theirs)
          if across
            lines << "**Foreign key:** `#{to_table}` is in #{theirs.join(' and ')} and `#{table}` in #{own.join(' and ')}; " \
                     "a foreign key cannot reach another database, so the reference below has none."
            lines << ""
          end

          composite = to_table && !across && composite_key(schema, to_table)
          if composite
            lines << "**Foreign key:** `#{to_table}` has the composite primary key (#{composite.join(', ')}), " \
                     "which one column cannot reference, so the reference below has none."
            lines << ""
          end

          fk_target = to_table unless across || composite
          given_key = option_value(options, :foreign_key)
          foreign_key = fk_target && !given_key ? foreign_key_option(schema, fk_target, reference) : ""
          reference_call = "add_reference :#{table}, :#{reference}#{key_type_option(schema, table, to_table)}#{", #{options}" if options}"
          lines << "```ruby"
          lines << "class Add#{written.camelize}To#{table.camelize} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def change"
          lines << "    #{reference_call}#{foreign_key}"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          lines << "**Reversible:** Yes"
          lines.concat(association_model_lines(table, reference, to_table))
          # A migration that fails on its existing column has nothing to make safe.
          keyless = given_key.is_a?(Prism::FalseNode) || given_key.is_a?(Prism::NilNode)
          lines.concat(association_strong_migrations_lines(table, reference, reference_call, (fk_target unless keyless), schema)) if strong_migrations_gem_present? && !fk_column_exists
          lines
        end

        # The value node `options` gives `key`, read as the keyword arguments it is written as.
        def option_value(options, key)
          call = RailsAiContext::AstCache.parse_uncached("f(#{options})").value.statements.body.first if options
          hash = call.arguments&.arguments&.last if call.is_a?(Prism::CallNode)
          return unless hash.is_a?(Prism::KeywordHashNode)

          hash.elements.find { |pair| pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode) && pair.key.unescaped == key.to_s }&.value
        end

        # The add_reference above as strong_migrations wants it on each
        # database: the index and the foreign key are what it checks.
        def association_strong_migrations_lines(table, reference, reference_call, fk_target, schema)
          column_option = ", column: :#{reference}_id"
          target_key = custom_primary_key(schema, fk_target) if fk_target
          add_foreign_key_call = "add_foreign_key :#{table}, :#{fk_target}#{column_option}#{", primary_key: :#{target_key}" if target_key}"
          warnings = case family(table).key
          when :postgresql
            # strong_migrations before 2.5.2 flags any key inside add_reference, so the key goes on its own.
            unvalidated_key_step = " and `#{add_foreign_key_call}, validate: false`" if fk_target
            steps = [
              "**`add_reference` builds its index without `algorithm: :concurrently`**, which blocks writes" \
              "#{", and its foreign key checks every existing row under a `SHARE ROW EXCLUSIVE` lock on both tables" if fk_target}. Instead:",
              "  1. `disable_ddl_transaction!` at the top of the migration, then `#{reference_call}, index: { algorithm: :concurrently }`#{unvalidated_key_step}"
            ]
            steps << "  2. In a separate migration: `validate_foreign_key :#{table}, :#{fk_target}#{column_option}`" if fk_target
            steps
          when :mysql
            if fk_target && strong_migrations_checks_mysql_foreign_keys?
              [
                "**`add_reference` with a foreign key blocks writes on both tables.** Add the reference without one, `#{reference_call}`, " \
                "and the key in a separate migration. If every row is valid and migrations do not run through a connection pooler:",
                "```ruby",
                "class Add#{reference.camelize}ForeignKeyTo#{table.camelize} < ActiveRecord::Migration[#{rails_version}]",
                "  def up",
                "    safety_assured do",
                "      execute \"SET SESSION foreign_key_checks = 0\"",
                "      #{add_foreign_key_call}",
                "    ensure",
                "      execute \"SET SESSION foreign_key_checks = 1\"",
                "    end",
                "  end",
                "",
                "  def down",
                "    remove_foreign_key :#{table}#{column_option}",
                "  end",
                "end",
                "```"
              ]
            end
          when :sqlite then nil # strong_migrations checks no foreign key on SQLite
          else
            [ "**The foreign key from `add_reference` validates existing rows**, which can block writes on both tables while it runs." ] if fk_target
          end
          strong_migrations_section(warnings)
        end

        # The belongs_to and has_many the reference wants, in the class each
        # table belongs to: a role names its class, and a self-reference is
        # optional (a root has no parent) and names its children.
        def association_model_lines(table, reference, to_table)
          owner = table_owner(table)
          lines = [ "**Also add to models:**", "```ruby", "# #{model_path(owner)}" ]
          unless to_table
            lines << "belongs_to :#{reference}, class_name: \"...\" # the model of the table it points at"
            return lines << "```"
          end

          target = table_owner(to_table)
          class_option = class_name_option(owner, reference.camelize, target)
          if to_table == table
            lines << "belongs_to :#{reference}#{class_option}, optional: true"
            lines << "has_many :children, class_name: \"#{class_name_for(target, target)}\", foreign_key: :#{reference}_id, inverse_of: :#{reference}, dependent: :destroy"
          else
            lines << "belongs_to :#{reference}#{class_option}"
            lines << "" << "# #{model_path(target)}"
            inverse = class_option.empty? ? "" : ", foreign_key: :#{reference}_id, inverse_of: :#{reference}"
            lines << "has_many :#{table}#{class_name_option(target, table.camelize.singularize, owner)}#{inverse}, dependent: :destroy"
          end
          lines << "```"
        end

        # Nothing when the association's own name already reaches the class.
        def class_name_option(from, derived, wanted)
          resolved_name(from, derived) == wanted ? "" : ", class_name: \"#{class_name_for(from, wanted)}\""
        end

        # A name a nearer model of the same name shadows is written from the root.
        def class_name_for(from, wanted)
          resolved_name(from, wanted) == wanted ? wanted : "::#{wanted}"
        end

        # The model Rails reaches by that name from `from`. Exact spellings only: an
        # unknown acronym costs a redundant class_name, a loose match a missing one.
        def resolved_name(from, name)
          models = Payload.models(cached_context)
          Introspectors::TableName.resolve_class(name, from) { |candidate| candidate if models.key?(candidate) }
        end

        def model_path(model)
          Payload.model_file(cached_context, model) || "app/models/#{model.underscore}.rb"
        end

        def schema_known?(schema)
          schema.is_a?(Hash) && Payload.schema_tables(schema).any?
        end

        def table_in_schema?(schema, name)
          Payload.schema_tables(schema).any? { |_, table, _| table.to_s == name.to_s }
        end

        def key_column(table_data)
          keys = Array(table_data && table_data[:columns]).select { |c| c[:primary_key] }
          keys.first if keys.size == 1
        end

        # The key type of a table when a reference would not get it by default: bigint never, integer unless counted as default.
        def custom_key_type(table_data, integer_is_default: true)
          type = key_column(table_data)&.dig(:type)&.to_s
          type unless type.nil? || type == "bigint" || (integer_is_default && type == "integer")
        end

        # A reference takes the column type of a serial key, never a sequence of its own.
        SERIAL_COLUMN_TYPES = { "serial" => "integer", "smallserial" => "smallint", "bigserial" => nil }.freeze

        # The type, limit and sign a reference needs to match its key, which a MySQL foreign key requires;
        # only SQLite types every integer alike. A table the schema lacks is keyed as the app's tables are.
        def key_type_option(schema, table, to_table)
          database = family(table).key
          target = to_table && schema_known?(schema) && Payload.schema_table(schema, to_table)
          key = key_column(target) if target
          type = target ? custom_key_type(target, integer_is_default: database == :sqlite) : app_key_type(schema)
          type = SERIAL_COLUMN_TYPES.fetch(type, type)
          limit = key[:limit] if key && type == "integer"
          unsigned = key && key[:unsigned] && database == :mysql
          "#{", type: :#{type}" if type}#{", limit: #{limit}" if limit}#{", unsigned: true" if unsigned}"
        end

        # Rails points a foreign key at the reference pluralized and at its
        # `id`, so another table, or a table keyed by another column, is named.
        def foreign_key_option(schema, to_table, reference)
          key = custom_primary_key(schema, to_table)
          options = [ ("to_table: :#{to_table}" if to_table != reference.pluralize), ("primary_key: :#{key}" if key) ].compact
          options.empty? ? ", foreign_key: true" : ", foreign_key: { #{options.join(', ')} }"
        end

        def custom_primary_key(schema, to_table)
          key = primary_key(schema, to_table)
          key if key.is_a?(String) && key != "id"
        end

        def composite_key(schema, to_table)
          key = primary_key(schema, to_table)
          key if key.is_a?(Array)
        end

        def primary_key(schema, to_table)
          schema_known?(schema) ? Payload.schema_table(schema, to_table)&.dig(:primary_key) : nil
        end

        # The key type more than half of the app's tables share, when it is not Rails' default.
        def app_key_type(schema)
          tables = schema.is_a?(Hash) && schema[:tables].is_a?(Hash) ? schema[:tables].values : []
          type, count = tables.map { |data| custom_key_type(data) }.tally.max_by(&:last)
          type if type && count * 2 > tables.size
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
          known_type = find_column_type(table, column, cached_context[:schema])
          original_type = known_type || "string"

          lines << "**Warning:** Changing column type may cause data loss if types are incompatible."
          lines << ""
          lines << "```ruby"
          lines << "class Change#{column.camelize}TypeIn#{table.camelize} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def up"
          lines << "    change_column :#{table}, :#{column}, :#{type}#{opts}"
          lines << "  end"
          lines << ""
          lines << "  def down"
          lines << "    change_column :#{table}, :#{column}, :#{original_type}#{column_options(table, column)}"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          # change_column has no inverse of its own; the `down` above is what
          # rolls it back, and it is only right when the schema knew the type.
          lines << if known_type
            "**Reversible:** Yes, through the `down` above, which restores `#{known_type}` (`change_column` alone cannot be reversed)"
          else
            "**Reversible:** Only if `#{column}` was a `string`: the schema does not list its type, so the `down` above guesses"
          end
          lines
        end

        def generate_create_table(table, columns_str, options, table_exists = false)
          lines = []
          if table_exists
            lines << "**Warning:** Table `#{table}` already exists. `create_table` fails on it unless it passes `if_not_exists: true`, " \
                     "or `force: :cascade`, which drops the table and every row in it first. Use `add_column` to change it."
            lines << ""
          end
          lines << "```ruby"
          lines << "class Create#{table.camelize} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def change"
          schema = cached_context[:schema]
          key_type = app_key_type(schema) unless option_value(options, :id)
          lines << "    create_table :#{table}#{", id: :#{key_type}" if key_type}#{", #{options}" if options} do |t|"

          if columns_str
            columns_str.split(",").each do |col|
              name, type, modifier = column_definition(col)
              index = { "index" => "", "uniq" => ", unique: true" }[modifier] if modifier
              if modifier && !index
                return [ "**Error:** `#{echo_input(col.strip)}`: only `index` and `uniq` can follow a column's type." ]
              end
              if %w[references belongs_to].include?(type)
                to_table = name.to_s.pluralize
                missing = schema_known?(schema) && !table_in_schema?(schema, to_table)
                composite = !missing && composite_key(schema, to_table)
                foreign_key = if missing then " # no foreign key: the schema has no #{to_table} table"
                elsif composite then " # no foreign key: #{to_table} has the composite primary key (#{composite.join(', ')})"
                else foreign_key_option(schema, to_table, name)
                end
                # A reference is indexed already, so only `uniq` changes its index.
                unique = ", index: { unique: true }" if modifier == "uniq"
                lines << "      t.#{type} :#{name}#{key_type_option(schema, table, to_table)}#{unique}#{foreign_key}"
              else
                lines << "      t.#{type} :#{name}"
                lines << "      t.index :#{name}#{index}" if index
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

        # Strong Migrations integration - surfaces the same warnings the gem would raise
        # at migration runtime, so AI agents see them at code-generation time. Only fires
        # when the gem is actually present in the project's Gemfile.lock.
        #
        # Catalog covers the most common breaking-change patterns (columns, indexes);
        # add_association's warning lives with the reference it rewrites.
        # Not exhaustive - see https://github.com/ankane/strong_migrations#checks for the full list.
        def strong_migrations_warnings(action, table, column, options)
          warnings = case action
          when "remove_column"
            [
              "**`remove_column` is unsafe under load.** strong_migrations requires:",
              "  1. Add the column to `self.ignored_columns += %w[#{column}]` in `#{model_path(table_owner(table))}` first.",
              "  2. Deploy that change.",
              "  3. THEN run the migration in a separate deploy.",
              "  Or wrap in `safety_assured do ... end` if you accept the risk."
            ]
          when "rename_column"
            [
              "**`rename_column` is unsafe under load.** Old code references the old name and breaks during the deploy window.",
              "Safer pattern: add a new column, backfill, dual-write, deploy, then remove the old column in a later release."
            ]
          when "change_type"
            [
              "**`change_column` (type change) blocks writes**#{" on Postgres" if family(table).postgresql?} for the duration of the table rewrite, which can be hours on large tables.",
              "Safer pattern: add a new column with the new type, backfill, dual-write, swap, drop the old column."
            ]
          when "add_index"
            # strong_migrations only requires algorithm: :concurrently on
            # PostgreSQL (its ACCESS EXCLUSIVE lock is the problem) - it
            # doesn't flag plain add_index on MySQL/MariaDB or SQLite at all.
            if family(table).postgresql? && !options.to_s.include?("concurrently")
              [
                "**`add_index` without `algorithm: :concurrently`** acquires an `ACCESS EXCLUSIVE` lock on Postgres and blocks writes.",
                "Use `add_index :#{table}, :#{column}, algorithm: :concurrently` and add `disable_ddl_transaction!` at the top of the migration."
              ]
            end
          when "add_column"
            if options.to_s.match?(/null:\s*false/) && !options.to_s.include?("default:")
              [
                if family(table).postgresql?
                  "**Adding a `NOT NULL` column without a default rewrites the table** on older Postgres and fails on existing rows."
                else
                  "**Adding a `NOT NULL` column without a default** needs a value for every existing row."
                end,
                "Safer pattern: add the column nullable, backfill in batches, then add the NOT NULL constraint with `change_column_null`."
              ]
            end
          end

          strong_migrations_section(warnings)
        end

        def strong_migrations_section(warnings)
          return [] unless warnings&.any?

          [ "", "## Strong Migrations Warnings", "", "_The `strong_migrations` gem is in your Gemfile - these warnings match what it would raise at migration runtime._", "" ] + warnings
        end

        def strong_migrations_gem_present?
          RailsAiContext::GemLock.for(rails_app.root).present?("strong_migrations")
        rescue => e
          RailsAiContext.debug_fail(e, false, label: "strong_migrations_gem_present?")
        end

        # strong_migrations checks a MySQL foreign key from 2.7 on; an unlocked or unreadable version is taken as current.
        def strong_migrations_checks_mysql_foreign_keys?
          version = RailsAiContext::GemLock.for(rails_app.root).version("strong_migrations")
          version.nil? || Gem::Version.new(version).release >= Gem::Version.new("2.7")
        rescue => e
          RailsAiContext.debug_fail(e, true, label: "strong_migrations_checks_mysql_foreign_keys?")
        end

        # Every STI subclass records its base's table, so the owner is one whose
        # parent is not on it; the conventional name settles two unrelated classes.
        def table_owner(table)
          models = Payload.models(cached_context)
          conventional = table.singularize.camelize
          readers = models_for_table(table, models)
          roots = readers.reject { |name| readers.include?(models.dig(name, :parent_model)) }
          roots.find { |name| name == conventional } || roots.first || readers.first || conventional
        end

        # The models on the table, and, when the change can touch a relation,
        # the associations that read it. Renaming or dropping a plain column
        # moves no association, so those list the models alone.
        def show_affected_models(table, models, action: nil, column: nil)
          relations = !%w[remove_column rename_column change_type].include?(action) || column.to_s.end_with?("_id")
          rows = affected_model_rows(table, models, relations: relations)
          return [] if rows.empty?

          [ "", "## Affected Models", "" ] + rows
        end

        MENTION_CAP = 15

        # Every line in the app's Ruby and views that names the column, word
        # for word: the code a rename or a drop breaks. A name the code also
        # uses for something else shows up too, which is why each is listed
        # rather than counted.
        def column_mention_lines(column)
          root = rails_app.root.to_s
          pattern = /\b#{Regexp.escape(column)}\b/
          found = []
          %w[app lib config].each do |dir|
            base = File.join(root, dir)
            next unless Dir.exist?(base)

            safe_glob(base, "**/*.{rb,erb,haml,slim,jbuilder}", File.realpath(root)).sort.each do |path|
              next if sensitive_file?(path.delete_prefix("#{File.realpath(root)}/"))

              source = RailsAiContext::SafeFile.read(path) or next
              next unless source.match?(pattern)

              source.each_line.with_index(1) do |line, number|
                found << "- `#{path.delete_prefix("#{File.realpath(root)}/")}:#{number}` #{line.strip.truncate(100)}" if line.match?(pattern)
              end
            end
          end
          return [ "", "## Code that names `#{column}`", "", "_No line in app/, lib/ or config/ names it._" ] if found.empty?

          search = pointer("rails_search_code", %(pattern:"#{column}", exact_match:true), "lists them all")
          more = found.size > MENTION_CAP ? [ "- _...and #{found.size - MENTION_CAP} more#{"; #{search}" if search}_" ] : []
          [ "", "## Code that names `#{column}` (#{count_phrase(found.size, "line")})", "" ] + found.first(MENTION_CAP) + more
        rescue => e
          RailsAiContext.debug_fail(e, [], label: "column_mention_lines")
        end

        def affected_model_rows(table, models, relations: true)
          return [] if models.empty?

          owners = models_for_table(table, models)
          rows = owners.map { |name| "- **#{name}** - directly affected (table: #{table})" }
          return rows unless relations

          models.each do |name, data|
            next unless data.is_a?(Hash)

            Array(data[:associations]).grep(Hash).each do |a|
              next unless owners.include?(a[:class_name].to_s.delete_prefix("::")) ||
                a[:name].to_s.pluralize == table ||
                a[:name].to_s.singularize == table.singularize

              rows << "- **#{name}** - #{a[:macro] || a[:type]} #{Serializers::SectionFacts.association_name(a)}"
            end
          end

          rows.uniq
        end

        # The payload records the table each model reads, so the models for a
        # table are looked up rather than derived: "admin_action_logs"
        # camelizes to a constant no app declares. The derived name is the
        # fallback for a payload whose models record no table.
        def models_for_table(table, models)
          named = models.select { |_, d| d.is_a?(Hash) && d[:table_name].to_s == table }.keys.map(&:to_s)
          return named if named.any?

          derived = Introspectors::TableName.model_for(table.singularize.camelize, nil, models)
          derived ? [ derived ] : []
        end

        def column_exists?(table, column)
          schema = cached_context[:schema]
          table_data = RailsAiContext::Payload.schema_table(schema, table)
          return false unless table_data

          col_str = column.to_s
          (table_data[:columns] || []).any? { |c| c[:name].to_s == col_str }
        end

        def index_exists?(table, column)
          schema = cached_context[:schema]
          table_data = RailsAiContext::Payload.schema_table(schema, table)
          return false unless table_data

          # add_index collides only with the name it would give the index; a
          # composite index containing the column is no duplicate.
          default_name = RailsAiContext::Introspectors::SchemaConventions.default_index_name(table, [ column ])
          (table_data[:indexes] || []).any? { |idx|
            cols = (idx[:columns] || [ idx[:column] ].compact).map(&:to_s)
            idx[:name].to_s == default_name || (idx[:name].nil? && cols == [ column.to_s ])
          }
        end

        # The options that rebuild the column as the schema holds it: change_column replaces the whole
        # definition, and remove_column's rollback adds the column back from them.
        def column_options(table, column)
          col = Array(RailsAiContext::Payload.schema_table(cached_context[:schema], table)&.dig(:columns)).find { |c| c[:name] == column }
          return "" unless col

          options = %i[limit precision scale].filter_map { |key| "#{key}: #{col[key]}" if col[key].is_a?(Integer) }
          options << "array: true" if col[:array]
          options << "null: false" if col[:null] == false
          default = col[:default].to_s
          # The dump writes a boolean or number default as its literal, any other as a string (type_cast_for_schema).
          literal = default.start_with?("-> {") ||
                    (%w[boolean integer bigint float].include?(col[:type].to_s) && default.match?(/\A(?:true|false|-?\d+(?:\.\d+)?)\z/))
          options << "default: #{literal ? default : default.inspect}" unless col[:default].nil?
          options.map { |option| ", #{option}" }.join
        end

        def find_column_type(table, column, schema)
          table_data = RailsAiContext::Payload.schema_table(schema, table)
          return nil unless table_data

          col = (table_data[:columns] || []).find { |c| c[:name] == column }
          col[:type] if col
        end

        # The superclass names the app's Rails, not the gem's. A standalone
        # --no-boot run has no Rails constant at all, and inside a bundle the
        # constant is whatever the gem loaded, so the context (which carries
        # the lockfile's version under --no-boot) comes first.
        def rails_version
          resolved_rails_version || SUPPORTED_RAILS_FLOOR
        end

        def rails_version_unknown?
          resolved_rails_version.nil?
        end

        def resolved_rails_version
          from_context = major_minor(cached_context[:rails_version])
          return from_context if from_context
          return major_minor(Rails.version) if defined?(Rails) && Rails.respond_to?(:version)

          nil
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "rails_version")
        end

        # nil for anything that is not a real version, including the
        # [UNAVAILABLE: ...] marker a static context can carry.
        def major_minor(value)
          parts = value.to_s.split(".").first(2)
          return nil unless parts.size == 2 && parts.all? { |p| p.match?(/\A\d+\z/) }

          parts.join(".")
        end

        # The family of the database that holds the table, since locking advice differs by family.
        # An undecided database is no family and gets advice that names no database.
        def family(table)
          return RailsAiContext::DatabaseFamily.of(cached_context.dig(:schema, :adapter).to_s) if on_primary?(table)

          held_in = Payload.schema_databases(Payload.section(cached_context, :schema), table)
          RailsAiContext::AppDatabases.for(rails_app.root)[held_in.first]&.family || RailsAiContext::DatabaseFamily.of(nil)
        end

        # A table no database holds yet goes to the primary. Another database can carry the name "primary".
        def on_primary?(table)
          holders = Payload.table_holders(Payload.section(cached_context, :schema), table)
          holders.empty? || holders.any? { |database, _, _| database.nil? }
        end
      end
    end
  end
end
