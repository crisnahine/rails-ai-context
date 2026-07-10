# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers migration files, pending migrations, and recent migration history.
    # Works without a database connection by parsing db/migrate/ filenames.
    class MigrationIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] migration info including recent, pending, and stats
      def call
        {
          total: all_migrations.size,
          recent: recent_migrations(10),
          pending: pending_migrations,
          schema_version: current_schema_version,
          migration_stats: migration_stats
        }
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

      # Parse all migration files from db/migrate/
      def all_migrations
        @all_migrations ||= begin
          return [] unless Dir.exist?(migrate_dir)

          Dir.glob(File.join(migrate_dir, "*.rb")).sort.map do |path|
            filename = File.basename(path, ".rb")
            version = filename.split("_").first
            name = filename.sub(/\A\d+_/, "").tr("_", " ").capitalize

            content = RailsAiContext::SafeFile.read(path)
            actions = content ? detect_migration_actions(content) : []

            {
              version: version,
              name: name,
              filename: File.basename(path),
              actions: actions
            }
          rescue => e
            { version: "unknown", name: File.basename(path), error: e.message }
          end
        end
      end

      def recent_migrations(count)
        all_migrations.last(count).reverse
      end

      # Detect pending migrations. Prefers the live DB (authoritative - the
      # actual applied version set) and falls back to comparing migration
      # filenames against the schema file's recorded version when the
      # database is unreachable (CI, static analysis, no db:create yet).
      def pending_migrations
        live = RailsAiContext::MigrationStatus.pending(migrate_dir)
        return live if live

        schema_ver = current_schema_version
        return [] unless schema_ver

        all_migrations.select { |m| m[:version].to_i > schema_ver.to_i }.map do |m|
          { version: m[:version], name: m[:name] }
        end
      end

      def current_schema_version
        RailsAiContext::SchemaVersion.current(root)
      rescue => e
        $stderr.puts "[rails-ai-context] current_schema_version failed: #{e.message}" if ENV["DEBUG"]
        nil
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
