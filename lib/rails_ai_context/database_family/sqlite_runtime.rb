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

      # What the child writes where a result's length would stand, the moment it meets a lock.
      MET_LOCK = [ (1 << 64) - 1 ].pack("Q>").freeze
      # What it writes once it holds its read lock: no lock can stop the statement from there on.
      PAST_LOCK = [ (1 << 64) - 2 ].pack("Q>").freeze
      WAITS_ON_LOCK = { MET_LOCK => true, PAST_LOCK => false }.freeze

      # A plan row that reads a table: the step, then the table's name or, for a table the statement
      # renames, the alias alone ("SEARCH u USING INDEX i"). SQLite before 3.36 wrote "SCAN TABLE users AS u".
      PLAN_STEP = /\A(SCAN|SEARCH)\s+(?:TABLE\s+)?(.+?)(?:\s+AS\s+\S+)?(?=\s+USING\b|\s+VIRTUAL TABLE\b|\z)/

      # pragma_table_xinfo's hidden flag: 2 is a virtual generated column, 3 a stored one.
      GENERATED = [ 2, 3 ].freeze

      # COUNT(*) walks the whole table; a count that stops here reads at most this many rows.
      COUNT_CAP = 100_000

      def read_only(conn, sql, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        # A child opens the file itself and would answer without the rows of a transaction open here.
        if !conn.transaction_open? && (path = fork_path(conn)) && !DatabaseFamily.bounding { held_here?(conn, sql) }
          result = in_child(conn, path, sql, deadline)
          return Rows.new(result.columns, result.rows, false) if result
        end

        result = DatabaseFamily.bounding { on_app_connection(conn, sql, deadline) }
        Rows.new(result.columns, result.rows, true)
      end

      # The temp catalog, the temp schema, and the pragma function that lists the tables of every schema.
      CONNECTION_CATALOG = /(?<![\w$])(?:sqlite_temp_(?:master|schema)|temp["`'\]]?\s*\.|pragma_table_list(?![\w$]))/i

      # Whether the statement names what the connection holds and a child would lack: a temp object, the temp
      # schema or an attached database. A name inside a string counts, since a pragma function takes one there.
      def held_here?(conn, sql)
        # Neither read waits on another connection's lock, which the pragma function for the same list does.
        names = conn.select_values("SELECT name FROM sqlite_temp_master WHERE type IN ('table', 'view')") +
          conn.select_rows("PRAGMA database_list").filter_map { |_seq, name, _file| name unless OWN_SCHEMAS.include?(name) }
        return false if names.empty?

        sql.match?(CONNECTION_CATALOG) || sql.match?(/(?<![\w$])#{Regexp.union(names)}(?![\w$])/i)
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
        tables = conn.data_sources.map(&:downcase)
        raw_lines = result.rows.map do |row|
          # Columns: id, parent, notused, detail.
          detail = row.last.to_s
          step, name = detail.match(PLAN_STEP)&.captures
          # "SCAN CONSTANT ROW" reads no table.
          if step && name != "CONSTANT ROW"
            table = tables.include?(name.downcase) ? name : "#{name} (a name the statement gives)"
            type = if step == "SEARCH" then "index search"
            elsif detail.match?(/USING.*INDEX/) then "index scan"
            else "full table scan"
            end
            scans << { table: table, type: type, index: detail[/USING.*INDEX\s+(\w+)/, 1] }
            warnings << "Full table scan on #{table}" if type == "full table scan"
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

      # The attached databases. A statement reaches their tables with no schema named, as it does main's and temp's.
      def unqualified_schemas(conn)
        conn.select_rows("PRAGMA database_list").map { |_seq, name, _file| name } | OWN_SCHEMAS
      end

      def schemas_named(_conn, _names)
        []
      end

      OWN_SCHEMAS = %w[main temp].freeze

      # One SELECT for each schema, as one statement. Yields the schema as an identifier and as a string,
      # which is how a pragma function takes it.
      def across(schemas)
        (schemas.empty? ? OWN_SCHEMAS : schemas).map { |schema| yield %("#{schema.gsub('"', '""')}"), "'#{schema.gsub("'", "''")}'" }.join(" UNION ALL ")
      end

      # A virtual table's hidden columns are left out (hidden = 1): a full-text table has one of its own name.
      def relation_columns(conn, schemas = [])
        DatabaseFamily.by_table(conn.select_rows(across(schemas) do |schema, name|
          "SELECT m.name, p.name FROM #{schema}.sqlite_master m JOIN pragma_table_xinfo(m.name, #{name}) p " \
            "WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND p.hidden <> 1"
        end)).transform_values(&:flatten)
      end

      # The body only: the header names the view itself.
      def view_definitions(conn, schemas = [])
        rows = conn.select_rows(across(schemas) { |schema, _| "SELECT name, sql FROM #{schema}.sqlite_master WHERE type = 'view'" })
        DatabaseFamily.by_view(rows.map { |name, sql| [ name, sql.to_s.sub(/\A.*?\bAS\b/mi, "") ] })
      end

      def traced_views(_conn, _schemas = [])
        []
      end

      # SQLite keeps no expression per column, so each one is cut from its table's definition. A column whose
      # part of the definition is not found answers the whole definition.
      def generated_columns(conn, schemas = [])
        rows = conn.select_rows(across(schemas) do |schema, name|
          "SELECT m.name, p.name, p.hidden, m.sql FROM #{schema}.sqlite_master m JOIN pragma_table_xinfo(m.name, #{name}) p " \
            "WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND m.sql LIKE '%AS%(%'"
        end)
        # Tables of one name in two schemas each have a definition of their own.
        rows.group_by { |table, _name, _hidden, definition| [ table, definition.to_s ] }.each_with_object({}) do |((table, definition), columns), found|
          generated = columns.filter_map { |_table, name, hidden, _| name if GENERATED.include?(hidden.to_i) }
          next if generated.empty?

          expressions = column_expressions(definition)
          DatabaseFamily.keep_expressions(found, generated.map { |name| [ table, name, expressions[name.downcase(:ascii)] || definition ] })
        end
      end

      COLUMN_NAME = /\A(?:"((?:""|[^"])*)"|`((?:``|[^`])*)`|\[([^\]]*)\]|'((?:''|[^'])*)'|([^\s(]+))(.*)\z/m
      # A bare one of these opens a table constraint. In quotes it is a column's name.
      TABLE_CONSTRAINT = /\A(?:CONSTRAINT|PRIMARY|UNIQUE|CHECK|FOREIGN)\z/i

      # @return [Hash{String => String, nil}] column name, folded as SQLite compares names (ASCII only) => what its
      #   part of a CREATE TABLE statement says after AS; nil where that cannot be told
      def column_expressions(definition)
        scanner = SqlGate::Scanner.new(SqlGate.comment_free(definition, SQLITE))
        depth = 0
        parts = [ +"" ]
        until scanner.eos?
          read = SqlGate.quoted(scanner, SQLITE)&.last || scanner.getch
          depth -= 1 if read == ")"
          if depth == 1 && read == "," then parts << +""
          elsif depth.positive? then parts.last << read
          end
          depth += 1 if read == "("
        end
        parts.each_with_object({}) do |part, found|
          double, tick, bracket, single, bare, rest = part.strip.match(COLUMN_NAME)&.captures
          next if rest.nil? || bare&.match?(TABLE_CONSTRAINT)

          # A quote is doubled only inside a name its own kind encloses, and a bracketed name doubles nothing.
          name = (bare || bracket || double&.gsub('""', '"') || tick&.gsub("``", "`") || single.gsub("''", "'")).downcase(:ascii)
          found[name] = found.key?(name) ? nil : rest.partition(/\bAS\b/i).last.presence
        end
      end

      # pragma_table_list, which types a shadow table, came with this version.
      TYPED_TABLES = "3.37"
      VOCABULARY = /\bUSING\s+["'`\[]?(fts5vocab|fts4aux)\b["'`\]]?\s*\((.*)\)/mi

      # Modules that return the database file's pages or cells, whatever table they belong to.
      PAGE_MODULES = %w[sqlite_dbpage sqlite_dbdata sqlite_dbptr].freeze

      # Before pragma_table_list a shadow table is told by its name: any table that starts with a virtual table's.
      def index_tables(conn, schemas = [])
        tables = ->(kept) { across(schemas) { |schema, _| "SELECT name, sql FROM #{schema}.sqlite_master WHERE type = 'table' AND rootpage #{kept}" } }
        virtual = conn.select_rows(tables.call("= 0")).to_h
        stored = if conn.database_version >= TYPED_TABLES
          conn.select_values(across(schemas) { |_, name| "SELECT name FROM pragma_table_list WHERE type = 'shadow' AND schema = #{name} COLLATE NOCASE" })
        else conn.select_rows(tables.call("> 0")).map(&:first)
        end
        found = stored.each_with_object(PAGE_MODULES.to_h { |name| [ name, [ :pages, nil ] ] }) do |name, tables|
          owner = virtual.keys.select { |table| name.downcase.start_with?("#{table.downcase}_") }.max_by(&:size)
          tables[name] = [ :shadow, owner ] if owner
        end
        virtual.each do |name, sql|
          sql = SqlGate.comment_free(sql.to_s, SQLITE)
          mod, args = sql.match(VOCABULARY)&.captures
          # fts5vocab([schema,] table, type) and fts4aux([schema,] table).
          names = args.to_s.split(",").map { |arg| arg.strip.delete(%q('"`[])) }
          found[name] = mod ? [ :vocabulary, mod.casecmp?("fts4aux") ? names.last : names[-2], sql ] : [ :virtual, name, sql ]
        end
        found
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
          wait_on_lock(db, writer, timeout * 0.8)
          # A read inside a transaction keeps its lock, so the statement itself never waits on one.
          db.execute("BEGIN")
          db.execute("SELECT 1 FROM sqlite_master LIMIT 1")
          writer.write(PAST_LOCK)
          stmt = db.prepare(sql)
          [ :ok, stmt.columns, stmt.to_a ]
        rescue => e
          # Which step failed is the child's own fact; the message can hold text from the statement.
          status = if e.is_a?(SQLite3::BusyException) then :busy
          else db && !stmt ? :unprepared : :error
          end
          [ status, "#{e.class}: #{e.message}" ]
        end
        bytes = Marshal.dump(payload)
        writer.write([ bytes.bytesize ].pack("Q>"), bytes)
      ensure
        exit!(0)
      end

      # Gives up under the deadline, so the child answers a database that stays locked. The parent is told at
      # the first wait, for a child that started late and is still waiting at the deadline.
      def wait_on_lock(db, writer, seconds)
        met = nil
        db.busy_handler do |count|
          if count.zero?
            met = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            writer.write(MET_LOCK)
          end
          sleep 0.01
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - met < seconds
        end
      end

      # Read by length: any other process forked meanwhile holds a copy of the writer, so EOF may never come.
      # A deadline that passes while the child waits on a lock is answered as locked; past the lock it is the timeout.
      def read_child_result(reader, deadline)
        on_lock = false
        size = begin
          loop do
            prefix = read_before(reader, 8, deadline)
            break prefix.unpack1("Q>") unless WAITS_ON_LOCK.key?(prefix)

            on_lock = WAITS_ON_LOCK.fetch(prefix)
          end
        rescue TimedOut
          raise unless on_lock

          raise Busy, BUSY
        end
        status, *rest = begin
          raise ArgumentError, "result length out of range" if size > MAX_RESULT_BYTES

          Marshal.load(read_before(reader, size, deadline))
        rescue ArgumentError, TypeError
          raise ActiveRecord::StatementInvalid, "the SQLite query process exited without a result"
        end
        raise Busy, BUSY if status == :busy
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
