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
        order: 28,
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

      def self.call(action: nil, table: nil, column: nil, type: nil, new_name: nil, options: nil, server_context: nil)
        action = action.to_s.strip
        table = table.to_s.strip
        column = column.to_s.strip.presence if column

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

        rename_to = new_name.to_s.strip.presence || type.to_s.strip.presence if action == "rename_column"
        if (unknown = unknown_type(action, column, type))
          return text_response((lines + [ unknown ]).join("\n"))
        end
        # What the app's migrations already hold: a file the generator's name
        # collides with, and a pending one that makes the same change.
        prior = prior_migration_lines(action, table, column, rename_to, type, migration_files_for(target), pending_versions(schema, databases))
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
        # add_association accepts the associated table via either `column` or
        # `type` (see generate_add_association) - resolve the same way here.
        warning_column = action == "add_association" ? (column || type) : column
        lines.concat(strong_migrations_warnings(action, table, warning_column, options)) if strong_migrations_gem_present?

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
        def pending_versions(schema, databases)
          pending = if databases.empty? || databases.include?("primary")
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

        def collect_changes(node, block_table, changes)
          return unless node.is_a?(Prism::Node)

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

        # A type no adapter knows writes a migration that fails when it runs.
        def unknown_type(action, column, type)
          written = case action
          when "add_column", "change_type" then [ type ]
          when "create_table" then column.to_s.split(",").map { |definition| definition.split(":")[1]&.strip }
          end
          bad = Array(written).compact.reject(&:empty?).find { |t| !column_types.include?(t) }
          return nil unless bad

          suggestion = find_closest_match(bad, column_types)
          "**Error:** Unknown column type `#{bad}`.#{" Did you mean `#{suggestion}`?" if suggestion} " \
            "Migration types include string, text, integer, bigint, decimal, boolean, date, datetime, json and references."
        end

        # A table only a secondary database holds needs its migration in that database's migrations_paths.
        # [lines, target]: target is nil for the primary, false when no environment configures the
        # database, else the generator's --database flag and the RAILS_ENV that configures it.
        def database_option(table, databases)
          return [ [], nil ] if databases.empty? || databases.include?("primary")

          yml = RailsAiContext::DatabaseYml
          root = rails_app.root
          found = databases.to_h { |db| [ db, (entry = yml.entry(root, db)) ? [ nil, entry ] : yml.elsewhere(root, db) ] }.compact
          if found.empty?
            note = "**Database:** `#{table}` is in the #{databases.join(", ")} dump, which no environment in config/database.yml configures: " \
                   "no `--database` reaches it, and a migration generated here runs on the primary."
            return [ [ note, "" ], false ]
          end

          names = found.keys
          env_name = found.values.first.first
          configured = Array(found.values.first.last["migrations_paths"])
          dirs = configured.any? ? configured.map { |path| File.expand_path(path, root.to_s) } : [ File.join(root.to_s, "db", "#{names.first}_migrate") ]
          target = { flag: " --database #{names.first}", env: env_name, dirs: dirs }
          paths = configured.join(", ")
          note = "**Database:** `#{table}` is in #{[ names[0..-2].join(", "), names.last ].reject(&:empty?).join(" and ")}," \
                 "#{" which #{env_name} configures and this environment does not," if env_name} not the primary database: generate with #{"`RAILS_ENV=#{env_name}` and " if env_name}`#{target[:flag].strip}` " \
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

        # NOT NULL with no default has no value for the rows already there, so
        # the migration fails on a table that holds any. The row count is the
        # database's own estimate when the app is booted.
        def not_null_warning(table, column)
          rows = Array(Payload.section(cached_context, :database_stats)&.dig(:tables)).find { |t| t[:table].to_s == table }&.dig(:approximate_rows)
          held = rows.nil? ? "if `#{table}` holds any rows" : "as `#{table}` holds about #{count_phrase(rows, "row")}"
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
          lines << "    remove_column :#{table}, :#{column}, :#{col_type}"
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
          lines << if mysql_adapter?
            "**Note:** MySQL/MariaDB add indexes to InnoDB tables via online DDL by default (`ALGORITHM=INPLACE`, no table lock) - there's no `algorithm: :concurrently` equivalent to reach for here (that option is PostgreSQL-only; Rails raises `ArgumentError` if you pass it on this adapter)."
          else
            "**Note:** For large tables, consider `algorithm: :concurrently` (PostgreSQL) to avoid locking"
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
          if column_exists?(table, fk_column)
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
                       "written with `to_table:`. Pass the table it points at as `type` to point it elsewhere."
              to_table = table
            else
              lines << "**Warning:** No `#{to_table}` table: `#{reference}` reads as a role. Pass the table it points at as `type` " \
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

          foreign_key = if across || to_table.nil? then ""
          elsif to_table == reference.pluralize then ", foreign_key: true"
          else ", foreign_key: { to_table: :#{to_table} }"
          end
          lines << "```ruby"
          lines << "class Add#{written.camelize}To#{table.camelize} < ActiveRecord::Migration[#{rails_version}]"
          lines << "  def change"
          lines << "    add_reference :#{table}, :#{reference}#{foreign_key}"
          lines << "  end"
          lines << "end"
          lines << "```"
          lines << ""
          lines << "**Reversible:** Yes"
          lines.concat(association_model_lines(table, reference, to_table))
        end

        # The belongs_to and has_many the reference wants, in the models that
        # read each table: a role names its class, and a self-reference is
        # optional (a root has no parent) and names its children.
        def association_model_lines(table, reference, to_table)
          models = Payload.models(cached_context)
          owner = models_for_table(table, models).first || table.singularize.camelize
          lines = [ "**Also add to models:**", "```ruby", "# #{model_path(owner)}" ]
          unless to_table
            lines << "belongs_to :#{reference}, class_name: \"...\" # the model of the table it points at"
            return lines << "```"
          end

          target = models_for_table(to_table, models).first || to_table.singularize.camelize
          class_option = reference.camelize == target ? "" : ", class_name: \"#{target}\""
          if to_table == table
            lines << "belongs_to :#{reference}#{class_option}, optional: true"
            lines << "has_many :children, class_name: \"#{target}\", foreign_key: :#{reference}_id, inverse_of: :#{reference}, dependent: :destroy"
          else
            lines << "belongs_to :#{reference}#{class_option}"
            lines << "" << "# #{model_path(target)}"
            inverse = class_option.empty? ? "" : ", foreign_key: :#{reference}_id, inverse_of: :#{reference}"
            lines << "has_many :#{table}#{inverse}, dependent: :destroy"
          end
          lines << "```"
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
          lines << "    change_column :#{table}, :#{column}, :#{original_type}"
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

        # Strong Migrations integration - surfaces the same warnings the gem would raise
        # at migration runtime, so AI agents see them at code-generation time. Only fires
        # when the gem is actually present in the project's Gemfile.lock.
        #
        # Catalog covers the most common breaking-change patterns (columns, indexes, FKs).
        # Not exhaustive - see https://github.com/ankane/strong_migrations#checks for the full list.
        def strong_migrations_warnings(action, table, column, options)
          warnings = case action
          when "remove_column"
            [
              "**`remove_column` is unsafe under load.** strong_migrations requires:",
              "  1. Add the column to `self.ignored_columns += %w[#{column}]` in `#{model_file_for_table(table)}` first.",
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
              "**`change_column` (type change) blocks writes** on Postgres for the duration of the table rewrite, which can be hours on large tables.",
              "Safer pattern: add a new column with the new type, backfill, dual-write, swap, drop the old column."
            ]
          when "add_index"
            # strong_migrations only requires algorithm: :concurrently on
            # PostgreSQL (its ACCESS EXCLUSIVE lock is the problem) - it
            # doesn't flag plain add_index on MySQL/MariaDB or SQLite at all.
            if postgresql_adapter? && !options.to_s.include?("concurrently")
              [
                "**`add_index` without `algorithm: :concurrently`** acquires an `ACCESS EXCLUSIVE` lock on Postgres and blocks writes.",
                "Use `add_index :#{table}, :#{column}, algorithm: :concurrently` and add `disable_ddl_transaction!` at the top of the migration."
              ]
            end
          when "add_association"
            if mysql_adapter?
              [
                "**`add_foreign_key` blocks writes on both tables while validating existing rows.** MySQL/MariaDB has no `validate: false` + separate-validation two-step like Postgres.",
                "If you're certain all rows are valid, wrap in `safety_assured` and drop `foreign_key_checks` for the duration:",
                "  1. `execute \"SET SESSION foreign_key_checks = 0\"`",
                "  2. `add_foreign_key :#{table}, :#{column}`",
                "  3. `execute \"SET SESSION foreign_key_checks = 1\"`"
              ]
            else
              [
                "**`add_foreign_key` validates existing rows by default**, which acquires a `SHARE ROW EXCLUSIVE` lock on both tables.",
                "Safer two-step pattern:",
                "  1. `add_foreign_key :#{table}, :#{column}, validate: false` (lock-free)",
                "  2. In a separate migration: `validate_foreign_key :#{table}, :#{column}`"
              ]
            end
          when "add_column"
            if options.to_s.match?(/null:\s*false/) && !options.to_s.include?("default:")
              [
                "**Adding a `NOT NULL` column without a default rewrites the table** on older Postgres and fails on existing rows.",
                "Safer pattern: add the column nullable, backfill in batches, then add the NOT NULL constraint with `change_column_null`."
              ]
            end
          end

          return [] unless warnings&.any?

          [ "", "## Strong Migrations Warnings", "", "_The `strong_migrations` gem is in your Gemfile - these warnings match what it would raise at migration runtime._", "" ] + warnings
        end

        def strong_migrations_gem_present?
          RailsAiContext::GemLock.for(rails_app.root).present?("strong_migrations")
        rescue => e
          RailsAiContext.debug_fail(e, false, label: "strong_migrations_gem_present?")
        end

        # ignored_columns has to go on the class that owns the table, and
        # every STI class records that same table, so a child that sorts
        # earlier would otherwise win. The conventional name is the base.
        def model_file_for_table(table)
          conventional = table.singularize.camelize
          owners = models_for_table(table, Payload.models(cached_context))
          name = owners.find { |owner| owner == conventional } || owners.first || conventional
          Payload.model_file(cached_context, name)
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

          more = found.size > MENTION_CAP ? [ "- _...and #{found.size - MENTION_CAP} more; `rails_search_code(pattern:\"#{column}\", exact_match:true)` lists them all_" ] : []
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

        # Locking/DDL advice differs by adapter (MySQL's online DDL vs
        # Postgres's ACCESS EXCLUSIVE locks), so callers need to know which
        # family the app is actually running before printing lock advice.
        def current_adapter
          cached_context.dig(:schema, :adapter).to_s
        end

        def mysql_adapter?
          current_adapter.match?(/mysql|trilogy/i)
        end

        def postgresql_adapter?
          current_adapter.match?(/postg/i)
        end
      end
    end
  end
end
