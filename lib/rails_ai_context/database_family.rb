# frozen_string_literal: true

module RailsAiContext
  # What a database is by its adapter's name: PostgreSQL, MySQL or SQLite, else no family (ADR-0008).
  # A family also owns how its database runs a guarded read and the statistics other tools show.
  module DatabaseFamily
    # A statement ran past the timeout it was given.
    class TimedOut < RailsAiContext::Error; end

    # The adapter has no family, so nothing was sent to its database.
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

      # Runs a block of reads beside the statement (the schema, a plan check) under the family's limit,
      # so each statement in it ends at timeout seconds, a wait on a lock included.
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
      def plan(connection, sql, timeout:)
        runtime.plan(connection, sql, timeout)
      end

      # @param plan [Hash, nil] the statement's plan, when one was read already
      # @return [Array<Array(Integer, String, String)>] [result column index, the table column it reads, its relation];
      #   the column is nil when the relation's columns could not be read, the relation nil when it is unknown too;
      #   [] where the family cannot say
      def column_sources(connection, sql, plan:)
        runtime.column_sources(connection, sql, plan)
      end

      # @return [Hash{String => Array<String>}] table name => its column names, from one catalogue read
      def relation_columns(connection)
        runtime.relation_columns(connection)
      end

      # @return [Hash{String => String, nil}, nil] view name => the definition the database stores, nil for one it
      #   will not show; nil where column_sources traces a view's columns to their table columns
      def view_definitions(connection)
        runtime.view_definitions(connection)
      end

      # @return [Hash{String => Hash{String => String}}] table name => { generated column => its expression }
      def generated_columns(connection)
        runtime.generated_columns(connection)
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

    # Runs the block and raises TimedOut for a database's timeout. Message text is never read.
    def bounding
      yield
    rescue ActiveRecord::StatementInvalid => e
      raise TimedOut, e.message if timed_out?(e)

      raise
    end

    def timed_out?(error)
      return true if defined?(ActiveRecord::QueryAborted) && error.is_a?(ActiveRecord::QueryAborted)

      cause = error.cause
      # A SQLite read that waited out the connection's busy timeout. Rails 7.0 gives it no class of its own.
      return true if defined?(SQLite3::BusyException) && cause.is_a?(SQLite3::BusyException)

      code = if cause.respond_to?(:error_number) then cause.error_number
      elsif cause.respond_to?(:error_code) then cause.error_code
      end
      TIMEOUT_CODES.include?(code)
    end
  end
end
