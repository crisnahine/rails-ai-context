# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers migration files, pending migrations, and recent migration history.
    # Works without a database connection by parsing db/migrate/ filenames.
    class MigrationIntrospector
      extend StaticTier
      static_tier :files_only

      attr_reader :app

      def initialize(app)
        @app = app
      end

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
        info
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def migrate_dir
        File.join(root, "db/migrate")
      end

      # The same file scan the pending derivation runs, with each file's
      # actions read on top.
      def all_migrations
        @all_migrations ||= RailsAiContext::PendingMigrations.migration_files(migrate_dir).map do |file|
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
          RailsAiContext::PendingMigrations.for(migrate_dir: migrate_dir, applied: applied_versions)
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
