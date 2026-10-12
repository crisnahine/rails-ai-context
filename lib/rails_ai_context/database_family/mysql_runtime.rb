# frozen_string_literal: true

module RailsAiContext
  module DatabaseFamily
    # MySQL bounds a statement with the session max_execution_time, which also holds a WITH or EXPLAIN ANALYZE.
    # MariaDB has no max_execution_time, so it scopes max_statement_time to the statement.
    module MysqlRuntime
      module_function

      def read_only(conn, sql, timeout)
        result = DatabaseFamily.bounding do
          if mariadb?(conn)
            in_read_only_transaction(conn, "SET STATEMENT max_statement_time = #{[ timeout.to_f, 0.001 ].max} FOR #{sql}")
          else
            previous = conn.select_value("SELECT @@SESSION.max_execution_time").to_i
            conn.execute("SET SESSION max_execution_time = #{[ (timeout * 1000).to_i, 1 ].max}")
            begin
              in_read_only_transaction(conn, sql)
            ensure
              restore_timeout(conn, previous)
            end
          end
        end
        Rows.new(result.columns, result.rows, false)
      end

      # A failed restore never replaces the statement's own error, and the connection it
      # left with a short timeout leaves the pool so no later statement inherits it.
      def restore_timeout(conn, previous)
        conn.execute("SET SESSION max_execution_time = #{previous}")
      rescue StandardError
        begin
          conn.respond_to?(:throw_away!) ? conn.throw_away! : conn.disconnect!
        rescue StandardError
          nil
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
