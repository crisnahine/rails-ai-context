# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Collects approximate row counts from PostgreSQL's pg_stat_user_tables.
    # Only activates for PostgreSQL adapter; returns { skipped: true } otherwise.
    class DatabaseStatsIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        return { skipped: true, reason: "ActiveRecord not available" } unless defined?(ActiveRecord::Base)

        adapter = ActiveRecord::Base.connection.adapter_name.downcase
        case adapter
        when /postgresql/
          collect_postgresql_stats
        when /mysql/
          collect_mysql_stats
        when /sqlite/
          collect_sqlite_stats
        else
          { skipped: true, reason: "Stats not available for adapter: #{adapter}" }
        end
      rescue => e
        { error: e.message }
      end

      private

      def collect_postgresql_stats
        rows = ActiveRecord::Base.connection.select_all(<<~SQL)
          SELECT relname AS table_name,
                 n_live_tup AS approximate_row_count,
                 n_dead_tup AS dead_rows
          FROM pg_stat_user_tables
          ORDER BY n_live_tup DESC
        SQL

        tables = rows.map do |row|
          entry = { table: row["table_name"], approximate_rows: row["approximate_row_count"].to_i }
          dead = row["dead_rows"].to_i
          entry[:dead_rows] = dead if dead > 0
          entry
        end

        { adapter: "postgresql", tables: tables, total_tables: tables.size }
      rescue => e
        $stderr.puts "[rails-ai-context] collect_postgresql_stats failed: #{e.message}" if ENV["DEBUG"]
        { error: e.message }
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
      rescue => e
        $stderr.puts "[rails-ai-context] collect_mysql_stats failed: #{e.message}" if ENV["DEBUG"]
        { error: e.message }
      end

      def collect_sqlite_stats
        conn = ActiveRecord::Base.connection
        # Use conn.tables as authoritative list - never interpolate user input
        table_names = conn.tables.reject { |t| t.start_with?("ar_internal_metadata", "schema_migrations") }

        tables = table_names.map do |table|
          count = conn.select_value("SELECT COUNT(*) FROM #{conn.quote_table_name(table)}").to_i
          { table: table, approximate_rows: count }
        end.sort_by { |t| -t[:approximate_rows] }

        { adapter: "sqlite", tables: tables, total_tables: tables.size }
      rescue => e
        $stderr.puts "[rails-ai-context] collect_sqlite_stats failed: #{e.message}" if ENV["DEBUG"]
        { error: e.message }
      end
    end
  end
end
