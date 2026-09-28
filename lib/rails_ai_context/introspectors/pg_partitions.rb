# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # A partition repeats its parent's columns, indexes and keys, so it is listed
    # as its partitioned parent, and its rows, bytes and index scans count there.
    module PgPartitions
      module_function

      # activerecord-postgis-adapter reports "PostGIS" for what is a PostgreSQL connection.
      POSTGRES_ADAPTER = /postg/i

      # Scoped the way connection.tables is.
      NAMES_SQL = <<~SQL.squish.freeze
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relispartition AND c.relkind IN ('r', 'p') AND n.nspname = ANY (current_schemas(false))
      SQL

      def names(conn)
        # relispartition arrived with partitions in 10; querying it before then
        # fails, and a failed query aborts any open transaction.
        return [] unless conn.adapter_name.match?(POSTGRES_ADAPTER) && conn.database_version >= 10_00_00

        conn.select_values(NAMES_SQL)
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "PgPartitions.names")
      end

      # @return [Array<Hash>] { name:, rows:, dead_rows: } per table, from the statistics alone
      def table_rows(conn)
        per_table(conn, "SUM(s.n_live_tup) AS live_rows, SUM(s.n_dead_tup) AS dead_rows").map do |r|
          { name: r["name"], rows: r["live_rows"].to_i, dead_rows: r["dead_rows"].to_i }
        end
      end

      # @return [Array<Hash>] { name:, bytes: } per table. Sizing a relation waits on its lock.
      def table_bytes(conn)
        per_table(conn, "SUM(pg_total_relation_size(s.relid)) AS bytes").map do |r|
          { name: r["name"], bytes: r["bytes"].to_i }
        end
      end

      # @return [Array<Hash>] { table:, index:, scans: } per index, from pg_stat_user_indexes
      def index_stats(conn)
        conn.select_all(<<~SQL).map do |r|
          SELECT t.relname AS table_name, i.relname AS index_name, SUM(s.idx_scan) AS scans
          FROM pg_stat_user_indexes s
          JOIN pg_class t ON t.oid = #{root_of(conn, "s.relid")}
          JOIN pg_class i ON i.oid = #{root_of(conn, "s.indexrelid")}
          GROUP BY t.oid, t.relname, i.oid, i.relname
        SQL
          { table: r["table_name"], index: r["index_name"], scans: r["scans"].to_i }
        end
      end

      def per_table(conn, sums)
        conn.select_all(<<~SQL)
          SELECT c.relname AS name, #{sums}
          FROM pg_stat_user_tables s
          JOIN pg_class c ON c.oid = #{root_of(conn, "s.relid")}
          GROUP BY c.oid, c.relname
        SQL
      end
      private_class_method :per_table

      def root_of(conn, relid)
        # ponytail: pg_partition_root needs PostgreSQL 12, so on 10 and 11 each partition stays its own row.
        conn.database_version >= 12_00_00 ? "COALESCE(pg_partition_root(#{relid}), #{relid})" : relid
      end
      private_class_method :root_of
    end
  end
end
