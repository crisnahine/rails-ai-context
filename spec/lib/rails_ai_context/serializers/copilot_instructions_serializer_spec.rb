# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::CopilotInstructionsSerializer do
  let(:context) do
    {
      app_name: "TestApp", rails_version: "8.0", ruby_version: "3.4",
      schema: { adapter: "postgresql", total_tables: 5 },
      routes: { total_routes: 30 },
      gems: {}, conventions: {},
      models: { "User" => { associations: [ { type: "has_many", name: "posts" } ], validations: [] } },
      controllers: { controllers: { "UsersController" => { actions: %w[index show] } } }
    }
  end

  it "generates .github/instructions/*.instructions.md with applyTo" do
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].size).to eq(4)

      models_file = File.read(File.join(dir, ".github", "instructions", "rails-models.instructions.md"))
      expect(models_file).to include("applyTo:")
      expect(models_file).to include("app/models/**/*.rb")
      expect(models_file).to include("User")

      ctrl_file = File.read(File.join(dir, ".github", "instructions", "rails-controllers.instructions.md"))
      expect(ctrl_file).to include("applyTo:")
      expect(ctrl_file).to include("app/controllers/**/*.rb")
      expect(ctrl_file).to include("UsersController")

      tools_file = File.read(File.join(dir, ".github", "instructions", "rails-mcp-tools.instructions.md"))
      expect(tools_file).to include("applyTo:")
      expect(tools_file).to include("Tools (37)")
      expect(tools_file).to include("rails_get_schema")
      expect(tools_file).to include('detail:"summary"')
    end
  end

  it "skips models file when no models" do
    context[:models] = {}
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].size).to eq(3) # context + controllers + mcp-tools
    end
  end

  it "skips controllers file when no controllers" do
    context[:controllers] = { controllers: {} }
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].size).to eq(3) # context + models + mcp-tools
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
end
