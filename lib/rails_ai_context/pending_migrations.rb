# frozen_string_literal: true

module RailsAiContext
  # Which migration files have not been applied, decided by membership in the
  # applied set rather than by comparison against the newest applied version.
  # A migration merged out of order is older than the newest and still
  # pending, so only the set answers it.
  module PendingMigrations
    module_function

    # applied: the applied versions, a single newest version, or nil when
    # nothing is known. Unknown answers nil - an empty Array is the different
    # claim that nothing has been applied, and every file is then pending.
    def for(migrate_dir:, applied: nil, root: nil)
      return nil if applied.nil?

      files = migration_files(migrate_dir, root: root)
      unapplied = if applied.is_a?(Array)
        known = applied.map(&:to_i)
        files.reject { |m| known.include?(m[:version].to_i) }
      else
        newest = applied.to_i
        files.select { |m| m[:version].to_i > newest }
      end
      unapplied.map { |m| { version: m[:version], name: m[:name] } }
    end

    # The connection's answer; nil when there is no database to ask. The schema
    # and migrations sections both ask, so a run queries once.
    def live(migrate_dir)
      RunCache.fetch([ :pending_migrations, migrate_dir.to_s ]) { MigrationStatus.pending(migrate_dir) }
    end

    # The entry's migrations_paths, else db/migrate as Rails runs it; a dump with no entry here takes the generator's db/<name>_migrate.
    # Only the dirs Rails migrates: an engine's renumbered copy in db/migrate would read as pending.
    def migrate_dirs_for(root, dump_path = nil)
      name = Introspectors::SchemaDumpPath.database_name(root, dump_path)
      entry = RailsAiContext::DatabaseYml.entry(root, name)
      Introspectors::MigrationReplay.configured_dirs(root, entry) ||
        [ File.join(root.to_s, "db", name == "primary" || entry ? "migrate" : "#{name}_migrate") ]
    end

    # Every versioned migration file under the directory or directories. One file scan behind
    # both the pending derivation and the migrations listing, so the two
    # cannot disagree on which files count.
    def migration_files(migrate_dir, root: nil)
      dirs = Array(migrate_dir).select { |dir| Dir.exist?(dir) }
      Introspectors::MigrationReplay.migration_files(dirs, root: root).filter_map do |path|
        base = File.basename(path, ".rb")
        version = base[/\A\d+/] or next
        # The class name, so a static entry names the migration the way the
        # connection's own pending list does; Rails drops an engine's ".scope" suffix.
        name = base.sub(/\A\d+_/, "").split(".", 2).first.to_s.camelize
        { version: version, name: name, path: path }
      end
    end
  end
end
