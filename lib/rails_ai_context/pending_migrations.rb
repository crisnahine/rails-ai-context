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
    def for(migrate_dir:, applied: nil)
      return nil if applied.nil?

      files = migration_files(migrate_dir)
      unapplied = if applied.is_a?(Array)
        known = applied.map(&:to_i)
        files.reject { |m| known.include?(m[:version].to_i) }
      else
        newest = applied.to_i
        files.select { |m| m[:version].to_i > newest }
      end
      unapplied.map { |m| { version: m[:version], name: m[:name] } }
    end

    # The connection's answer; nil when there is no database to ask.
    def live(migrate_dir)
      MigrationStatus.pending(migrate_dir)
    end

    # Each secondary database keeps its own migrate directory, so a secondary
    # dump compared against db/migrate would report the primary's files.
    def migrate_dir_for(root, dump_path = nil)
      base = if dump_path
        File.basename(dump_path.to_s).sub(/\.(rb|sql)\z/, "").sub(/_?(schema|structure)\z/, "")
      else
        ""
      end
      File.join(root.to_s, "db", base.empty? ? "migrate" : "#{base}_migrate")
    end

    # Every versioned migration file in the directory. One file scan behind
    # both the pending derivation and the migrations listing, so the two
    # cannot disagree on which files count.
    def migration_files(migrate_dir)
      return [] unless migrate_dir && Dir.exist?(migrate_dir)

      Dir.glob(File.join(migrate_dir, "*.rb")).sort.filter_map do |path|
        base = File.basename(path, ".rb")
        version = base[/\A\d+/] or next
        # The class name, so a static entry names the migration the way the
        # connection's own pending list does.
        name = base.sub(/\A\d+_/, "").camelize
        { version: version, name: name, path: path }
      end
    end
  end
end
