# frozen_string_literal: true

module RailsAiContext
  module DatabaseFamily
    # MySQL bounds a statement with the session max_execution_time, which also holds a WITH or EXPLAIN ANALYZE.
    # MariaDB has no max_execution_time; its session max_statement_time does the same.
    module MysqlRuntime
      module_function

      def read_only(conn, sql, timeout)
        result = bounded(conn, timeout) { in_read_only_transaction(conn, sql) }
        Rows.new(result.columns, result.rows, false)
      end

      # The statement limit does not cover SHOW, so lock_wait_timeout (whole seconds) ends a wait on a
      # metadata lock. Both session values are read first and put back after the block.
      def bounded(conn, timeout)
        limit, value = if mariadb?(conn) then [ "max_statement_time", [ timeout.to_f, 0.001 ].max ]
        else [ "max_execution_time", [ (timeout * 1000).to_i, 1 ].max ]
        end
        DatabaseFamily.bounding do
          previous = conn.select_rows("SELECT @@SESSION.#{limit}, @@SESSION.lock_wait_timeout").first
          begin
            conn.execute("SET SESSION #{limit} = #{value}, lock_wait_timeout = #{[ timeout.ceil, 1 ].max}")
            yield
          ensure
            DatabaseFamily.restore(conn, "SET SESSION #{limit} = #{previous[0]}, lock_wait_timeout = #{previous[1]}")
          end
        end
      end

      # MySQL rejects SET TRANSACTION once a transaction is open, and Rails opens the lazy BEGIN
      # before the first statement in the block. Unscoped, it applies to the next transaction only.
      def in_read_only_transaction(conn, sql)
        result = nil
        conn.execute("SET TRANSACTION READ ONLY")
        conn.transaction do
          result = conn.select_all(sql)
          raise ActiveRecord::Rollback
        end
        result
      end

      # Rails 7.1+ answers mariadb?; the server version is the fallback.
      def mariadb?(conn)
        return conn.mariadb? if conn.respond_to?(:mariadb?)

        conn.select_value("SELECT VERSION()").to_s.include?("MariaDB")
      rescue StandardError
        false
      end

      def explain(conn, sql, timeout)
        # MySQL 8.3+ defaults to TREE output, which has no table/type/key columns. MariaDB has no FORMAT=TRADITIONAL.
        prefix = mariadb?(conn) ? "EXPLAIN" : "EXPLAIN FORMAT=TRADITIONAL"
        result = read_only(conn, "#{prefix} #{sql}", timeout)
        scans = []
        warnings = []
        raw_lines = result.rows.map do |row|
          cols = result.columns.zip(row).to_h
          table = cols["table"]
          rows = cols["rows"].to_i
          extra = cols["Extra"].to_s
          # A row with no table ("No tables used") scans nothing.
          if table
            scans << { table: table, type: scan_label(cols["type"]), index: cols["key"] }
            warnings << "Full table scan on #{table} (#{rows} rows)" if cols["type"] == "ALL" && rows > 1000
            warnings << "Using filesort on #{table}" if extra.include?("filesort")
            warnings << "Using temporary table on #{table}" if extra.include?("temporary")
          end
          cols.map { |k, v| "#{k}: #{v}" }.join(", ")
        end
        { scan_types: scans, warnings: warnings, raw: raw_lines.join("\n"), unbounded: false }
      end

      def scan_label(type)
        case type
        when "ALL" then "full table scan"
        when "index" then "full index scan"
        when "range" then "index range scan"
        when "ref", "eq_ref" then "index lookup"
        when "const", "system" then "constant lookup"
        else type.to_s
        end
      end

      def column_sources(_conn, _sql, _plan)
        []
      end

      def plan(_conn, _sql, _timeout)
        nil
      end

      def relation_columns(conn)
        conn.select_rows(
          "SELECT c.TABLE_NAME, c.COLUMN_NAME FROM information_schema.COLUMNS c JOIN information_schema.TABLES t " \
          "ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME " \
          "WHERE c.TABLE_SCHEMA = DATABASE() AND t.TABLE_TYPE = 'BASE TABLE' ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION"
        ).each_with_object({}) { |(table, column), found| (found[table] ||= []) << column }
      end

      # The definition is empty for a view the account may not SHOW.
      def view_definitions(conn)
        conn.select_rows("SELECT TABLE_NAME, VIEW_DEFINITION FROM information_schema.VIEWS WHERE TABLE_SCHEMA = DATABASE()").to_h
      end

      def generated_columns(conn)
        conn.select_rows(
          "SELECT TABLE_NAME, COLUMN_NAME, GENERATION_EXPRESSION FROM information_schema.COLUMNS " \
          "WHERE TABLE_SCHEMA = DATABASE() AND GENERATION_EXPRESSION <> ''"
        ).each_with_object({}) { |(table, column, expression), found| (found[table] ||= {})[column] = expression }
      end

      # Base tables only: a view has no rows or bytes of its own.
      BASE_TABLES = "FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'"

      def table_sizes(conn)
        conn.select_all("SELECT TABLE_NAME AS name, (DATA_LENGTH + INDEX_LENGTH) AS bytes #{BASE_TABLES}")
          .map { |r| { name: r["name"], bytes: r["bytes"].to_i } }
          .sort_by { |r| [ -r[:bytes], r[:name] ] }
      end

      def row_estimates(conn)
        conn.select_all("SELECT TABLE_NAME AS table_name, TABLE_ROWS AS approximate_row_count #{BASE_TABLES}")
          .map { |r| { table: r["table_name"], approximate_rows: r["approximate_row_count"].to_i } }
          .sort_by { |t| [ -t[:approximate_rows], t[:table] ] }
      end

      def index_usage(_conn)
        nil
      end
    end
  end
end
