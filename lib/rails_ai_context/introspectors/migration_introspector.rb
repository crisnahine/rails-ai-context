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

      # The other databases `db:migrate` runs here, each from its own
      # migrations_paths, keyed by database.yml name. Pending is what the
      # database's dump records, as the schema section reads that database;
      # one that shares the primary's directories adds no files of its own.
      def secondary_databases
        dumps = SchemaDumpPath.secondaries(root)
        RailsAiContext::DatabaseYml.task_secondaries(root).each_with_object({}) do |(name, entry), found|
          dirs = MigrationReplay.configured_dirs(root, entry)
          next if dirs.nil? || dirs == migrate_dir

          files = RailsAiContext::PendingMigrations.migration_files(dirs, root: root)
          next if files.empty?

          format, dump = dumps[name]
          pending = RailsAiContext::PendingMigrations.for(migrate_dir: dirs, applied: RailsAiContext::SchemaVersion.recorded(format, dump), root: root)
          found[name] = {
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
        %w[
          create_table drop_table rename_table
          add_column remove_column rename_column change_column
          change_column_default change_column_null
          add_index remove_index add_reference remove_reference
          add_foreign_key remove_foreign_key
          add_timestamps create_join_table enable_extension execute
          add_check_constraint remove_check_constraint
        ].select { |action| content.include?(action) }
      end
    end
  end
end
