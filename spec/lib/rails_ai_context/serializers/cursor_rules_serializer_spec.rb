# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::CursorRulesSerializer do
  let(:context) do
    {
      app_name: "App", rails_version: "8.0", ruby_version: "3.4",
      schema: { adapter: "postgresql", total_tables: 10 },
      models: { "User" => { associations: [], validations: [], table_name: "users" } },
      routes: { total_routes: 50 },
      gems: {},
      conventions: {},
      controllers: { controllers: { "UsersController" => { actions: %w[index show] } } }
    }
  end

  it "generates .cursor/rules/*.mdc files with YAML frontmatter" do
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written]).not_to be_empty

      project_rule = File.read(File.join(dir, ".cursor", "rules", "rails-project.mdc"))
      expect(project_rule).to start_with("---")
      expect(project_rule).to include("alwaysApply: true")
      expect(project_rule).to include("MCP tools")
    end
  end

  it "generates models rule with glob" do
    Dir.mktmpdir do |dir|
      described_class.new(context).call(dir)

      models_rule = File.read(File.join(dir, ".cursor", "rules", "rails-models.mdc"))
      expect(models_rule).to include("app/models/**/*.rb")
      expect(models_rule).to include("alwaysApply: false")
      expect(models_rule).to include("User")
    end
  end

  it "generates controllers rule with glob" do
    Dir.mktmpdir do |dir|
      described_class.new(context).call(dir)

      ctrl_rule = File.read(File.join(dir, ".cursor", "rules", "rails-controllers.mdc"))
      expect(ctrl_rule).to include("app/controllers/**/*.rb")
      expect(ctrl_rule).to include("UsersController")
    end
  end

  it "skips models rule when no models" do
    context[:models] = {}
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].any? { |f| f.include?("rails-models.mdc") }).to be false
    end
  end

  it "skips controllers rule when no controllers" do
    context[:controllers] = { controllers: {} }
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].any? { |f| f.include?("rails-controllers.mdc") }).to be false
    end
  end

  it "generates MCP tools rule as agent-requested (alwaysApply false)" do
    Dir.mktmpdir do |dir|
      described_class.new(context).call(dir)

      tools_rule = File.read(File.join(dir, ".cursor", "rules", "rails-mcp-tools.mdc"))
      expect(tools_rule).to include("alwaysApply: false")
      expect(tools_rule).to include("Tools (#{RailsAiContext::Server::TOOLS.size})")
      expect(tools_rule).to include("rails_get_schema")
      expect(tools_rule).to include("Step-by-step workflows")
    end
  end

  it "skips unchanged files" do
    Dir.mktmpdir do |dir|
      first = described_class.new(context).call(dir)
      second = described_class.new(context).call(dir)
      expect(second[:written]).to be_empty
      expect(second[:skipped].size).to eq(first[:written].size)
    end
  end

  # v5.9.0 regression: real user report during release QA — Cursor chat
  # agent didn't detect rules written only as .cursor/rules/*.mdc. Writing
  # .cursorrules alongside (legacy format) fixed it. Ensure both are
  # produced so neither older Cursor builds nor newer ones miss the rules.
  it "also writes a legacy .cursorrules at the project root" do
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      cursorrules_path = File.join(dir, ".cursorrules")
      expect(result[:written]).to include(cursorrules_path)
      expect(File.exist?(cursorrules_path)).to be true

      content = File.read(cursorrules_path)
      # Plain text — no frontmatter — so every Cursor build reads it.
      expect(content).not_to start_with("---")
      # Must surface the gem's presence + name a couple of the MCP tools
      # so the chat agent knows to use them rather than guess.
      expect(content).to include("rails-ai-context")
      expect(content).to include("rails_get_schema")
      expect(content).to include("rails_get_routes")
      expect(content).to include("App")  # app name from context
    end
  end
end
