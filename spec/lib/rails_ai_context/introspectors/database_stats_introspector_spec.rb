# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::DatabaseStatsIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    it "returns table stats for SQLite adapter" do
      result = introspector.call
      # Test suite uses SQLite - should return stats
      expect(result[:adapter]).to eq("sqlite")
      expect(result[:tables]).to be_an(Array)
      expect(result[:total_tables]).to be_a(Integer)
    end

    it "collects MySQL-family stats for the Trilogy adapter (Rails 8's default MySQL adapter)" do
      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("Trilogy")
      allow(ActiveRecord::Base.connection).to receive(:select_all)
        .with(a_string_matching(/information_schema\.TABLES/i))
        .and_return([ { "table_name" => "products", "approximate_row_count" => 3 } ])

      result = introspector.call
      expect(result[:adapter]).to eq("mysql")
      expect(result[:tables]).to eq([ { table: "products", approximate_rows: 3 } ])
    end

    # Sizing a relation waits on its lock, so a migration holding one would stall
    # the stats; the statistics views alone take none.
    it "reads PostgreSQL row counts without sizing any relation" do
      conn = ActiveRecord::Base.connection
      allow(conn).to receive(:adapter_name).and_return("PostgreSQL")
      allow(conn).to receive(:database_version).and_return(17_00_09)
      queries = []
      allow(conn).to receive(:select_all) { |sql| queries << sql and [] }

      introspector.call

      expect(queries).not_to be_empty
      expect(queries).to all(satisfy { |sql| !sql.include?("pg_total_relation_size") })
    end

    it "collects PostgreSQL stats for the PostGIS adapter" do
      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("PostGIS")
      allow(RailsAiContext::Introspectors::PgPartitions).to receive(:table_rows)
        .and_return([ { name: "parcels", rows: 7, dead_rows: 0 } ])

      result = introspector.call
      expect(result[:adapter]).to eq("postgresql")
      expect(result[:tables]).to eq([ { table: "parcels", approximate_rows: 7 } ])
    end
  end
end
