# frozen_string_literal: true

require "spec_helper"

# The booted tier's PostgreSQL reads that a double cannot vouch for. Runs only when RAC_TEST_PG_URL is set.
RSpec.describe RailsAiContext::Introspectors::SchemaIntrospector, skip: (ENV["RAC_TEST_PG_URL"] ? false : "set RAC_TEST_PG_URL to run against PostgreSQL") do
  let(:conn) { RacPgSchemaRecord.connection }
  let(:introspector) { described_class.new(Rails.application) }
  let(:schemas) { [ 'rac "s', "rac,b", "rac\\slash", "rac_c" ] }

  before do
    stub_const("RacPgSchemaRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RacPgSchemaRecord.establish_connection(ENV.fetch("RAC_TEST_PG_URL"))
    schemas.each { |name| conn.execute("CREATE SCHEMA IF NOT EXISTS #{conn.quote_column_name(name)}") }
    allow(introspector).to receive_messages(connection: conn, adapter_name: "PostgreSQL")
  end

  after do
    conn.execute("RESET search_path")
    schemas.each { |name| conn.execute("DROP SCHEMA IF EXISTS #{conn.quote_column_name(name)}") }
    RacPgSchemaRecord.remove_connection
  end

  it "reads the search path in order, a schema name with a comma, a quote and a backslash whole" do
    conn.execute("SET search_path TO #{(schemas + [ 'public' ]).map { |name| conn.quote_column_name(name) }.join(', ')}")

    expect(introspector.send(:live_search_path)).to eq(schemas + [ "public" ])
  end

  # The dumper (and ForeignKeyDefinition#export_name_on_schema_dump?) leaves out a name matching SchemaDumper.fk_ignore_pattern.
  it "names a foreign key as the dumper does, by the app's fk_ignore_pattern" do
    conn.execute("DROP TABLE IF EXISTS rac_pg_fk_posts CASCADE; DROP TABLE IF EXISTS rac_pg_fk_users CASCADE")
    conn.execute("CREATE TABLE rac_pg_fk_users (id bigint PRIMARY KEY)")
    conn.execute("CREATE TABLE rac_pg_fk_posts (id bigint PRIMARY KEY, a bigint, b bigint, c bigint)")
    { "a" => "fk_rails_f868b47f6a", "b" => "my_fk", "c" => "tmp_fk" }.each do |column, name|
      conn.execute("ALTER TABLE rac_pg_fk_posts ADD CONSTRAINT #{name} FOREIGN KEY (#{column}) REFERENCES rac_pg_fk_users (id)")
    end
    names = -> { introspector.send(:extract_foreign_keys, "rac_pg_fk_posts").to_h { |fk| [ fk[:column], fk[:name] ] } }

    expect(names.call).to eq("a" => nil, "b" => "my_fk", "c" => "tmp_fk")
    original = ActiveRecord::SchemaDumper.fk_ignore_pattern
    begin
      ActiveRecord::SchemaDumper.fk_ignore_pattern = /\Atmp_/
      expect(names.call).to eq("a" => "fk_rails_f868b47f6a", "b" => "my_fk", "c" => nil)
    ensure
      ActiveRecord::SchemaDumper.fk_ignore_pattern = original
    end
  ensure
    conn.execute("DROP TABLE IF EXISTS rac_pg_fk_posts CASCADE; DROP TABLE IF EXISTS rac_pg_fk_users CASCADE")
  end

  # PostgreSQL's connection.indexes lists the index behind a unique or exclusion constraint; the dumper writes the constraint alone.
  it "lists the constraint and not the index a unique or exclusion constraint owns" do
    conn.execute("DROP TABLE IF EXISTS rac_pg_owned")
    conn.execute("CREATE TABLE rac_pg_owned (n integer, m integer, k integer, CONSTRAINT rac_uniq_n UNIQUE (n), CONSTRAINT rac_excl_m EXCLUDE USING btree (m WITH =))")
    conn.execute("CREATE INDEX rac_idx_k ON rac_pg_owned (k)")

    entry = introspector.send(:table_entry, "rac_pg_owned")

    expect(conn.indexes("rac_pg_owned").map(&:name)).to include("rac_uniq_n", "rac_excl_m")
    expect(entry[:indexes].map { |idx| idx[:name] }).to eq(%w[rac_idx_k])
    expect(entry[:unique_constraints].map { |c| c[:name] }).to eq(%w[rac_uniq_n])
    expect(entry[:exclusion_constraints].map { |c| c[:name] }).to eq(%w[rac_excl_m])
  ensure
    conn.execute("DROP TABLE IF EXISTS rac_pg_owned")
  end

  # schema.rb writes precision: nil for the timestamp with no precision and nothing for timestamp(6).
  it "reads a timestamp with no precision as precision: nil and timestamp(6) as the default" do
    conn.execute("DROP TABLE IF EXISTS rac_pg_prec")
    conn.execute("CREATE TABLE rac_pg_prec (a timestamp, b timestamp(6), c timestamp(3), d timestamp(0), e timestamptz, f time)")

    precisions = introspector.send(:extract_columns, "rac_pg_prec").to_h { |c| [ c[:name], c.key?(:precision) ? c[:precision] : :default ] }

    expect(precisions).to eq("a" => nil, "b" => :default, "c" => 3, "d" => 0, "e" => :default, "f" => :default)
  ensure
    conn.execute("DROP TABLE IF EXISTS rac_pg_prec")
  end
end
