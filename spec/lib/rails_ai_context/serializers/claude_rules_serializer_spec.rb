# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::ClaudeRulesSerializer do
  let(:context) do
    {
      app_name: "TestApp", rails_version: "8.0", ruby_version: "3.4",
      schema: {
        adapter: "postgresql",
        total_tables: 2,
        tables: {
          "users" => { columns: [ { name: "id" }, { name: "email" } ], primary_key: "id" },
          "posts" => { columns: [ { name: "id" }, { name: "title" } ], primary_key: "id" }
        }
      },
      models: {
        "User" => { table_name: "users", associations: [ { type: "has_many", name: "posts" } ], validations: [] },
        "Post" => { table_name: "posts", associations: [ { type: "belongs_to", name: "user" } ], validations: [] }
      },
      routes: { total_routes: 20 },
      gems: {},
      conventions: {}
    }
  end

  it "generates .claude/rules/ files" do
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].size).to eq(4)

      schema_file = File.join(dir, ".claude", "rules", "rails-schema.md")
      expect(File.exist?(schema_file)).to be true
      content = File.read(schema_file)
      expect(content).to include("users")
      expect(content).to include("rails_get_schema")

      models_file = File.join(dir, ".claude", "rules", "rails-models.md")
      expect(File.exist?(models_file)).to be true
      content = File.read(models_file)
      expect(content).to include("User")
      expect(content).to include("rails_get_model_details")

      tools_file = File.join(dir, ".claude", "rules", "rails-mcp-tools.md")
      expect(File.exist?(tools_file)).to be true
      content = File.read(tools_file)
      expect(content).to include("Tools (#{RailsAiContext::Server::TOOLS.size})")
      expect(content).to include("rails_get_schema")
      expect(content).to include('detail:"summary"')
    end
  end

  it "skips unchanged files" do
    Dir.mktmpdir do |dir|
      first = described_class.new(context).call(dir)
      expect(first[:written].size).to eq(4)

      second = described_class.new(context).call(dir)
      expect(second[:written].size).to eq(0)
      expect(second[:skipped].size).to eq(4)
    end
  end

  it "skips schema rule when no tables" do
    context[:schema] = { adapter: "postgresql", tables: {} }
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].size).to eq(3) # context + models + mcp-tools
    end
  end

  it "skips models rule when no models" do
    context[:models] = {}
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].size).to eq(3) # context + schema + mcp-tools
    end
  end

  describe "paths: frontmatter" do
    it "includes paths: frontmatter on schema rule" do
      Dir.mktmpdir do |dir|
        described_class.new(context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-schema.md"))
        expect(content).to start_with("---")
        expect(content).to include('- "db/schema.rb"')
        expect(content).to include('- "db/migrate/**"')
      end
    end

    it "includes paths: frontmatter on models rule" do
      Dir.mktmpdir do |dir|
        described_class.new(context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-models.md"))
        expect(content).to start_with("---")
        expect(content).to include('- "app/models/**/*.rb"')
      end
    end

    it "does NOT include paths: frontmatter on context rule" do
      Dir.mktmpdir do |dir|
        described_class.new(context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-context.md"))
        expect(content).not_to start_with("---")
      end
    end

    it "does NOT include paths: frontmatter on mcp-tools rule" do
      Dir.mktmpdir do |dir|
        described_class.new(context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-mcp-tools.md"))
        expect(content).not_to start_with("---")
      end
    end
  end

  it "names the files it did not generate and why" do
    context[:models] = {}
    context[:schema] = { tables: {} }
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      rules = File.join(dir, ".claude", "rules")

      expect(result[:not_applicable]).to eq(
        File.join(rules, "rails-schema.md") => "no schema dump",
        File.join(rules, "rails-models.md") => "no models",
        File.join(rules, "rails-components.md") => "no view components"
      )
      expect(File.exist?(File.join(rules, "rails-models.md"))).to be false
    end
  end
end
