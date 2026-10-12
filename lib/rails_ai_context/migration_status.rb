# frozen_string_literal: true

module RailsAiContext
  # Resolves pending-migration status the way Rails' own
  # MigrationContext#needs_migration? reads it, and without writing: the
  # migration files Rails loads, minus the versions schema_migrations holds
  # (none when the table is not there). MigrationContext#open, which the
  # "Migrations are pending" page walks, builds a Migrator, and building one
  # creates schema_migrations and ar_internal_metadata in a database that
  # lacks them.
  #
  # The MigrationContext itself moved from the connection object to the
  # connection pool between Rails 7.0 and 7.1, and from 7.1 on it takes a
  # schema_migration + internal_metadata pair - so a single hardcoded
  # construction path breaks on part of the range this gem supports. The
  # respond_to? cascade below picks whichever construction the loaded
  # ActiveRecord version actually exposes instead of guessing from a version
  # number.
  module MigrationStatus
    # @param migrate_dir [String, Array<String>] the migrations directories to check
    # @return [Array<Hash>, nil] [{ version:, name: }, ...] in pending order,
    #   or nil when pending status can't be determined (no migrations
    #   directory, ActiveRecord not loaded, or the database is unreachable).
    def self.pending(migrate_dir)
      dirs = Array(migrate_dir).select { |dir| Dir.exist?(dir) }
      return nil if dirs.empty? || !defined?(ActiveRecord::Base)
      # A database that is not there yet, said without creating its file.
      return nil if DatabaseFile.missing(ActiveRecord::Base.connection_db_config)

      pending_in(migration_context(dirs), dirs)
    rescue => e
      RailsAiContext.debug_fail(e, nil, label: "MigrationStatus.pending")
    end

    # One database's pending migrations, as `db:migrate:status:<name>` reads
    # them: from that database's own schema_migrations, through its pool.
    # AppDatabases::Database#pending_migrations leases the pool.
    def self.pending_on(pool, migrate_dir)
      dirs = Array(migrate_dir).select { |dir| Dir.exist?(dir) }
      dirs.empty? ? [] : pending_in(migration_context(dirs, pool), dirs)
    end

    def self.pending_in(context, dirs)
      applied = context.get_all_versions
      context.migrations.reject { |m| applied.include?(m.version) }.map { |m| { version: m.version.to_s, name: m.name } }
    rescue ActiveRecord::MigrationError
      # A version Rails will not load (one past tomorrow, a name it cannot
      # read) stops it reading the directory; the applied set still answers.
      PendingMigrations.for(migrate_dir: dirs, applied: context.get_all_versions)
    end

    # @return [ActiveRecord::MigrationContext]
    def self.migration_context(migrate_dir, pool = ActiveRecord::Base.connection_pool)
      # Rails 7.2+: MigrationContext takes a schema_migration + internal_metadata
      # pair (per-connection bookkeeping objects) that only the pool knows how
      # to build - construct explicitly with OUR migrate_dir rather than
      # calling pool.migration_context directly, since that resolves its own
      # migrations_paths relative to the process's working directory, which
      # isn't guaranteed to equal Rails.root (daemonized servers, this gem's
      # own test suite).
      if pool.respond_to?(:schema_migration) && pool.respond_to?(:internal_metadata)
        return ActiveRecord::MigrationContext.new(migrate_dir, pool.schema_migration, pool.internal_metadata)
      end

      # Rails 7.1 keeps the pair on the connection, and Rails 7.0 the
      # schema_migration alone - construct with OUR migrate_dir for the same
      # reason as above. The connection's own migration_context resolves the
      # app's configured migrations_paths and ignores the directory being
      # asked about, silently reporting zero pending migrations.
      connection = pool.connection
      if connection.respond_to?(:internal_metadata)
        return ActiveRecord::MigrationContext.new(migrate_dir, connection.schema_migration, connection.internal_metadata)
      end

      ActiveRecord::MigrationContext.new(migrate_dir, connection.schema_migration)
    end
  end
end
