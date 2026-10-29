# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::CursorRulesSerializer do
  let(:context) do
    serializer_context(
      app_name: "App",
      schema: { adapter: "postgresql", total_tables: 10 },
      models: { "User" => { associations: [], validations: [], table_name: "users" } },
      routes: { total_routes: 50 },
      controllers: { controllers: { "UsersController" => { actions: %w[index show] } } }
    )
  end

  it "generates .cursor/rules/*.mdc files with YAML frontmatter" do
    allow(RailsAiContext.configuration).to receive(:generate_root_files).and_return(false)
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written]).not_to be_empty

      project_rule = File.read(File.join(dir, ".cursor", "rules", "rails-project.mdc"))
      expect(project_rule).to start_with("---")
      expect(project_rule).to include("alwaysApply: true", "- Database:")
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

  it "generates the MCP tools rule as always applied, standing in for the root file" do
    allow(RailsAiContext.configuration).to receive(:generate_root_files).and_return(false)
    Dir.mktmpdir do |dir|
      described_class.new(context).call(dir)

      tools_rule = File.read(File.join(dir, ".cursor", "rules", "rails-mcp-tools.mdc"))
      expect(tools_rule).to include("alwaysApply: true")
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

  # Cursor calls .cursorrules legacy and reads the root content from AGENTS.md.
  describe ".cursorrules" do
    it "is not written" do
      Dir.mktmpdir do |dir|
        result = described_class.new(context).call(dir)

        expect(File).not_to exist(File.join(dir, ".cursorrules"))
        expect(result[:written]).not_to include(File.join(dir, ".cursorrules"))
      end
    end

    it "loses the block an earlier release wrote and keeps the user's text around it" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".cursorrules")
        File.write(path, "# Above the gem\n<!-- BEGIN rails-ai-context -->\nold\n<!-- END rails-ai-context -->\n# Below the gem\n")

        result = described_class.new(context).call(dir)

        expect(File.read(path)).to eq("# Above the gem\n# Below the gem\n")
        expect(result[:trimmed]).to eq([ path ])
      end
    end

    it "is left alone when it holds only the user's own rules" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".cursorrules")
        File.write(path, "# My hand-written rules\n")

        result = described_class.new(context).call(dir)

        expect(File.read(path)).to eq("# My hand-written rules\n")
        expect(result.values_at(:removed, :trimmed).flatten).to be_empty
      end
    end
  end

  it "renders no routes line when the static tier refused routes" do
    allow(RailsAiContext.configuration).to receive(:generate_root_files).and_return(false)
    Dir.mktmpdir do |dir|
      refused = context.merge(routes: { unavailable: "requires a booted Rails app" })
      described_class.new(refused).call(dir)

      project_rule = File.read(File.join(dir, ".cursor", "rules", "rails-project.mdc"))
      expect(project_rule).not_to include("- Routes:")
    end
  end

  it "names the files it did not generate and why" do
    Dir.mktmpdir do |dir|
      empty = context.merge(models: {}, controllers: { controllers: {} })
      result = described_class.new(empty).call(dir)
      rules = File.join(dir, ".cursor", "rules")

      expect(result[:not_applicable]).to eq(
        File.join(rules, "rails-project.mdc") => "in the root file",
        File.join(rules, "rails-models.mdc") => "no models",
        File.join(rules, "rails-controllers.mdc") => "no controllers",
        File.join(rules, "rails-mcp-tools.mdc") => "in the root file"
      )
    end
  end
end
