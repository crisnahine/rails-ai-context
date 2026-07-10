# frozen_string_literal: true

module RailsAiContext
  # Resolves pending-migration status the same way Rails itself does for the
  # "Migrations are pending" dev error page (ActiveRecord::Migration.check_pending!
  # walks pool.migration_context.open.pending_migrations). MigrationContext moved
  # from the connection object to the connection pool between Rails 7.0 and 7.1,
  # and ActiveRecord::Migrator.new's signature changed to require a schema_migration
  # + internal_metadata pair it can no longer build on its own - so a single
  # hardcoded construction path breaks on part of the range this gem supports.
  # The respond_to? cascade below picks whichever construction the loaded
  # ActiveRecord version actually exposes instead of guessing from a version
  # number.
  module MigrationStatus
    # @param migrate_dir [String] path to the migrations directory to check
    # @return [Array<Hash>, nil] [{ version:, name: }, ...] in pending order,
    #   or nil when pending status can't be determined (no migrations
    #   directory, ActiveRecord not loaded, or the database is unreachable).
    def self.pending(migrate_dir)
      return nil unless migrate_dir && Dir.exist?(migrate_dir)
      return nil unless defined?(ActiveRecord::Base)

      context = migration_context(migrate_dir)
      context.open.pending_migrations.map { |m| { version: m.version.to_s, name: m.name } }
    rescue => e
      $stderr.puts "[rails-ai-context] MigrationStatus.pending failed: #{e.message}" if ENV["DEBUG"]
      nil
    end

    # @return [ActiveRecord::MigrationContext]
    def self.migration_context(migrate_dir)
      pool = ActiveRecord::Base.connection_pool

      # Rails 7.1+: MigrationContext takes a schema_migration + internal_metadata
      # pair (per-connection bookkeeping objects) that only the pool knows how
      # to build - construct explicitly with OUR migrate_dir rather than
      # calling pool.migration_context directly, since that resolves its own
      # migrations_paths relative to the process's working directory, which
      # isn't guaranteed to equal Rails.root (daemonized servers, this gem's
      # own test suite).
      if pool.respond_to?(:schema_migration) && pool.respond_to?(:internal_metadata)
        return ActiveRecord::MigrationContext.new(migrate_dir, pool.schema_migration, pool.internal_metadata)
      end

      # Rails 7.0: migration_context lived on the connection, not the pool.
      conn = ActiveRecord::Base.connection
      return conn.migration_context if conn.respond_to?(:migration_context)

      ActiveRecord::MigrationContext.new(migrate_dir)
    end
  end
end
