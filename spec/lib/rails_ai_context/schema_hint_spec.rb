# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::SchemaHint do
  let(:hint) do
    described_class.new(
      model_name: "Post",
      table_name: "posts",
      columns: [
        { name: "id", type: "integer", null: false },
        { name: "title", type: "string", null: false },
        { name: "body", type: "text" }
      ],
      associations: [
        { name: "comments", type: "has_many", class_name: "Comment" },
        { name: "user", type: "belongs_to", class_name: "User", foreign_key: "user_id" }
      ],
      validations: [
        { kind: "presence", attributes: [ "title" ] }
      ],
      primary_key: "id",
      confidence: "[VERIFIED]"
    )
  end

  it "is immutable" do
    expect(hint).to be_frozen
  end

  it "exposes all attributes" do
    expect(hint.model_name).to eq("Post")
    expect(hint.table_name).to eq("posts")
    expect(hint.columns.size).to eq(3)
    expect(hint.associations.size).to eq(2)
    expect(hint.validations.size).to eq(1)
    expect(hint.primary_key).to eq("id")
    expect(hint.confidence).to eq("[VERIFIED]")
  end

  describe "#verified?" do
    it "returns true for VERIFIED confidence" do
      expect(hint.verified?).to be true
    end

    it "returns false for INFERRED confidence" do
      inferred = described_class.new(**hint.to_h.merge(confidence: "[INFERRED]"))
      expect(inferred.verified?).to be false
    end
  end

  describe "#column_names" do
    it "returns array of column name strings" do
      expect(hint.column_names).to eq(%w[id title body])
    end
  end

  describe "#association_names" do
    it "returns array of association name strings" do
      expect(hint.association_names).to eq(%w[comments user])
    end
  end
end

RSpec.describe RailsAiContext::HydrationResult do
  describe "with defaults" do
    let(:result) { described_class.new }

    it "defaults to empty hints and warnings" do
      expect(result.hints).to eq([])
      expect(result.warnings).to eq([])
    end

    it "returns false for any?" do
      expect(result.any?).to be false
    end
  end

  describe "with hints" do
    let(:hint) do
      RailsAiContext::SchemaHint.new(
        model_name: "Post", table_name: "posts", columns: [],
        associations: [], validations: [], primary_key: "id",
        confidence: "[VERIFIED]"
      )
    end
    let(:result) { described_class.new(hints: [ hint ]) }

    it "returns true for any?" do
      expect(result.any?).to be true
    end
  end
end
