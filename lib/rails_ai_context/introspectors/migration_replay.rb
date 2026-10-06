# frozen_string_literal: true

require "set"

module RailsAiContext
  module Introspectors
    # Tables for an app with no schema dump, replayed from migrations in the dump readers' shape.
    module MigrationReplay
      Counts = Struct.new(:unnamed, :unnamed_columns, :helper_calls, :failed_files)
      Result = Struct.new(:tables, :counts)
      Run = Struct.new(:pk_type, :root, :real_root, :db_dirs, :read, :helpers, :counts, keyword_init: true)

      module_function

      # Migrations that require table files can chain, so the walk is bounded like routes `draw`.
      MAX_REQUIRE_DEPTH = 5

      # @param migrations_dir [String, Array<String>] one or more migrations paths
      # @return [Hash] table name => { columns:, indexes:, foreign_keys: }
      def tables(migrations_dir, pk_type:, root: nil)
        replayed(migrations_dir, pk_type: pk_type, root: root).tables
      end

      # @return [Result] the tables, and the Counts the schema note reports
      def replayed(migrations_dir, pk_type:, root: nil)
        dirs = Array(migrations_dir)
        run = new_run(dirs, pk_type: pk_type, root: root)
        tables = {}
        # Rails orders every migrations path by version, not one directory at a time.
        migration_files(dirs, root: run.real_root).each { |path| replay_file(path, tables, run) }

        tables.delete("ar_internal_metadata")
        tables.delete("schema_migrations")
        Result.new(tables, run.counts)
      end

      def new_run(dirs, pk_type:, root: nil)
        root = File.expand_path((root || File.join(dirs.first.to_s, "..", "..")).to_s)
        Run.new(pk_type: pk_type, root: root, real_root: real_root(root), db_dirs: db_dirs(root, dirs), read: [], helpers: Set.new,
                counts: Counts.new(0, 0, 0, 0))
      end

      # database.yml's migrations_paths for the primary, else db/migrate and db/post_migrate
      # for the app and each in-repo engine.
      def migration_dirs(root)
        configured_dirs(root, RailsAiContext::DatabaseYml.primary(root)) ||
          PathResolver.dirs_for(root.to_s, "db/migrate") + PathResolver.dirs_for(root.to_s, "db/post_migrate")
      end

      # A database entry's migrations_paths, which replace the default list as
      # ConnectionPool#migrations_paths does; nil when the entry names none.
      def configured_dirs(root, config)
        paths = Array(config.is_a?(Hash) ? config["migrations_paths"] : nil)
          .select { |path| path.is_a?(String) && !path.empty? && !RailsAiContext::DatabaseYml.computed?(path) }
        return nil if paths.empty?

        real = real_root(root)
        paths.filter_map do |path|
          dir = File.expand_path(path, root.to_s)
          dir if SafePath.contained?(File.realpath(dir), real)
        rescue SystemCallError
          nil
        end
      end

      # Rails' own glob: versioned files at any depth, run in version order. With a root, a
      # file whose real path leaves the app is not read, so every reader counts the same files.
      def migration_files(dirs, root: nil)
        files = Array(dirs).flat_map { |dir| Dir.glob(File.join(dir.to_s, "**", "[0-9]*_*.rb")) }
          .sort_by { |path| [ File.basename(path), path ] }
        return files unless root

        real = real_root(root)
        files.select do |path|
          SafePath.contained?(File.realpath(path), real)
        rescue SystemCallError
          false
        end
      end

      # The app root as the file system resolves it, or as given when it does not exist.
      def real_root(root)
        File.realpath(root.to_s)
      rescue SystemCallError
        root.to_s
      end

      # A migration may require from the app's db/ or the one holding its migrations path.
      def db_dirs(root, dirs)
        ([ File.join(root, "db") ] + dirs.map { |dir| File.dirname(dir.to_s) }).filter_map do |dir|
          File.realpath(dir)
        rescue SystemCallError
          nil
        end.uniq
      end

      # One file, after the db/ files it requires: Ruby loads those before the
      # body runs, and a table file defines its table there.
      def replay_file(path, tables, run, depth = 0)
        real = begin
          File.realpath(path)
        rescue SystemCallError
          return
        end
        return if run.read.include?(real) || !SafePath.contained?(real, run.real_root)

        run.read << real
        content = RailsAiContext::SafeFile.read(real, max_size: RailsAiContext.configuration.max_schema_file_size)
        return unless content

        if depth < MAX_REQUIRE_DEPTH
          required_db_files(content, real, run).each { |dep| replay_file(dep, tables, run, depth + 1) }
        end
        replay(content, tables, run, real)
      rescue StandardError, ScriptError => e
        # One unreadable migration costs that file, not the whole schema.
        run.counts.failed_files += 1
        RailsAiContext.debug_fail(e, nil, label: "replay #{path}")
      end

      # The .rb files under a db/ directory this file names literally, by a
      # require or a Dir glob it iterates; any other path is refused.
      def required_db_files(content, path, run)
        literal_requires(content, File.dirname(path), run.root).flat_map do |spec, relative_to_file|
          base = relative_to_file ? File.dirname(path) : run.root
          pattern = spec.start_with?("/") ? spec : File.join(base, spec)
          pattern += ".rb" unless File.extname(pattern) == ".rb"
          Dir.glob(pattern)
        end.filter_map do |candidate|
          real = File.realpath(candidate) rescue next
          real if real.end_with?(".rb") && run.db_dirs.any? { |dir| SafePath.contained?(real, dir) }
        end.uniq.sort
      end

      # [[path spec, relative to this file?], ...]
      def literal_requires(content, file_dir, app_root)
        tree = AstCache.parse_string(content)&.value
        return [] unless tree

        AstWalk.each(tree).filter_map do |node|
          next unless node.is_a?(Prism::CallNode)

          case node.name
          when :require, :require_relative
            spec = literal_path(node.arguments&.arguments&.first, file_dir, app_root)
            [ spec, node.name == :require_relative ] if spec
          when :[], :glob
            spec = literal_path(node.arguments&.arguments&.first, file_dir, app_root) if dir_receiver?(node)
            [ spec, false ] if spec
          end
        end
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, [], label: "literal_requires")
      end

      def dir_receiver?(node)
        receiver = node.receiver
        (receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :Dir) ||
          (node.name == :[] && receiver.is_a?(Prism::ConstantPathNode) && receiver.slice == "Dir")
      end

      # A path built only from literals, `__dir__` and Rails.root: a string,
      # `.to_s` around one, `Rails.root.join`, `File.join` or `File.expand_path(x, dir)`.
      def literal_path(node, file_dir, app_root)
        case node
        when Prism::StringNode then node.unescaped
        when Prism::CallNode
          return file_dir if node.name == :__dir__ && node.receiver.nil? && node.arguments.nil?
          return app_root if rails_root?(node)
          return literal_path(node.receiver, file_dir, app_root) if node.name == :to_s && node.arguments.nil?

          parts = (node.arguments&.arguments || []).map { |arg| literal_path(arg, file_dir, app_root) }
          return nil if parts.empty? || !parts.all?

          if node.name == :join && rails_root?(node.receiver) then File.join(*parts)
          elsif file_call?(node, :join) then File.join(*parts)
          elsif file_call?(node, :expand_path) && parts.size == 2 && parts[1].start_with?("/") then File.expand_path(*parts)
          end
        end
      end

      def file_call?(node, name)
        node.name == name && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :File
      end

      def rails_root?(node)
        node.is_a?(Prism::CallNode) && node.name == :root &&
          node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Rails
      end

      # One file's statements, applied in the order the migration runs them.
      def replay(content, tables, run, path = nil)
        parsed = AstCache.parse_string(content)
        tree = parsed&.value
        # A wrapper's own create_table makes whatever each caller names.
        helper_ranges = Helpers.table_helper_defs(tree, run.helpers)
        ast_data = SourceIntrospector.walk_dispatch(parsed, {
          migration: -> { Listeners::MigrationDslListener.new(table_helpers: run.helpers) },
          schema: -> { Listeners::SchemaDslListener.new },
          replay: -> { Listeners::MigrationReplayListener.new }
        })

        # A down body undoes the migration, so replaying it beside up cancels it out.
        skipped = ast_data[:replay].select { |hit| hit[:kind] == :down }.map { |hit| hit[:range] } + helper_ranges
        reverts = ast_data[:replay].select { |hit| hit[:kind] == :revert }.map { |hit| hit[:range] }
        statements = ast_data[:replay].reject { |hit| %i[down revert].include?(hit[:kind]) }
        module_entries = Helpers.module_helper_entries(tree, run.root) + Helpers.app_constant_call_markers(tree, run.root)
        collected = (ast_data[:migration] + ast_data[:schema] + statements + module_entries)
          .reject { |r| skipped.any? { |range| range.cover?(r[:location]) } }
        entries = invert_reverts(Helpers.follow_local_methods(tree, collected, run.helpers)
          .sort_by.with_index { |r, i| [ r[:location], r[:order] || 0, i ] }, reverts)

        inferred = inferred_table_name(content, path)
        inferred_existed = tables.key?(inferred)
        used_inferred = inferred && name_unnamed_tables(entries, inferred)
        version = migration_version(tree)
        entries.each { |entry| entry[:migration_version] = version }

        # Migration[5.0] and older run Compatibility::V5_0, which keys a table and its references with integer.
        dispatch(entries, tables, version && (version <=> [ 5, 0 ]) <= 0 ? "integer" : run.pk_type)
        mark_inferred(tables, inferred, inferred_existed) if used_inferred
        count(entries, run.counts)
      end

      # Each statement on the table it names, a block's on the table its block
      # opened; only a table definition (create_table's block) indexes timestamps.
      def dispatch(entries, tables, pk_type)
        current_table = nil
        creating = false
        entries.each do |entry|
          next if entry[:kind] == :not_replayed

          entry = entry.merge(table: current_table, definition: creating) if entry[:block]
          if entry.key?(:action)
            case entry[:action]
            when :create_table, :change_table
              if entry[:action] == :create_table && skipped_create?(entry, tables)
                current_table = nil
                next
              end
              current_table = entry[:table]
              creating = entry[:action] == :create_table
            when :drop_table, :rename_table then current_table = nil
            end
            made = Statements.apply(entry, tables, pk_type)
            current_table, creating = made, true if entry[:action] == :create_join_table
          elsif entry[:type] == :create_table
            current_table = entry[:table]
            creating = true
            Statements.seed_table(tables, current_table, entry[:options], pk_type)
          elsif entry[:type] == :column && current_table
            Statements.apply_schema_column(entry, current_table, tables, pk_type)
          elsif entry[:type] == :index && current_table
            Statements.apply_schema_index(entry, current_table, tables)
          elsif entry[:type] == :unread_call && current_table
            SchemaConventions.note_unread_call(tables[current_table], entry[:name])
          end
        end
      end

      INVERSE = { create_table: :drop_table, add_column: :remove_column, add_index: :remove_index,
                  add_reference: :remove_reference, add_belongs_to: :remove_reference,
                  add_foreign_key: :remove_foreign_key, add_check_constraint: :remove_check_constraint }.freeze

      # Migration#revert runs its block's statements inverted and last first.
      # CommandRecorder#revert flips reverting, so a revert inside one runs forward.
      def invert_reverts(entries, ranges, reverting = false)
        outermost = ranges.reject { |range| ranges.any? { |other| other != range && other.cover?(range.first) && other.cover?(range.last) } }
        units = []
        entries.each do |entry|
          range = outermost.find { |r| r.cover?(entry[:location]) }
          if range ? units.last&.first == range : (reverting && units.last && !units.last.first && !(entry.key?(:action) && !entry[:block]))
            units.last.last << entry
          else
            units << [ range, [ entry ] ]
          end
        end
        units = units.map do |range, group|
          if range
            invert_reverts(group, ranges.select { |o| o != range && range.cover?(o.first) && range.cover?(o.last) }, !reverting)
          else
            reverting ? inverted(group) : group
          end
        end
        (reverting ? units.reverse : units).flatten(1)
      end

      # A statement with its block, inverted; one CommandRecorder cannot invert is not replayed.
      def inverted(group)
        head, *body = group
        return group unless head.key?(:action) && !head[:block]

        inverse = case head[:action]
        when *INVERSE.keys then head.merge(action: INVERSE[head[:action]])
        when :drop_table then head.merge(action: :create_table) if body.any?
        when :remove_column then head.merge(action: :add_column) if head[:column_type]
        when :rename_column then head.merge(column: head[:new_name], new_name: head[:column])
        when :rename_table then head.merge(table: head[:new_name], new_name: head[:table])
        when :add_timestamps then head.merge(action: :remove_columns, columns: %w[created_at updated_at])
        when :change_column_null then head.merge(null: !head[:null]) unless head[:null].nil?
        when :change_column_default
          options = head[:options] || {}
          head.merge(options: options.merge(from: options[:to], to: options[:from])) if options.key?(:from) && options.key?(:to)
        end
        return [ { kind: :not_replayed, location: head[:location] } ] unless inverse

        inverse[:action] == :create_table ? [ inverse, *body ] : [ inverse ]
      end

      # A temporary table is gone with the connection, and if_not_exists leaves a table that exists as it is.
      def skipped_create?(entry, tables)
        options = entry[:options] || {}
        options[:temporary] == true || (options[:if_not_exists] == true && tables.key?(entry[:table]))
      end

      # Counted after the flow, so a call only down or a rescue reaches is not.
      def count(entries, counts)
        counts.helper_calls += entries.count { |e| e[:kind] == :not_replayed }
        counts.unnamed += entries.count { |e| e[:table].nil? && e[:action] == :create_table }
        counts.unnamed_columns += entries.count { |e| e[:action] == :add_column && e[:column].nil? && e[:table] }
      end

      # [major, minor] from the first `ActiveRecord::Migration[6.0]`; nil for a
      # migration naming none, which Rails runs as the current version.
      def migration_version(tree)
        return nil unless tree

        call = AstWalk.each(tree).find do |node|
          node.is_a?(Prism::CallNode) && node.name == :[] && node.arguments&.arguments&.first.is_a?(Prism::FloatNode) &&
            node.receiver&.slice&.delete_prefix("::") == "ActiveRecord::Migration"
        end
        call && call.arguments.arguments.first.slice.split(".").map(&:to_i)
      end

      # A class that names its table through itself (Tables::Base's
      # name.demodulize.underscore) is named by its file, when the two agree.
      def inferred_table_name(content, path)
        return nil unless path

        stem = File.basename(path.to_s, ".rb")
        return nil if stem.empty?

        # Separator-blind: the app's inflections read OAuthApplications as oauth_applications.
        squashed = stem.delete("_").downcase
        declared = DeclaredConstant.declarations(content, path_name: stem.camelize)
          .map { |d| d.name.to_s.split("::").last.to_s.downcase }
        declared.include?(squashed) ? stem : nil
      end

      def name_unnamed_tables(entries, name)
        unnamed = entries.select { |e| e[:table].nil? && (e[:action] == :create_table || e[:type] == :create_table) }
        unnamed.each { |e| e[:table] = name }
        unnamed.any?
      end

      # A guessed name with no column behind it is not a table: Tables::Base's
      # own create_table helper read as a table called `base`.
      def mark_inferred(tables, name, existed)
        data = tables[name] or return
        if data[:columns].any? { |column| !column[:primary_key] }
          data[:inferred_name] = true
        elsif !existed
          tables.delete(name)
        end
      end
    end
  end
end
