# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Approximate row counts per table on PostgreSQL, MySQL and SQLite; any
    # other adapter returns { skipped: true }.
    class DatabaseStatsIntrospector < Base
      extend StaticTier
      static_tier :runtime_only

      # Trilogy is Rails 8's default MySQL adapter (`adapter_name` reports
      # "Trilogy", not "Mysql2") - matching only /mysql/ silently skips
      # stats collection for every Trilogy app.
      MYSQL_ADAPTER = /mysql|trilogy/i

      # activerecord-postgis-adapter reports "PostGIS" for what is a PostgreSQL connection.
      POSTGRES_ADAPTER = /postg/i

      def call
        return { skipped: true, reason: "ActiveRecord not available" } unless defined?(ActiveRecord::Base)

        # Connecting would create a SQLite file that is not there yet.
        missing = DatabaseFile.missing(ActiveRecord::Base.connection_db_config)
        raise missing if missing

        adapter = ActiveRecord::Base.connection.adapter_name.downcase
        case adapter
        when POSTGRES_ADAPTER
          collect_postgresql_stats
        when MYSQL_ADAPTER
          collect_mysql_stats
        when /sqlite/
          collect_sqlite_stats
        else
          { skipped: true, reason: "Stats not available for adapter: #{adapter}" }
        end
      end

      private

      def collect_postgresql_stats
        stats = PgPartitions.table_rows(ActiveRecord::Base.connection).sort_by { |t| [ -t[:rows], t[:name] ] }
        tables = stats.map do |t|
          entry = { table: t[:name], approximate_rows: t[:rows] }
          entry[:dead_rows] = t[:dead_rows] if t[:dead_rows] > 0
          entry
        end

        { adapter: "postgresql", tables: tables, total_tables: tables.size }
      end

      def collect_mysql_stats
        rows = ActiveRecord::Base.connection.select_all(<<~SQL)
          SELECT TABLE_NAME AS table_name,
                 TABLE_ROWS AS approximate_row_count
          FROM information_schema.TABLES
          WHERE TABLE_SCHEMA = DATABASE()
            AND TABLE_TYPE = 'BASE TABLE'
          ORDER BY TABLE_ROWS DESC
        SQL

        tables = rows.map do |row|
          { table: row["table_name"], approximate_rows: row["approximate_row_count"].to_i }
        end

        { adapter: "mysql", tables: tables, total_tables: tables.size }
      end

      # SQLite keeps no row estimate a query can read without ANALYZE, and
      # COUNT(*) walks the whole table on every introspection. A count that
      # stops at the cap reads at most that many rows; a table past it is
      # reported as at least the cap.
      SQLITE_COUNT_CAP = 100_000

      def collect_sqlite_stats
        conn = ActiveRecord::Base.connection
        # Use conn.tables as authoritative list - never interpolate user input
        table_names = (conn.tables - SqliteVirtualTables.hidden(conn)).reject { |t| t.start_with?("ar_internal_metadata", "schema_migrations") }

        tables = table_names.map do |table|
          count = conn.select_value("SELECT COUNT(*) FROM (SELECT 1 FROM #{conn.quote_table_name(table)} LIMIT #{SQLITE_COUNT_CAP + 1})").to_i
          entry = { table: table, approximate_rows: [ count, SQLITE_COUNT_CAP ].min }
          entry[:at_least] = true if count > SQLITE_COUNT_CAP
          entry
        end.sort_by { |t| -t[:approximate_rows] }

        { adapter: "sqlite", tables: tables, total_tables: tables.size }
      end
    end
  end
end
