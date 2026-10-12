# frozen_string_literal: true

require "set"

module RailsAiContext
  module DatabaseFamily
    # sqlite3-ruby holds the interpreter lock while a statement steps, so only a killable child ends
    # one at the deadline. A statement the child cannot run goes to the app's own connection, unbounded.
    module SqliteRuntime
      module_function

      TIMED_OUT = "SQLite query exceeded the statement timeout"

      # A row-capped result is far below this; a larger prefix is a corrupt one.
      MAX_RESULT_BYTES = 1 << 30

      # COUNT(*) walks the whole table; a count that stops here reads at most this many rows.
      COUNT_CAP = 100_000

      def read_only(conn, sql, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        if (path = fork_path(conn))
          result = in_child(conn, path, sql, deadline)
          return Rows.new(result.columns, result.rows, false) if result
        end

        result = on_app_connection(conn, sql, deadline)
        Rows.new(result.columns, result.rows, true)
      end

      # The watchdog's interrupt lands when the driver is back in Ruby between two rows, so it ends a
      # statement that returns rows slowly and cannot end one long step: the run counts as unbounded.
      def on_app_connection(conn, sql, deadline)
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise TimedOut, TIMED_OUT unless left.positive?

        raw = conn.raw_connection
        found = conn.select_value("PRAGMA query_only").to_i
        watchdog = Thread.new { sleep(left) and raw.interrupt }
        begin
          conn.execute("PRAGMA query_only = ON")
          conn.select_all(sql)
        rescue ActiveRecord::StatementInvalid => e
          raise TimedOut, TIMED_OUT if e.cause.is_a?(SQLite3::InterruptException)

          raise
        ensure
          watchdog.kill.join
          DatabaseFamily.restore(conn, "PRAGMA query_only = #{found}")
        end
      end

      # These reads run on the app's own connection, where a wait on another writer ends at the
      # connection's busy timeout (database.yml `timeout`; with none, a busy database fails at once).
      def bounded(_conn, _timeout, &reads)
        DatabaseFamily.bounding(&reads)
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

      def relation_columns(conn)
        conn.select_rows(
          "SELECT m.name, p.name FROM sqlite_master m JOIN pragma_table_xinfo(m.name) p " \
          "WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' ORDER BY m.name, p.cid"
        ).each_with_object({}) { |(table, column), found| (found[table] ||= []) << column }
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
        rows = conn.select_rows(
          "SELECT m.name, m.sql, p.name, p.hidden FROM sqlite_master m JOIN pragma_table_xinfo(m.name) p " \
          "WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND m.sql LIKE '%AS%(%'"
        )
        rows.group_by(&:first).each_with_object({}) do |(table, columns), found|
          generated = columns.select { |column| column[3].to_i >= 2 }
          next if generated.empty?

          read = columns.reduce(columns.first[1].to_s) { |text, column| text.sub(/\b#{Regexp.escape(column[2])}\b/i, " ") }
          found[table] = generated.to_h { |column| [ column[2], read ] }
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

      # @return [ActiveRecord::Result, nil] nil when the child could not prepare the statement, as when it
      #   names a function, module, collation, key or temporary table only the app's connection has
      def in_child(conn, path, sql, deadline)
        parent = Process.pid
        extensions = Array(conn.pool.db_config.configuration_hash[:extensions]).map { |ext| (ext.is_a?(String) && ext.safe_constantize) || ext }
        # sqlite3 2.x warns in every child that inherits a writable handle; Rails 8 silences it the same way.
        SQLite3::ForkSafety.suppress_warnings! if defined?(SQLite3::ForkSafety)

        timeout = [ deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max
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
          # Which step failed is the child's own fact; the message can hold text from the statement.
          [ db && !stmt && !e.is_a?(SQLite3::BusyException) ? :unprepared : :error, "#{e.class}: #{e.message}" ]
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
        return nil if status == :unprepared

        ActiveRecord::Result.new(*rest)
      end

      def read_before(reader, size, deadline)
        data = "".b
        while data.bytesize < size
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise TimedOut, TIMED_OUT unless left.positive? && IO.select([ reader ], nil, nil, left)

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
