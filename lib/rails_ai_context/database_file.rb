# frozen_string_literal: true

require "uri"

module RailsAiContext
  # A SQLite database is a file, and connecting to one that is not there
  # creates it: the driver opens a path it cannot find by making an empty
  # database at it. Reading the app must not do that. The empty file reads
  # as a database with every migration pending, and `db:prepare` then
  # migrates it from nothing where it would have loaded the schema and the
  # seeds. So a SQLite database whose file is missing is said to be missing
  # before anything connects to it.
  module DatabaseFile
    MEMORY = ":memory:"

    # The error a connection would meet if SQLite did not create the file. nil for a file
    # that is there, a database in memory and every other adapter.
    def self.missing(db_config)
      ActiveRecord::NoDatabaseError.db_error(db_config.database.to_s) if missing?(db_config)
    end

    def self.missing?(db_config)
      path = path(db_config)
      !path.nil? && !File.exist?(path)
    end

    # A SQLite database with no file: every connection to one opens a new, empty database.
    def self.in_memory?(db_config)
      return false unless DatabaseFamily.of(db_config).sqlite?

      database = db_config.database.to_s
      database == MEMORY || (uri?(database) && (uri_path(database) == MEMORY || database.match?(/[?&]mode=memory(?:&|#|\z)/)))
    end

    # Whether this SQLite build reads a `file:` name as a URI. One compiled without USE_URI opens it as a plain file name.
    def self.sqlite_reads_uris?
      return @uris if defined?(@uris)
      return true unless defined?(SQLite3::Database)

      db = SQLite3::Database.new(MEMORY)
      @uris = db.execute("PRAGMA compile_options").flatten.any? { |option| option.to_s.match?(/\AUSE_URI(?:=1)?\z/) }
    rescue StandardError
      true
    ensure
      db&.close
    end

    def self.uri?(database)
      database.start_with?("file:") && sqlite_reads_uris?
    end
    private_class_method :uri?

    # A SQLite file name the adapter reads from the app's root. SQLite itself opens a `file:` name.
    def self.root_relative?(db_config)
      database = db_config.database.to_s
      DatabaseFamily.of(db_config).sqlite? && !database.empty? && !in_memory?(db_config) &&
        !database.start_with?("file:") && !SafePath.absolute?(database)
    end

    # The file a SQLite database is, or nil when it is none.
    def self.path(db_config)
      return nil unless DatabaseFamily.of(db_config).sqlite?

      database = db_config.database.to_s
      return nil if database.empty? || in_memory?(db_config)
      # SQLite opens a `file:` name from the working directory: the URI's path, or the whole name where it reads no URIs.
      return File.expand_path(uri?(database) ? uri_path(database) : database) if database.start_with?("file:")

      # Relative to Rails.root, as the adapter reads it.
      File.expand_path(database, defined?(Rails.root) ? Rails.root : nil)
    end

    # file:path, file:/path, file:///path and file://localhost/path, less the query and the fragment.
    def self.uri_path(uri)
      path = uri.delete_prefix("file:").sub(/[?#].*\z/m, "").sub(%r{\A//[^/]*}, "")
      URI::DEFAULT_PARSER.unescape(path)
    end
    private_class_method :uri_path
  end
end
