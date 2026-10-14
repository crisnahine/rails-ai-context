# frozen_string_literal: true

module RailsAiContext
  # What a database is by its adapter's name: PostgreSQL, MySQL or SQLite, else no family (ADR-0008).
  # A family also owns how its database runs a guarded read and the statistics other tools show.
  module DatabaseFamily
    # A statement ran past the timeout it was given.
    class TimedOut < RailsAiContext::Error; end

    # Another connection holds a lock on the database, so the statement did not run.
    class Busy < RailsAiContext::Error; end

    # The read cannot be guarded (an adapter with no family, a MySQL transaction already open), so nothing was sent.
    class Unsupported < RailsAiContext::Error; end

    # Rows from a guarded read; unbounded when no timeout could hold it.
    Rows = Data.define(:columns, :rows, :unbounded)

    Family = Data.define(:key, :name) do
      def known?
        key != :unknown
      end

      def postgresql?
        key == :postgresql
      end

      def mysql?
        key == :mysql
      end

      def sqlite?
        key == :sqlite
      end

      def implicit_pk_type
        sqlite? ? "integer" : "bigint"
      end

      # A statement is checked against its plan before it runs, and a result column is traced to its table column.
      def plan_checks?
        postgresql?
      end

      # The read-only transaction refuses FOR UPDATE and FOR SHARE itself.
      def refuses_locking_reads?
        postgresql?
      end

      # Every string literal in a statement can be told from its identifiers.
      def masks_literals?
        postgresql?
      end

      def dollar_quoting?
        postgresql?
      end

      # A block comment inside a block comment needs a closer of its own.
      def nested_comments?
        postgresql?
      end

      # `/*! ... */` holds text the database runs.
      def executable_comments?
        mysql?
      end

      # A backslash escapes the next character in every string.
      def backslash_escapes?
        mysql?
      end

      # @return [Regexp] a comment that runs to the end of its line: `#` too, and `--` only before a space, on MySQL
      def line_comment
        mysql? ? /--(?=\s|\z)[^\n]*|#[^\n]*/ : /--[^\n]*/
      end

      # @return [Rows] run in a read-only transaction, bounded by timeout seconds
      # @raise [TimedOut, Unsupported]
      def read_only(connection, sql, timeout:)
        runtime.read_only(connection, sql, timeout)
      end

      # Runs reads beside the statement so that each one ends at timeout seconds, a wait on a lock included.
      # @raise [TimedOut, Unsupported]
      def bounded(connection, timeout:, &reads)
        runtime.bounded(connection, timeout, &reads)
      end

      # @return [Hash] { scan_types:, warnings:, raw:, unbounded: }
      def explain(connection, sql, timeout:)
        runtime.explain(connection, sql, timeout)
      end

      # @raise [TimedOut, ActiveRecord::StatementInvalid] when PostgreSQL cannot plan the statement
      # @return [Hash, nil] the PostgreSQL JSON plan's top node; nil on other families or when the answer is no plan
      def plan(connection, sql, timeout:, generic: false)
        runtime.plan(connection, sql, timeout, generic: generic)
      end

      # @return [Array<Array(Integer, String, String)>] [result column index, table column, relation] from the
      #   plan; the column is nil where the relation's columns could not be read; [] where the family cannot say
      def column_sources(connection, sql, plan:)
        runtime.column_sources(connection, sql, plan)
      end

      # A schema read that is given no schemas reads at least what a statement reaches with no schema named:
      # the PostgreSQL search path, the MySQL connection's database, SQLite's main and temp.

      # @return [Array<String>] the schemas a statement reaches with no schema named, where the reads' own
      #   default does not cover them: SQLite's attached databases
      def unqualified_schemas(connection)
        runtime.unqualified_schemas(connection)
      end

      # @return [Array<String>] the names among these that are schemas a statement can read and the reads' own
      #   default does not cover. System schemas are left out.
      def schemas_named(connection, names)
        names.empty? ? [] : runtime.schemas_named(connection, names)
      end

      # @return [Hash{String => Array<String>}] relation name => its column names, from one catalogue read. On
      #   PostgreSQL also under `schema.relation`, where the bare name holds the columns of every schema read.
      def relation_columns(connection, schemas = [])
        runtime.relation_columns(connection, schemas)
      end

      # @return [Hash{String => String, nil}] view name => the definition the database stores, nil for one it
      #   will not show. On PostgreSQL also under `schema.view`, as traced_views names it too.
      def view_definitions(connection, schemas = [])
        runtime.view_definitions(connection, schemas)
      end

      # @return [Array<String>] the views whose result columns column_sources traces to their table columns
      def traced_views(connection, schemas = [])
        runtime.traced_views(connection, schemas)
      end

      # @return [Hash{String => Hash{String => String}}] table name => { generated column => its expression }
      def generated_columns(connection, schemas = [])
        runtime.generated_columns(connection, schemas)
      end

      # @return [Hash{String => Array}] what holds another table's rows or words under other names: table =>
      #   [:pages, :shadow, :vocabulary or :virtual, its virtual table, and for the last two kinds their definition]
      def index_tables(connection, schemas = [])
        runtime.index_tables(connection, schemas)
      end

      # Each setting the family sets for a statement, among those the text names, with the session's own value.
      # Read with no bound: reading a setting waits on no lock.
      # @return [Hash{String => String}]
      def own_settings(connection, text)
        runtime.bound_settings(connection).filter_map do |name, read|
          [ name, connection.select_value(read).to_s ] if text.match?(/\b#{name}\b/i)
        end.to_h
      end

      # @return [Array<Hash>, nil] { name:, bytes: } largest first; nil when the family has none
      def table_sizes(connection)
        runtime.table_sizes(connection)
      end

      # @return [Array<Hash>, nil] { table:, approximate_rows: } most rows first
      def row_estimates(connection)
        runtime.row_estimates(connection)
      end

      # @return [Array<Hash>, nil] { table:, index:, scans: } least used first
      def index_usage(connection)
        runtime.index_usage(connection)
      end

      private

      def runtime
        case key
        when :postgresql then PostgresqlRuntime
        when :mysql then MysqlRuntime
        when :sqlite then SqliteRuntime
        else
          raise Unsupported, "The #{name} adapter has no database family, so its read-only transaction " \
            "and statement timeout are not known. Supported: PostgreSQL, MySQL (with MariaDB) and SQLite."
        end
      end
    end

    POSTGRESQL = Family.new(:postgresql, "PostgreSQL")
    MYSQL = Family.new(:mysql, "MySQL")
    SQLITE = Family.new(:sqlite, "SQLite")

    # Live adapter_name values, database.yml adapters, URL schemes, display labels and dump dialects, downcased.
    NAMES = {
      "postgresql" => POSTGRESQL, "postgis" => POSTGRESQL, "postgres" => POSTGRESQL,
      "mysql2" => MYSQL, "trilogy" => MYSQL, "mysql" => MYSQL, "mariadb" => MYSQL,
      "sqlite3" => SQLITE, "sqlite" => SQLITE
    }.freeze

    DEFAULT_SUFFIX = " by database.yml default"

    # 3024 MySQL max_execution_time, 1317 query interrupted, 1969 MariaDB max_statement_time, 1205 lock_wait_timeout.
    TIMEOUT_CODES = [ 3024, 1317, 1969, 1205 ].freeze

    module_function

    # @param source [#adapter_name, #adapter, String, Symbol, nil]
    # @return [Family] never raises; no family carries the raw name
    def of(source)
      raw = raw_name(source)
      NAMES.fetch(raw.downcase.delete_suffix(DEFAULT_SUFFIX)) { Family.new(:unknown, raw.empty? ? "unknown" : raw) }
    end

    def raw_name(source)
      source = source.adapter_name if source.respond_to?(:adapter_name)
      source = source.adapter if source.respond_to?(:adapter)
      source.is_a?(String) || source.is_a?(Symbol) ? source.to_s : ""
    rescue StandardError
      ""
    end

    # @return [Hash{String => Array<Array>}] catalogue rows grouped by their first field, the table, without it
    def by_table(rows)
      rows.group_by(&:first).transform_values { |found| found.map { |row| row.drop(1) } }
    end

    # @return [Hash{String => String, nil}] [view, definition] rows by view. Views of one name in two schemas
    #   are read as one text, and as unreadable when either is.
    def by_view(rows)
      rows.group_by(&:first).transform_values { |found| found.map(&:last).then { |texts| texts.all? ? texts.join("\n") : nil } }
    end

    # Adds [table, generated column, expression] rows to found, as table => { column => expression }. Tables of one
    # name in two schemas keep every expression their columns of one name have.
    def keep_expressions(found, rows)
      rows.each_with_object(found) do |(table, column, expression), kept|
        (kept[table] ||= {}).merge!(column => expression.to_s) { |_column, known, read| known.include?(read) ? known : "#{known} #{read}" }
      end
    end

    BUSY = "The database is locked by another connection, so the query did not run. Run it again when the other connection has finished."

    # Runs the block and raises TimedOut for a database's timeout, Busy for a locked SQLite database. Message text is never read.
    def bounding
      yield
    rescue ActiveRecord::StatementInvalid => e
      raise Busy, BUSY if busy?(e)
      raise TimedOut, e.message if timed_out?(e)

      raise
    end

    # Puts a session setting back. A failed restore never replaces the caller's own error, and the
    # connection it left changed leaves the pool so no later statement inherits the setting.
    def restore(connection, statement)
      connection.execute(statement)
    rescue StandardError
      begin
        connection.respond_to?(:throw_away!) ? connection.throw_away! : connection.disconnect!
      rescue StandardError
        nil
      end
    end

    # A connection the server dropped: the caller's to answer, and no reason to fall back to another read.
    def lost_connection?(error)
      error.is_a?(ActiveRecord::ConnectionNotEstablished) ||
        (defined?(ActiveRecord::ConnectionFailed) && error.is_a?(ActiveRecord::ConnectionFailed))
    end

    # A SQLite read that found the database locked, at once or after the connection's busy timeout.
    # Rails 7.0 gives it no class of its own.
    def busy?(error)
      defined?(SQLite3::BusyException) && error.cause.is_a?(SQLite3::BusyException)
    end

    def timed_out?(error)
      # A connection the server dropped is a QueryAborted on Rails 7.1 and later, and it is no timeout.
      return false if defined?(ActiveRecord::ConnectionFailed) && error.is_a?(ActiveRecord::ConnectionFailed)
      return !canceled?(error.cause) if defined?(ActiveRecord::QueryAborted) && error.is_a?(ActiveRecord::QueryAborted)
      # A wait on a lock that the database's own lock timeout ended.
      return true if error.is_a?(ActiveRecord::LockWaitTimeout)

      TIMEOUT_CODES.include?(native_code(error))
    end

    # PostgreSQL gives its timeout and a cancel another session sent one error code, and only the server's
    # message tells them apart. A server that writes its messages in another language reads as the timeout.
    def canceled?(driver_error)
      result = driver_error.result if driver_error.respond_to?(:result)
      result.respond_to?(:error_field) && result.error_field(PG::PG_DIAG_MESSAGE_PRIMARY).to_s.end_with?("due to user request")
    end

    # @return [Integer, nil] the MySQL or MariaDB error number the driver's error carries
    def native_code(error)
      cause = error.cause
      if cause.respond_to?(:error_number) then cause.error_number
      elsif cause.respond_to?(:error_code) then cause.error_code
      end
    end
  end
end
