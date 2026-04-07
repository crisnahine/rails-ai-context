# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Hydrators::HydrationFormatter do
  let(:hint) do
    RailsAiContext::SchemaHint.new(
      model_name: "Post",
      table_name: "posts",
      columns: [
        { name: "id", type: "integer", null: false },
        { name: "title", type: "string", null: false },
        { name: "body", type: "text" }
      ],
      associations: [
        { name: "comments", type: "has_many" },
        { name: "user", type: "belongs_to" }
      ],
      validations: [
        { kind: "presence", attributes: [ "title" ] }
      ],
      primary_key: "id",
      confidence: "[VERIFIED]"
    )
  end

  describe ".format" do
    it "returns empty string for nil" do
      expect(described_class.format(nil)).to eq("")
    end

    it "returns empty string for empty hydration result" do
      result = RailsAiContext::HydrationResult.new
      expect(described_class.format(result)).to eq("")
    end

    it "formats a hydration result with hints" do
      result = RailsAiContext::HydrationResult.new(hints: [ hint ])
      output = described_class.format(result)

      expect(output).to include("## Schema Hints")
      expect(output).to include("### Post [VERIFIED]")
      expect(output).to include("`posts`")
      expect(output).to include("`title` string NOT NULL")
      expect(output).to include("`has_many` :comments")
      expect(output).to include("`belongs_to` :user")
      expect(output).to include("presence(title)")
    end

    it "includes warnings" do
      result = RailsAiContext::HydrationResult.new(
        hints: [ hint ],
        warnings: [ "Model 'Foo' referenced but not found" ]
      )
      output = described_class.format(result)
      expect(output).to include("Model 'Foo' referenced but not found")
    end
  end

  describe ".format_hint" do
    it "truncates columns at 10" do
      many_columns = (1..15).map { |i| { name: "col_#{i}", type: "string" } }
      big_hint = RailsAiContext::SchemaHint.new(
        model_name: "Big", table_name: "bigs", columns: many_columns,
        associations: [], validations: [], primary_key: "id",
        confidence: "[VERIFIED]"
      )
      output = described_class.format_hint(big_hint)
      expect(output).to include("... 5 more")
    end
  end
end
