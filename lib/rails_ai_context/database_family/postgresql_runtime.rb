# frozen_string_literal: true

require "json"

module RailsAiContext
  module DatabaseFamily
    # PostgreSQL bounds a statement with SET LOCAL statement_timeout inside a read-only transaction.
    module PostgresqlRuntime
      module_function

      def read_only(conn, sql, timeout)
        result = bounded(conn, timeout) { exec_single(conn, sql) }
        Rows.new(result.fields, result.values, false)
      end

      # One statement over the extended protocol (exec_params with no binds). The simple
      # protocol conn.execute and select_all use runs every statement in its text, so a text
      # the gate passed in error would run a second one; the extended protocol refuses that at
      # the wire ("cannot insert multiple commands"), whatever the gate saw. The adapter set the
      # raw connection's result type map, so values cast as select_all's do. The bounded block's
      # SET statements have materialized the transaction, so this runs inside it, under its
      # read-only mode and statement_timeout. A driver error is raised as the ActiveRecord class
      # the callers expect, so a timeout still reads as TimedOut.
      #
      # A single statement that leaves a $n unbound can only be an EXPLAIN (GENERIC_PLAN), which
      # the extended protocol will not run but the simple one plans without a value; it runs
      # nothing (no ANALYZE). The extended attempt aborts the transaction, so a savepoint lets
      # the simple protocol plan it after. A text with a second statement fails with "cannot
      # insert multiple commands" before the bind, never the unbound-parameter error, so the
      # simple-protocol fallback can never run one. Only a $ can be an unbound parameter, so a
      # statement without one takes the extended protocol with no savepoint round-trips.
      def exec_single(conn, sql)
        raw = conn.raw_connection
        return raw.exec_params(sql, []) unless sql.include?("$")

        raw.exec("SAVEPOINT rac_exec_single")
        begin
          result = raw.exec_params(sql, [])
          raw.exec("RELEASE SAVEPOINT rac_exec_single")
          result
        rescue StandardError => e
          raw.exec("ROLLBACK TO SAVEPOINT rac_exec_single")
          raise e unless unbound_parameters?(e)

          conn.execute(sql)
        end
      rescue ActiveRecord::ActiveRecordError
        raise
      rescue StandardError => e
        raise conn.send(:translate_exception_class, e, sql, [])
      end

      # The driver's "bind message supplies 0 parameters, but ... requires N" for a lone $n.
      def unbound_parameters?(error)
        (defined?(PG::ProtocolViolation) && error.is_a?(PG::ProtocolViolation)) || error.message.include?("bind message supplies")
      end

      # statement_timeout ends each statement in the block, a wait on a lock included. Read-only, rolled back.
      # Inside a transaction that is already open it is a savepoint, whose rollback puts both settings back.
      def bounded(conn, timeout)
        result = nil
        DatabaseFamily.bounding do
          rolling_back(conn) do
            conn.execute("SET TRANSACTION READ ONLY")
            conn.execute("SET LOCAL statement_timeout = '#{[ (timeout * 1000).to_i, 1 ].max}'")
            result = yield
          end
        end
        result
      end

      # PG::PQTRANS_IDLE, which needs the pg gem loaded.
      TRANSACTION_IDLE = 0

      # The server's own transaction status decides: Active Record does not count a transaction the app opened with a
      # raw BEGIN, and its own BEGIN and ROLLBACK there would end the app's.
      def rolling_back(conn)
        if conn.raw_connection.transaction_status == TRANSACTION_IDLE
          conn.transaction(requires_new: true) do
            yield
            raise ActiveRecord::Rollback
          end
        else
          conn.execute("SAVEPOINT rac_bounded")
          begin
            yield
          ensure
            DatabaseFamily.restore(conn, "ROLLBACK TO SAVEPOINT rac_bounded; RELEASE SAVEPOINT rac_bounded")
          end
        end
      end

      # The settings bounded sets for each statement => the read of the session's own value.
      def bound_settings(_conn)
        { "statement_timeout" => "SHOW statement_timeout", "transaction_read_only" => "SHOW transaction_read_only" }
      end

      def explain(conn, sql, timeout)
        raw = read_only(conn, "EXPLAIN (FORMAT JSON, ANALYZE) #{sql}", timeout).rows.map { |r| r.first.to_s }.join("\n")
        scans = []
        warnings = []
        begin
          data = JSON.parse(raw)
          plan = data.first["Plan"] if data.is_a?(Array) && data.first.is_a?(Hash)
          scan_nodes(plan, scans, warnings) if plan
        rescue JSON::ParserError
          nil
        end
        { scan_types: scans, warnings: warnings, raw: raw, unbounded: false }
      end

      # Planning only: EXPLAIN without ANALYZE runs nothing, not even a VOLATILE function.
      # A timeout and an SQL error are raised, so the caller never runs what it could not plan.
      def plan(conn, sql, timeout, generic: false)
        explain = "EXPLAIN (VERBOSE, FORMAT JSON#{", GENERIC_PLAN" if generic}) #{sql}"
        # One statement at the wire while the gate is still checking, so a text it passed in
        # error cannot run a write here. A generic plan's unbound $n falls back to the simple
        # protocol inside exec_single, which plans it without running anything.
        result = bounded(conn, timeout) { exec_single(conn, explain) }
        data = JSON.parse(result.values.first&.first.to_s)
        data.is_a?(Array) && data.first.is_a?(Hash) ? data.first["Plan"] : nil
      rescue JSON::ParserError
        nil
      end

      # The described statement's ftable/ftablecol, then the plan's top Output,
      # which also sees through a view, CTE or subquery that renamed a column.
      def column_sources(conn, sql, plan)
        raise ArgumentError, "PostgreSQL column sources are read from the statement's plan, and none was given" unless plan

        described_sources(conn, sql) + planned_sources(plan)
      end

      def described_sources(conn, sql)
        raw = conn.raw_connection
        stmt = "rac_prov_#{Process.pid}_#{rand(1 << 30)}"
        begin
          raw.prepare(stmt, sql)
          desc = raw.describe_prepared(stmt)
        ensure
          raw.exec("DEALLOCATE #{stmt}") rescue nil
        end

        relations = {}
        desc.nfields.times.filter_map do |i|
          oid = desc.ftable(i).to_i
          col = desc.ftablecol(i).to_i
          next if oid.zero? || col.zero?

          relation, names = relations[oid] ||= [ relation_name(conn, oid), attribute_names(conn, oid) ]
          # A relation whose columns could not be read still names itself, for the caller to fail closed on.
          next [ i, nil, relation ] unless names
          [ i, names[col], relation ] if names[col]
        end
      rescue StandardError => e
        # The driver raises its own class here. Half a trace is no answer, so a timeout is raised as the call's, and a cancel as itself.
        if defined?(PG::QueryCanceled) && e.is_a?(PG::QueryCanceled)
          raise if DatabaseFamily.canceled?(e)

          raise TimedOut, e.message
        end
        raise if e.is_a?(ActiveRecord::StatementInvalid) && DatabaseFamily.timed_out?(e)

        []
      end

      def planned_sources(plan)
        read = PostgresqlPlan.new(plan)
        read.output.each_with_index.flat_map do |exprs, i|
          exprs.flat_map { |expr| read.base_columns(expr) }.map { |rel, col| [ i, col, rel ] }.uniq { |_, col, _| col }
        end
      end

      def unqualified_schemas(_conn)
        []
      end

      # A bare name folds to lower case and a quoted one does not, so both spellings are asked for.
      def schemas_named(conn, names)
        asked = (names | names.map(&:downcase)).map { |name| conn.quote(name) }.join(", ")
        conn.select_values(
          "SELECT nspname FROM pg_namespace WHERE nspname IN (#{asked}) AND nspname !~ '^pg_' " \
          "AND nspname <> 'information_schema' AND nspname <> ALL (current_schemas(false))"
        )
      end

      # A plan names the session's temporary schema pg_temp, whatever number its own name carries.
      SCHEMA = "CASE WHEN n.oid = pg_my_temp_schema() THEN 'pg_temp' ELSE n.nspname END"

      def in_schemas(conn, schemas)
        schemas.empty? ? "n.nspname = ANY (current_schemas(false))" : "#{SCHEMA} IN (#{schemas.map { |name| conn.quote(name) }.join(", ")})"
      end

      # Every relation a plan can name that stores rows: tables, partitioned tables, materialized views, foreign tables and sequences.
      # One read that takes no lock on any of them.
      def relation_columns(conn, schemas = [])
        rows = conn.select_rows(
          "SELECT #{SCHEMA}, c.relname, a.attname FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid " \
          "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p', 'm', 'f', 'S') AND a.attnum > 0 " \
          "AND NOT a.attisdropped AND #{in_schemas(conn, schemas)} ORDER BY c.relname, a.attnum"
        )
        rows.each_with_object({}) do |(schema, relation, column), found|
          (found[relation] ||= []) << column
          (found["#{schema}.#{relation}"] ||= []) << column
        end
      end

      VIEWS = "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind"

      # A materialized view stores its rows, so its result columns have no table column to be traced to. The
      # views are read with it for what a materialized view built on one reads. Each is also under `schema.view`.
      def view_definitions(conn, schemas = [])
        rows = conn.select_rows("SELECT #{SCHEMA}, c.relname, pg_get_viewdef(c.oid) #{VIEWS} IN ('v', 'm') AND #{in_schemas(conn, schemas)}")
        DatabaseFamily.by_view(rows.flat_map { |schema, view, definition| [ [ view, definition ], [ "#{schema}.#{view}", definition ] ] })
      end

      def traced_views(conn, schemas = [])
        conn.select_rows("SELECT #{SCHEMA}, c.relname #{VIEWS} = 'v' AND #{in_schemas(conn, schemas)}")
          .flat_map { |schema, view| [ view, "#{schema}.#{view}" ] }
      end

      # A stored generated column is a plain column to the plan, so its expression is read here.
      def generated_columns(conn, _schemas = [])
        return {} if conn.database_version < 12_00_00

        DatabaseFamily.keep_expressions({}, conn.select_rows(
          "SELECT c.relname, a.attname, pg_get_expr(d.adbin, d.adrelid) FROM pg_attribute a " \
          "JOIN pg_class c ON c.oid = a.attrelid JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum " \
          "WHERE a.attgenerated <> '' AND NOT a.attisdropped"
        ))
      end

      def relation_name(conn, oid)
        conn.select_value("SELECT relname FROM pg_class WHERE oid = #{oid.to_i}")&.to_s
      rescue StandardError
        nil
      end

      # attnum => column name for one relation oid, or nil when they cannot be read.
      def attribute_names(conn, oid)
        conn.select_rows(
          "SELECT attnum, attname FROM pg_attribute WHERE attrelid = #{oid.to_i} AND attnum > 0 AND NOT attisdropped"
        ).to_h { |num, name| [ num.to_i, name.to_s ] }
      rescue StandardError
        nil
      end

      def index_tables(_conn, _schemas = [])
        {}
      end

      def table_sizes(conn)
        Introspectors::PgPartitions.table_bytes(conn).sort_by { |r| [ -r[:bytes], r[:name] ] }
      end

      def row_estimates(conn)
        Introspectors::PgPartitions.table_rows(conn).sort_by { |t| [ -t[:rows], t[:name] ] }.map do |t|
          entry = { table: t[:name], approximate_rows: t[:rows] }
          entry[:dead_rows] = t[:dead_rows] if t[:dead_rows] > 0
          entry
        end
      end

      def index_usage(conn)
        Introspectors::PgPartitions.index_stats(conn).sort_by { |i| [ i[:scans], i[:table], i[:index] ] }
      end

      def scan_nodes(node, scans, warnings)
        return unless node.is_a?(Hash)

        node_type = node["Node Type"].to_s
        table = node["Relation Name"]
        rows = node["Actual Rows"] || node["Plan Rows"]

        if node_type.include?("Seq Scan")
          scans << { table: table, type: "sequential scan", index: nil }
          warnings << "Sequential scan on #{table} (#{rows} rows)" if rows.to_i > 1000
        elsif node_type.include?("Index")
          scans << { table: table, type: node_type.downcase, index: node["Index Name"] }
        end

        (node["Plans"] || []).each { |child| scan_nodes(child, scans, warnings) }
      end
    end
  end
end
