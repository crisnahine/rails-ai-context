# frozen_string_literal: true

require "spec_helper"

# spec/e2e/postgres_install_spec.rb runs these against a real PostgreSQL; the
# doubles here stand in for the older servers that run cannot reach.
RSpec.describe RailsAiContext::Introspectors::PgPartitions do
  # relispartition is missing before 10, and a failed query aborts any open transaction.
  it "does not ask a PostgreSQL before 10, which has no partitions" do
    pg96 = double(adapter_name: "PostgreSQL", database_version: 9_06_24)
    expect(pg96).not_to receive(:select_values)

    expect(described_class.names(pg96)).to eq([])
  end

  it "asks a PostGIS connection, which is PostgreSQL" do
    postgis = double(adapter_name: "PostGIS", database_version: 17_00_09)
    allow(postgis).to receive(:select_values).and_return([ "parcels_2026" ])

    expect(described_class.names(postgis)).to eq([ "parcels_2026" ])
  end

  it "finds no partitions when the catalog query fails" do
    pg17 = double(adapter_name: "PostgreSQL", database_version: 17_00_09)
    allow(pg17).to receive(:select_values).and_raise(ActiveRecord::StatementInvalid, "PG::InsufficientPrivilege")

    expect(described_class.names(pg17)).to eq([])
  end

  it "leaves out pg_partition_root on a PostgreSQL before 12, which lacks it" do
    pg11 = double(adapter_name: "PostgreSQL", database_version: 11_00_16)
    queries = []
    allow(pg11).to receive(:select_all) { |sql| queries << sql and [] }

    described_class.table_rows(pg11)
    described_class.table_bytes(pg11)
    described_class.index_stats(pg11)

    expect(queries.size).to eq(3)
    expect(queries).to all(satisfy { |sql| !sql.include?("pg_partition_root") })
  end
end
