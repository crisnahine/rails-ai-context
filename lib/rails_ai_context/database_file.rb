# frozen_string_literal: true

module RailsAiContext
  # A SQLite database is a file, and connecting to one that is not there
  # creates it: the driver opens a path it cannot find by making an empty
  # database at it. Reading the app must not do that. The empty file reads
  # as a database with every migration pending, and `db:prepare` then
  # migrates it from nothing where it would have loaded the schema and the
  # seeds. So a SQLite database whose file is missing is said to be missing
  # before anything connects to it.
  module DatabaseFile
    # The error a connection to db_config would meet if SQLite did not
    # create the file, or nil: for a file that is there, for :memory: and a
    # file: URI (SQLite's own to open), and for every other adapter.
    def self.missing(db_config)
      return nil unless db_config.respond_to?(:adapter) && db_config.adapter.to_s == "sqlite3"

      database = db_config.database.to_s
      return nil if database.empty? || database == ":memory:" || database.start_with?("file:")
      # Relative to Rails.root, as the adapter reads it.
      return nil if File.exist?(File.expand_path(database, defined?(Rails.root) ? Rails.root : nil))

      ActiveRecord::NoDatabaseError.db_error(database)
    end
  end
end
