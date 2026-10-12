# frozen_string_literal: true

require "json"

module RailsAiContext
  module DatabaseFamily
    # PostgreSQL bounds a statement with SET LOCAL statement_timeout inside a read-only transaction.
    module PostgresqlRuntime
      module_function

      def read_only(conn, sql, timeout)
        result = nil
        DatabaseFamily.bounding do
          conn.transaction do
            conn.execute("SET TRANSACTION READ ONLY")
            conn.execute("SET LOCAL statement_timeout = '#{(timeout * 1000).to_i}'")
            result = conn.select_all(sql)
            raise ActiveRecord::Rollback
          end
        end
        Rows.new(result.columns, result.rows, false)
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
      def plan(conn, sql, timeout)
        json = read_only(conn, "EXPLAIN (VERBOSE, FORMAT JSON) #{sql}", timeout).rows.first&.first
        data = JSON.parse(json.to_s)
        data.is_a?(Array) ? data.first&.dig("Plan") : nil
      rescue ActiveRecord::StatementInvalid, TimedOut, JSON::ParserError
        nil
      end

      # The described statement's ftable/ftablecol, then the plan's top Output,
      # which also sees through a view, CTE or subquery that renamed a column.
      def column_sources(conn, sql, plan)
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
      rescue StandardError
        []
      end

      def planned_sources(plan)
        return [] unless plan

        read = PostgresqlPlan.new(plan)
        read.output.each_with_index.filter_map do |expr, i|
          rel, col = read.base_column(expr)
          [ i, col, rel ] if col
        end
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
