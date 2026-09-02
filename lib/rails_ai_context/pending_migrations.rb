# frozen_string_literal: true

module RailsAiContext
  # Which migration files have not been applied. Three derivations gave two
  # answers: one compared each file against the newest applied version, so a
  # migration merged out of order was never pending in the generated context
  # while the schema tool counted it.
  module PendingMigrations
    module_function

    # applied: the applied versions, a single newest version, or nil when
    # nothing is known (every file is then pending).
    def for(migrate_dir:, applied: nil)
      files = migration_files(migrate_dir)
      case applied
      when Array
        known = applied.map(&:to_i)
        files.reject { |m| known.include?(m[:version].to_i) }
      when String, Integer
        newest = applied.to_i
        files.select { |m| m[:version].to_i > newest }
      else
        files
      end
    end

    # The connection's answer; nil when there is no database to ask.
    def live(migrate_dir)
      MigrationStatus.pending(migrate_dir)
    end

    # Each secondary database keeps its own migrate directory, so a secondary
    # dump compared against db/migrate would report the primary's files.
    def migrate_dir_for(root, dump_path = nil)
      base = dump_path ? File.basename(dump_path.to_s).sub(/_?schema\.rb\z|_?structure\.sql\z/, "") : ""
      File.join(root.to_s, "db", base.empty? ? "migrate" : "#{base}_migrate")
    end

    def migration_files(migrate_dir)
      return [] unless migrate_dir && Dir.exist?(migrate_dir)

      Dir.glob(File.join(migrate_dir, "*.rb")).sort.filter_map do |path|
        base = File.basename(path, ".rb")
        version = base[/\A\d+/] or next
        { version: version, name: base.sub(/\A\d+_/, "").tr("_", " ").capitalize }
      end
    end
    private_class_method :migration_files
  end
end
