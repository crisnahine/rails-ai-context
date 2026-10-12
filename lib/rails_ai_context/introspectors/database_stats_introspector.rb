# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Approximate row counts per table from the database family; an engine with
    # no family returns { skipped: true }.
    class DatabaseStatsIntrospector < Base
      extend StaticTier
      static_tier :runtime_only

      def call
        return { skipped: true, reason: "ActiveRecord not available" } unless defined?(ActiveRecord::Base)

        # Connecting would create a SQLite file that is not there yet.
        missing = DatabaseFile.missing(ActiveRecord::Base.connection_db_config)
        raise missing if missing

        conn = ActiveRecord::Base.connection
        family = RailsAiContext::DatabaseFamily.of(conn)
        return { skipped: true, reason: "Row estimates are not available for the #{family.name} adapter" } unless family.known?

        tables = family.row_estimates(conn)
        { adapter: family.key.to_s, tables: tables, total_tables: tables.size }
      end
    end
  end
end
