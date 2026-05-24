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
  end
end
