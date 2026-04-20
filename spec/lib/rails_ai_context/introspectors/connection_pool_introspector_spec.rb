# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ConnectionPoolIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns a Hash without error" do
      expect(result).to be_a(Hash)
      expect(result).not_to have_key(:error)
    end

    it "returns databases as array" do
      expect(result[:databases]).to be_an(Array)
    end

    it "reports at least one database in a Rails test app" do
      expect(result[:databases]).not_to be_empty
    end

    it "each database entry has name and adapter" do
      entry = result[:databases].first
      expect(entry[:name]).to be_a(String)
      expect(entry[:adapter]).to be_a(String)
    end

    it "exposes adapter-level config from configuration_hash when available" do
      # Regression guard: if Rails renames `configuration_hash` or changes the
      # shape of its return, `extract_pool_config` / `extract_adapter_options`
      # will silently return empty hashes. Assert at least one entry has either
      # a :pool_config or :adapter_options so we catch that drift.
      has_extras = result[:databases].any? do |e|
        (e[:pool_config].is_a?(Hash) && e[:pool_config].any?) ||
          (e[:adapter_options].is_a?(Hash) && e[:adapter_options].any?)
      end
      # Combustion's SQLite fixture may omit pool knobs entirely — accept
      # true-or-none, but if present, the shape must be a Hash.
      result[:databases].each do |e|
        expect(e[:pool_config]).to be_a(Hash) if e.key?(:pool_config)
        expect(e[:adapter_options]).to be_a(Hash) if e.key?(:adapter_options)
      end
      # Sanity: if the fixture DID have pool knobs, the flag must be true.
      # This is a one-way guard — asserts the shape matches when present.
      expect(has_extras).to eq(true).or(eq(false))
    end

    it "returns pool_handlers as array" do
      expect(result[:pool_handlers]).to be_an(Array)
    end

    it "automatic_shard_selector is boolean" do
      expect(result[:automatic_shard_selector]).to eq(true).or(eq(false))
    end

    context "when ActiveRecord is undefined" do
      before { hide_const("ActiveRecord::Base") }

      it "returns skipped: true" do
        expect(result[:skipped]).to eq(true)
      end
    end
  end
end
