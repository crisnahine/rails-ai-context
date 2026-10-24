# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers migration files, pending migrations, and recent migration history.
    # Works without a database connection by parsing db/migrate/ filenames.
    class MigrationIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # @return [Hash] migration info including recent, pending, and stats
      def call
        info = {
          total: all_migrations.size,
          recent: recent_migrations(10),
          schema_version: current_schema_version,
          migration_stats: migration_stats
        }
        # No key at all when nothing says what has been applied - an empty
        # list would read as "up to date".
        pending = pending_migrations
        info[:pending] = pending if pending
        secondary = secondary_databases
        info[:secondary_databases] = secondary if secondary.any?
        info
      end

      private

      def migrate_dir
        @migrate_dir ||= RailsAiContext::PendingMigrations.migrate_dirs_for(root)
      end

      # The same file scan the pending derivation runs, with each file's
      # actions read on top.
      def all_migrations
        @all_migrations ||= RailsAiContext::PendingMigrations.migration_files(migrate_dir, root: root).map do |file|
          content = RailsAiContext::SafeFile.read(file[:path])

          {
            version: file[:version],
            name: file[:name],
            filename: File.basename(file[:path]),
            actions: content ? detect_migration_actions(content) : []
          }
        rescue => e
          { version: file[:version], name: File.basename(file[:path]), error: e.message }
        end
      end

      def recent_migrations(count)
        all_migrations.last(count).reverse
      end

      # Prefers the live database (the actual applied version set) and falls
      # back to the schema file's recorded version when it is unreachable
      # (CI, static analysis, no db:create yet).
      def pending_migrations
        RailsAiContext::PendingMigrations.live(migrate_dir) ||
          RailsAiContext::PendingMigrations.for(migrate_dir: migrate_dir, applied: applied_versions, root: root)
      end

      # structure.sql records the whole applied set, which catches an
      # out-of-order merge; schema.rb records only the newest version.
      def applied_versions
        RailsAiContext::SchemaVersion.applied(root) || current_schema_version
      rescue => e
        RailsAiContext.debug_fail(e, current_schema_version, label: "applied_versions")
      end

      def current_schema_version
        RailsAiContext::SchemaVersion.current(root)
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "current_schema_version")
      end

      # The other databases `db:migrate` runs, by database.yml name. Pending is what each one's dump
      # records. One that shares the primary's directories adds no files of its own.
      def secondary_databases
        RailsAiContext::AppDatabases.for(root).secondaries.each_with_object({}) do |db, found|
          dirs = db.migrate_dirs
          next if dirs == migrate_dir

          files = RailsAiContext::PendingMigrations.migration_files(dirs, root: root)
          next if files.empty?

          applied = RailsAiContext::SchemaVersion.recorded(db.dump&.format, db.dump&.path)
          pending = RailsAiContext::PendingMigrations.for(migrate_dir: dirs, applied: applied, root: root)
          found[db.name] = {
            total: files.size,
            migrations_paths: dirs.select { |dir| Dir.exist?(dir) }.map { |dir| dir.delete_prefix("#{root.chomp('/')}/") },
            pending: pending
          }.compact
        end
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "secondary_databases")
      end

      def migration_stats
        return {} if all_migrations.empty?

        by_year = all_migrations.group_by do |m|
          version = m[:version].to_s
          version.length >= 4 ? version[0..3] : "unknown"
        end

        {
          by_year: by_year.transform_values(&:count),
          total_create_table: all_migrations.count { |m| m[:actions]&.include?("create_table") },
          total_add_column: all_migrations.count { |m| m[:actions]&.include?("add_column") },
          total_add_index: all_migrations.count { |m| m[:actions]&.include?("add_index") }
        }
      end

      def detect_migration_actions(content)
        parsed = AstCache.parse_uncached(content)
        called = AstWalk.each(parsed.value).filter_map do |node|
          next unless node.is_a?(Prism::CallNode) && migration_receiver?(node.receiver)

          node.name == :remove_columns ? "remove_column" : node.name.to_s
        end.to_set
        %w[
          create_table drop_table rename_table
          add_column remove_column rename_column change_column
          change_column_default change_column_null
          add_index remove_index add_reference remove_reference
          add_foreign_key remove_foreign_key
          add_timestamps create_join_table enable_extension execute
          add_check_constraint remove_check_constraint
        ].select { |action| called.include?(action) } | change_table_actions(content, parsed)
      end

      # A migration forwards a bare call to its connection, so a call on self, a connection, or a local
      # holding one (`conn = connection`, `with_connection { |c| ... }`) is the same one.
      def migration_receiver?(receiver)
        receiver.nil? || receiver.is_a?(Prism::SelfNode) || receiver.is_a?(Prism::LocalVariableReadNode) ||
          (receiver.is_a?(Prism::CallNode) && %i[connection lease_connection].include?(receiver.name))
      end

      # What each table call in a change_table block does; a column type adds a column, any other call does nothing.
      CHANGE_TABLE_CALLS = {
        index: "add_index", remove_index: "remove_index", remove: "remove_column", remove_timestamps: "remove_column",
        remove_references: "remove_reference", remove_belongs_to: "remove_reference", references: "add_reference",
        belongs_to: "add_reference", timestamps: "add_timestamps", rename: "rename_column", change: "change_column",
        change_default: "change_column_default", change_null: "change_column_null", foreign_key: "add_foreign_key",
        remove_foreign_key: "remove_foreign_key", check_constraint: "add_check_constraint",
        remove_check_constraint: "remove_check_constraint"
      }.freeze
      COLUMN_CALLS = (Listeners::SchemaDslListener::COLUMN_TYPES.map(&:to_sym) + [ :column ] - CHANGE_TABLE_CALLS.keys).freeze

      # A table call counts only inside a change_table block: the listener links each call to the block that encloses it.
      def change_table_actions(content, parsed)
        return [] unless content.include?("change_table")

        hits = SourceIntrospector.walk_dispatch(parsed, {
          change_table: -> { Listeners::GenericMacroListener.new(:change_table, *CHANGE_TABLE_CALLS.keys, *COLUMN_CALLS, any_receiver: true) }
        })[:change_table]
        blocks = hits.select { |hit| hit[:macro] == :change_table }.to_set { |hit| hit[:offset] }
        return [] if blocks.empty?

        inside = hits.select { |hit| blocks.include?(hit[:parent_offset]) }
        [ "change_table" ] | inside.map { |hit| CHANGE_TABLE_CALLS.fetch(hit[:macro], "add_column") }
      end
    end
  end
end
