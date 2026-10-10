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
    # @param migrate_dir [String, Array<String>] the migrations directories to check
    # @return [Array<Hash>, nil] [{ version:, name: }, ...] in pending order,
    #   or nil when pending status can't be determined (no migrations
    #   directory, ActiveRecord not loaded, or the database is unreachable).
    def self.pending(migrate_dir)
      dirs = Array(migrate_dir).select { |dir| Dir.exist?(dir) }
      return nil if dirs.empty? || !defined?(ActiveRecord::Base)

      pending_in(migration_context(dirs), dirs)
    rescue => e
      RailsAiContext.debug_fail(e, nil, label: "MigrationStatus.pending")
    end

    # One database's pending migrations, as `db:migrate:status:<name>` reads
    # them: from that database's own schema_migrations, through a pool of its
    # own that is removed after, so the app's connections are left as they
    # are. The primary is asked through the app's own pool. The connection is
    # made first, so a database that does not exist, or a server that does
    # not answer, says so rather than reading as nothing pending.
    #
    # @param db_config [ActiveRecord::DatabaseConfigurations::DatabaseConfig]
    # @return [Hash] { pending: [{ version:, name: }, ...] }, or { error: exception }
    def self.of_database(db_config, migrate_dir, primary: false)
      dirs = Array(migrate_dir).select { |dir| Dir.exist?(dir) }
      with_pool(db_config, primary: primary) do |pool|
        pool.with_connection(&:verify!)
        { pending: dirs.empty? ? [] : pending_in(migration_context(dirs, pool), dirs) }
      end
    rescue StandardError => e
      { error: e }
    end

    def self.pending_in(context, dirs)
      context.open.pending_migrations.map { |m| { version: m.version.to_s, name: m.name } }
    rescue ActiveRecord::MigrationError
      # A future or duplicate version stops Rails loading the directory; the applied set still answers.
      PendingMigrations.for(migrate_dir: dirs, applied: context.get_all_versions)
    end

    # What a pool established for another database belongs to: Rails names a
    # pool by its owner, and an owner that is no primary class leaves the
    # app's own pools alone (ActiveRecord::PendingMigrationConnection, which
    # Rails 7.0 lacks and 7.1 shapes differently).
    class TemporaryOwner
      def self.primary_class?
        false
      end

      def self.current_preventing_writes
        false
      end
    end

    def self.with_pool(db_config, primary:)
      return yield(ActiveRecord::Base.connection_pool) if primary

      handler = ActiveRecord::Base.connection_handler
      begin
        yield handler.establish_connection(db_config, owner_name: TemporaryOwner)
      ensure
        handler.remove_connection_pool(TemporaryOwner.name)
      end
    end
    private_class_method :with_pool

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
