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

            content = File.read(path)
            actions = detect_migration_actions(content)

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

      # Detect pending migrations by comparing against schema version
      def pending_migrations
        if defined?(ActiveRecord::Base) && ActiveRecord::Base.connection_pool.connected?
          begin
            context = ActiveRecord::MigrationContext.new(migrate_dir)
            if context.respond_to?(:pending_migrations)
              return context.pending_migrations.map do |m|
                { version: m.version.to_s, name: m.name }
              end
            end
          rescue => _e
            # Fall through to file-based detection
          end
        end

        schema_ver = current_schema_version
        return [] unless schema_ver

        all_migrations.select { |m| m[:version].to_i > schema_ver.to_i }.map do |m|
          { version: m[:version], name: m[:name] }
        end
      end

      def current_schema_version
        schema_path = File.join(root, "db/schema.rb")
        return nil unless File.exist?(schema_path)

        content = File.read(schema_path)
        match = content.match(/version:\s*([\d_]+)/)
        match ? match[1].delete("_") : nil
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
          add_index remove_index add_reference remove_reference
          add_foreign_key remove_foreign_key
          add_timestamps create_join_table enable_extension execute
        ].select { |action| content.include?(action) }
      end
    end
  end
end
