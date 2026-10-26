# frozen_string_literal: true

require "spec_helper"

# The booted tier's MySQL and MariaDB reads that a double cannot vouch for. Runs only when RAC_TEST_MYSQL_URL is set.
RSpec.describe RailsAiContext::Introspectors::SchemaIntrospector, skip: (ENV["RAC_TEST_MYSQL_URL"] ? false : "set RAC_TEST_MYSQL_URL to run against MySQL") do
  let(:conn) { RacMysqlSchemaRecord.connection }
  let(:introspector) { described_class.new(Rails.application) }

  before do
    stub_const("RacMysqlSchemaRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RacMysqlSchemaRecord.establish_connection(ENV.fetch("RAC_TEST_MYSQL_URL"))
    allow(introspector).to receive_messages(connection: conn, adapter_name: conn.adapter_name)
  end

  after { RacMysqlSchemaRecord.remove_connection }

  # schema.rb writes precision: nil for a datetime with no precision or datetime(0), and nothing for datetime(6).
  it "reads a datetime with no precision as precision: nil and datetime(6) as the default" do
    conn.execute("DROP TABLE IF EXISTS rac_my_prec")
    conn.execute("CREATE TABLE rac_my_prec (a datetime, b datetime(6), c datetime(3), d datetime(0), e timestamp(6) NULL, f time)")

    precisions = introspector.send(:extract_columns, "rac_my_prec").to_h { |c| [ c[:name], c.key?(:precision) ? c[:precision] : :default ] }

    expect(precisions).to eq("a" => nil, "b" => :default, "c" => 3, "d" => nil, "e" => :default, "f" => :default)
  ensure
    conn.execute("DROP TABLE IF EXISTS rac_my_prec")
  end
end
