# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Hydrators::SchemaHintBuilder do
  let(:context) do
    {
      models: {
        "Post" => {
          table_name: "posts",
          associations: [
            { name: "comments", type: "has_many", class_name: "Comment", foreign_key: "post_id" },
            { name: "user", type: "belongs_to", class_name: "User", foreign_key: "user_id" }
          ],
          validations: [
            { kind: "presence", attributes: [ "title" ] },
            { kind: "uniqueness", attributes: [ "slug" ] }
          ]
        },
        "User" => {
          table_name: "users",
          associations: [
            { name: "posts", type: "has_many", class_name: "Post", foreign_key: "user_id" }
          ],
          validations: [
            { kind: "presence", attributes: [ "email" ] }
          ]
        }
      },
      schema: {
        tables: {
          "posts" => {
            columns: [
              { name: "id", type: "integer", null: false },
              { name: "title", type: "string", null: false },
              { name: "body", type: "text" },
              { name: "user_id", type: "integer" }
            ],
            primary_key: "id"
          },
          "users" => {
            columns: [
              { name: "id", type: "integer", null: false },
              { name: "email", type: "string", null: false },
              { name: "name", type: "string" }
            ],
            primary_key: "id"
          }
        }
      }
    }
  end

  describe ".build" do
    it "builds a SchemaHint from context for a known model" do
      hint = described_class.build("Post", context: context)
      expect(hint).to be_a(RailsAiContext::SchemaHint)
      expect(hint.model_name).to eq("Post")
      expect(hint.table_name).to eq("posts")
      expect(hint.columns.size).to eq(4)
      expect(hint.associations.size).to eq(2)
      expect(hint.validations.size).to eq(2)
      expect(hint.primary_key).to eq("id")
      expect(hint.confidence).to eq("[VERIFIED]")
    end

    it "returns nil for unknown model" do
      expect(described_class.build("Nonexistent", context: context)).to be_nil
    end

    it "is case-insensitive for model lookup" do
      hint = described_class.build("post", context: context)
      expect(hint).to be_a(RailsAiContext::SchemaHint)
      expect(hint.model_name).to eq("Post")
    end

    it "returns nil when models data is missing" do
      expect(described_class.build("Post", context: {})).to be_nil
    end

    it "returns nil when schema data is missing" do
      expect(described_class.build("Post", context: { models: context[:models] })).to be_nil
    end

    it "sets INFERRED confidence when table is not in schema" do
      ctx = context.dup
      ctx[:schema] = { tables: {} }
      hint = described_class.build("Post", context: ctx)
      expect(hint.confidence).to eq("[INFERRED]")
      expect(hint.columns).to eq([])
    end
  end

  describe ".build_many" do
    it "builds hints for multiple known models" do
      hints = described_class.build_many(%w[Post User], context: context)
      expect(hints.size).to eq(2)
      expect(hints.map(&:model_name)).to eq(%w[Post User])
    end

    it "skips unknown models" do
      hints = described_class.build_many(%w[Post Nonexistent User], context: context)
      expect(hints.size).to eq(2)
      expect(hints.map(&:model_name)).to eq(%w[Post User])
    end

    it "respects max parameter" do
      hints = described_class.build_many(%w[Post User], context: context, max: 1)
      expect(hints.size).to eq(1)
    end
  end
end
