# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe RailsAiContext::Serializers::JsonSerializer do
  describe "#call" do
    it "returns valid JSON" do
      context = { app_name: "TestApp", rails_version: "8.0" }
      output = described_class.new(context).call
      parsed = JSON.parse(output)
      expect(parsed).to be_a(Hash)
    end

    it "leaves out a foreign key's actual_name" do
      context = { schema: { tables: { "kids" => { foreign_keys: [ { column: "pa", actual_name: "fk_rails_0123456789" } ] } } } }

      expect(described_class.new(context).call).not_to include("actual_name")
    end

    it "preserves all context keys" do
      context = { app_name: "MyApp", rails_version: "8.0", ruby_version: "3.4" }
      output = described_class.new(context).call
      parsed = JSON.parse(output)
      expect(parsed["app_name"]).to eq("MyApp")
      expect(parsed["rails_version"]).to eq("8.0")
      expect(parsed["ruby_version"]).to eq("3.4")
    end

    it "produces pretty-printed output" do
      context = { key: "value" }
      output = described_class.new(context).call
      expect(output).to include("\n")
      expect(output.lines.count).to be > 1
    end

    it "handles nested hashes" do
      context = { schema: { tables: { users: { columns: %w[id name email] } } } }
      output = described_class.new(context).call
      parsed = JSON.parse(output)
      expect(parsed.dig("schema", "tables", "users", "columns")).to eq(%w[id name email])
    end

    it "handles arrays" do
      context = { models: %w[User Post Comment] }
      output = described_class.new(context).call
      parsed = JSON.parse(output)
      expect(parsed["models"]).to eq(%w[User Post Comment])
    end

    it "handles empty context" do
      output = described_class.new({}).call
      parsed = JSON.parse(output)
      expect(parsed).to eq({})
    end

    it "serializes symbol keys as strings" do
      context = { app_name: "App" }
      output = described_class.new(context).call
      parsed = JSON.parse(output)
      expect(parsed).to have_key("app_name")
    end

    it "handles nil values" do
      context = { app_name: "App", database: nil }
      output = described_class.new(context).call
      parsed = JSON.parse(output)
      expect(parsed["database"]).to be_nil
    end

    it "exposes context via attr_reader" do
      context = { app_name: "App" }
      serializer = described_class.new(context)
      expect(serializer.context).to eq(context)
    end

    it "handles complex nested structures from introspection" do
      context = {
        app_name: "BigApp",
        schema: { adapter: "postgresql", tables: { users: { columns: 5 } } },
        models: { "User" => { associations: [ { type: "has_many", name: "posts" } ] } },
        routes: { total_routes: 50, by_controller: { "UsersController" => 5 } }
      }
      output = described_class.new(context).call
      parsed = JSON.parse(output)
      expect(parsed.dig("models", "User", "associations")).to be_an(Array)
      expect(parsed.dig("routes", "total_routes")).to eq(50)
    end
  end
end
