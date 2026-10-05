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

  describe "a Mongoid document" do
    let(:mongoid_context) do
      { schema: { unavailable: "this app uses Mongoid; ActiveRecord schema introspection does not apply" },
        models: { "Book" => { mongoid: true, fields: [ { name: :title, type: "String" } ] },
                  "Admin::Shelf" => { mongoid: true, collection: "legacy_shelves", fields: [] } } }
    end

    it "names its collection and _id key, and lists its fields" do
      hint = described_class.build("Book", context: mongoid_context)
      expect(hint).to have_attributes(table_name: "books", primary_key: "_id", collection: true)
      expect(hint.columns).to eq([ { name: "title", type: "String" } ])
      expect(RailsAiContext::Hydrators::HydrationFormatter.format_hint(hint)).to include("**Collection:** `books` (key: `_id`)\n**Fields:** `title` String")
    end

    it "takes the collection store_in names" do
      expect(described_class.build("Admin::Shelf", context: mongoid_context).table_name).to eq("legacy_shelves")
    end
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

    it "renders a composite key as its names, and an array-shaped one as the name" do
      context[:schema][:tables]["posts"][:primary_key] = %w[tag_id account_id]
      context[:schema][:tables]["users"][:primary_key] = [ "id" ]

      expect(described_class.build("Post", context: context).primary_key).to eq("tag_id, account_id")
      expect(described_class.build("User", context: context).primary_key).to eq("id")
    end

    it "keeps a column's array flag, and the hint prints it" do
      context[:schema][:tables]["posts"][:columns] << { name: "tags", type: "string", array: true }

      hint = described_class.build("Post", context: context)
      expect(hint.columns.last).to eq({ name: "tags", type: "string", array: true })
      expect(RailsAiContext::Hydrators::HydrationFormatter.format_hint(hint)).to include("`tags` string[]")
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

    it "keeps the STATIC tag a static-tier model record already carries" do
      ctx = context.merge(models: context[:models].merge(
        "Post" => context[:models]["Post"].merge(confidence: "[STATIC]")
      ))
      hint = described_class.build("Post", context: ctx)
      expect(hint.confidence).to eq("[STATIC]")
    end

    it "sets VERIFIED confidence for a booted record, which carries no confidence key" do
      hint = described_class.build("Post", context: context)
      expect(hint.confidence).to eq("[VERIFIED]")
    end

    it "sets INFERRED confidence when table is not in schema" do
      ctx = context.dup
      ctx[:schema] = { tables: {} }
      hint = described_class.build("Post", context: ctx)
      expect(hint.confidence).to eq("[INFERRED]")
      expect(hint.columns).to eq([])
    end
  end

  it "reads the columns of a table in a secondary database" do
    ctx = { models: { "PageView" => { table_name: "page_views" } },
            schema: { tables: {}, secondary_databases: { "analytics" => { tables: { "page_views" => { columns: [ { name: "path", type: "string" } ] } } } } } }
    expect(described_class.build("PageView", context: ctx).columns.map { |c| c[:name] }).to eq([ "path" ])
  end
end
