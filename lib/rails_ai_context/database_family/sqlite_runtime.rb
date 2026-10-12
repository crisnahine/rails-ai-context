# frozen_string_literal: true

require "set"

module RailsAiContext
  module DatabaseFamily
    # sqlite3-ruby cannot interrupt a running statement, so a killable child runs it with a
    # deadline. Where there is no child to fork, PRAGMA query_only runs it here, unbounded.
    module SqliteRuntime
      module_function

      # Errors from state only the app's own connection has: registered functions,
      # virtual table modules, collations, an encryption key.
      APP_CONNECTION_ONLY = /no such (?:function|module|collation)|file is not a database/i

      # A row-capped result is far below this; a larger prefix is a corrupt one.
      MAX_RESULT_BYTES = 1 << 30

      # COUNT(*) walks the whole table; a count that stops here reads at most this many rows.
      COUNT_CAP = 100_000

      def read_only(conn, sql, timeout)
        if (path = fork_path(conn))
          begin
            result = in_child(conn, path, sql, timeout)
            return Rows.new(result.columns, result.rows, false)
          rescue ActiveRecord::StatementInvalid => e
            raise unless e.message.match?(APP_CONNECTION_ONLY)
          end
        end

        result = nil
        begin
          conn.execute("PRAGMA query_only = ON")
          result = conn.select_all(sql)
        ensure
          conn.execute("PRAGMA query_only = OFF")
        end
        Rows.new(result.columns, result.rows, true)
      end

      def explain(conn, sql, timeout)
        result = read_only(conn, "EXPLAIN QUERY PLAN #{sql}", timeout)
        scans = []
        warnings = []
        raw_lines = result.rows.map do |row|
          # Columns: id, parent, notused, detail.
          detail = row.last.to_s
          index = detail.match(/USING.*INDEX\s+(\w+)/i)&.captures&.first
          if detail.match?(/SCAN\b/i)
            table = detail.match(/SCAN\s+(?:TABLE\s+)?(\w+)/i)&.captures&.first
            scan_type = detail.match?(/USING.*INDEX/i) ? "index scan" : "full table scan"
            scans << { table: table, type: scan_type, index: index }
            warnings << "Full table scan on #{table}" if scan_type == "full table scan" && table
          elsif detail.match?(/SEARCH\b/i)
            scans << { table: detail.match(/SEARCH\s+(?:TABLE\s+)?(\w+)/i)&.captures&.first, type: "index search", index: index }
          end
          detail
        end
        { scan_types: scans, warnings: warnings, raw: raw_lines.join("\n"), unbounded: result.unbounded }
      end

      def column_sources(_conn, _sql, _plan)
        []
      end

      def plan(_conn, _sql, _timeout)
        nil
      end

      # The body only: the header names the view itself. A temporary view lives in its own catalogue.
      def view_definitions(conn)
        conn.select_rows(
          "SELECT name, sql FROM sqlite_master WHERE type = 'view' UNION ALL SELECT name, sql FROM sqlite_temp_master WHERE type = 'view'"
        ).to_h { |name, sql| [ name, sql.to_s.sub(/\A.*?\bAS\b/mi, "") ] }
      end

      # SQLite keeps no expression per column, so each generated column answers its table's definition with one
      # mention of every column taken out: a column name still in it is one some expression reads.
      def generated_columns(conn)
        conn.select_rows("SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").each_with_object({}) do |(table, sql), found|
          next unless sql.to_s.match?(/\bAS\s*\(/i)

          columns = conn.select_all("PRAGMA table_xinfo(#{conn.quote_table_name(table)})").to_a
          generated = columns.select { |column| column["hidden"].to_i >= 2 }
          next if generated.empty?

          read = columns.reduce(sql.to_s) { |text, column| text.sub(/\b#{Regexp.escape(column["name"])}\b/i, " ") }
          found[table] = generated.to_h { |column| [ column["name"], read ] }
        end
      end

      def table_sizes(conn)
        # dbstat lists every b-tree, indexes and SQLite internals too.
        app_tables = conn.select_values("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").to_set

        begin
          rows = conn.select_all("SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name ORDER BY bytes DESC")
            .filter_map { |r| { name: r["name"], bytes: r["bytes"].to_i } if app_tables.include?(r["name"]) }
          return rows if rows.any?
        rescue => e
          RailsAiContext.debug_fail(e, label: "SqliteRuntime.table_sizes (dbstat)")
        end

        # Without dbstat, the whole file split across the tables.
        total = conn.select_value("PRAGMA page_count").to_i * conn.select_value("PRAGMA page_size").to_i
        tables = app_tables.to_a.sort
        tables.map { |t| { name: t, bytes: total / [ tables.size, 1 ].max } }
      end

      # SQLite keeps no row estimate a query can read without ANALYZE; a table past the cap is a floor.
      def row_estimates(conn)
        names = (conn.tables - Introspectors::SqliteVirtualTables.hidden(conn)).reject { |t| t.start_with?("ar_internal_metadata", "schema_migrations") }
        names.map do |table|
          count = conn.select_value("SELECT COUNT(*) FROM (SELECT 1 FROM #{conn.quote_table_name(table)} LIMIT #{COUNT_CAP + 1})").to_i
          entry = { table: table, approximate_rows: [ count, COUNT_CAP ].min }
          entry[:at_least] = true if count > COUNT_CAP
          entry
        end.sort_by { |t| [ -t[:approximate_rows], t[:table] ] }
      end

      def index_usage(_conn)
        nil
      end

      # nil for an in-memory or temporary database, or where there is no fork.
      def fork_path(conn)
        return nil unless Process.respond_to?(:fork)

        path = conn.raw_connection.filename("main").to_s
        path unless path.empty?
      end

      def in_child(conn, path, sql, timeout)
        parent = Process.pid
        extensions = Array(conn.pool.db_config.configuration_hash[:extensions]).map { |ext| (ext.is_a?(String) && ext.safe_constantize) || ext }
        # sqlite3 2.x warns in every child that inherits a writable handle; Rails 8 silences it the same way.
        SQLite3::ForkSafety.suppress_warnings! if defined?(SQLite3::ForkSafety)

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        reader, writer = IO.pipe.each(&:binmode)
        pid = fork { answer_in_child(reader, writer, path, sql, timeout, extensions) }
        writer.close
        read_child_result(reader, deadline)
      ensure
        # Also reached in a child whose fork hooks raised: it must not carry on as a second server.
        exit!(1) if parent && Process.pid != parent
        reader&.close
        writer&.close
        reap_child(pid) if pid
      end

      # Writes the length-prefixed result and exits without the parent's at_exit hooks.
      def answer_in_child(reader, writer, path, sql, timeout, extensions)
        reader.close
        payload = begin
          db = SQLite3::Database.new(path, readonly: true, extensions: extensions)
          db.busy_timeout = (timeout * 1000).to_i
          stmt = db.prepare(sql)
          [ :ok, stmt.columns, stmt.to_a ]
        rescue => e
          [ :error, "#{e.class}: #{e.message}" ]
        end
        bytes = Marshal.dump(payload)
        writer.write([ bytes.bytesize ].pack("Q>"), bytes)
      ensure
        exit!(0)
      end

      # Read by length: any other process forked meanwhile holds a copy of the writer, so EOF may never come.
      def read_child_result(reader, deadline)
        size = read_before(reader, 8, deadline).unpack1("Q>")
        status, *rest = begin
          raise ArgumentError, "result length out of range" if size > MAX_RESULT_BYTES

          Marshal.load(read_before(reader, size, deadline))
        rescue ArgumentError, TypeError
          raise ActiveRecord::StatementInvalid, "the SQLite query process exited without a result"
        end
        raise ActiveRecord::StatementInvalid, rest.first if status == :error

        ActiveRecord::Result.new(*rest)
      end

      def read_before(reader, size, deadline)
        data = "".b
        while data.bytesize < size
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise TimedOut, "SQLite query exceeded the statement timeout" unless left.positive? && IO.select([ reader ], nil, nil, left)

          chunk = reader.read_nonblock([ size - data.bytesize, 1 << 16 ].min, exception: false)
          raise ActiveRecord::StatementInvalid, "the SQLite query process exited without a result" if chunk.nil?

          data << chunk unless chunk == :wait_readable
        end
        data
      end

      # KILL: TERM cannot land while `step` holds the GVL, and would run inherited at_exit hooks.
      # Runs in an ensure, so it rescues everything: nothing here may replace the query's own error.
      def reap_child(pid)
        Process.kill(:KILL, pid) rescue nil
        Process.wait(pid) rescue nil
      end
    end
  end
end
