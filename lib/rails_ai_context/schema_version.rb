# frozen_string_literal: true

module RailsAiContext
  # Reads the applied schema version without a database connection.
  #
  # db/schema.rb (config.active_record.schema_format = :ruby, the default)
  # carries the version as a `version: X` keyword on the ActiveRecord::Schema
  # define call.
  #
  # db/structure.sql (schema_format = :sql) has no such line - Rails instead
  # writes every applied migration version into an `INSERT INTO
  # schema_migrations (version) VALUES (...)` block at the bottom of the dump
  # (mysqldump quotes the table name with backticks, pg_dump with double
  # quotes; the version literals themselves are always single-quoted).
  module SchemaVersion
    def self.current(root)
      schema_path = File.join(root, "db", "schema.rb")
      if File.exist?(schema_path)
        version = from_schema_rb(schema_path)
        return version if version
      end

      structure_path = File.join(root, "db", "structure.sql")
      return from_structure_sql(structure_path) if File.exist?(structure_path)

      nil
    end

    def self.from_schema_rb(path)
      content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
      return nil unless content

      match = content.match(/version:\s*([\d_]+)/)
      match ? match[1].delete("_") : nil
    end

    def self.from_structure_sql(path)
      content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
      return nil unless content

      match = content.match(/INSERT INTO\s+[`"]?schema_migrations[`"]?\s*\(version\)\s*VALUES\s*(.+?);/mi)
      return nil unless match

      versions = match[1].scan(/'(\d+)'/).flatten
      return nil if versions.empty?

      # Versions are timestamps (14 digits) padded consistently, but compare
      # numerically rather than lexically in case an old app still has
      # pre-timestamp (short integer) migration versions mixed in.
      versions.map(&:to_i).max.to_s
    end
  end
end
