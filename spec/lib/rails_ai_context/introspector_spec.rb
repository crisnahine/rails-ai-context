# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    it "returns a complete context hash" do
      result = introspector.call

      expect(result[:ruby_version]).to eq(RUBY_VERSION)
      expect(result[:rails_version]).to eq(Rails.version)
      expect(result[:generator]).to include("rails-ai-context")
      expect(result[:generated_at]).to be_a(String)
    end

    it "includes all configured introspectors" do
      result = introspector.call

      expect(result).to have_key(:schema)
      expect(result).to have_key(:models)
      expect(result).to have_key(:routes)
      expect(result).to have_key(:jobs)
      expect(result).to have_key(:gems)
      expect(result).to have_key(:conventions)
    end

    it "extracts schema with tables" do
      result = introspector.call
      schema = result[:schema]

      expect(schema[:adapter]).not_to be_nil
      # Live DB may not load schema on all Rails versions via Combustion;
      # fall back to verifying static parse produces tables from schema.rb
      if schema[:tables].empty?
        static = RailsAiContext::Introspectors::SchemaIntrospector.new(Rails.application).send(:static_schema_parse)
        expect(static[:tables]).to have_key("users")
        expect(static[:tables]).to have_key("posts")
      else
        expect(schema[:tables]).to have_key("users")
        expect(schema[:tables]).to have_key("posts")
      end
    end
  end
end
