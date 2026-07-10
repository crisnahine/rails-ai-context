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
  end
end
