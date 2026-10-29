# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::ModelSection do
  let(:width) { RailsAiContext::Serializers::Budget::LINE_WIDTH }

  # An app the size of a large private one: 600 models, the busiest with a
  # hundred associations and as many scopes.
  let(:context) do
    models = (1..600).to_h do |i|
      n = i <= 5 ? 100 : 3
      [ "Model#{i}", {
        table_name: "model#{i}s",
        associations: (1..n).map { |j| { type: "has_many", name: "things_#{i}_#{j}" } },
        validations: [ { kind: "presence", attributes: [ "name" ] } ],
        scopes: (1..n).map { |j| { name: "scope_#{j}" } },
        enums: { "status" => (1..n).map { |j| "state_#{j}" } }
      } ]
    end
    serializer_context(models: models)
  end

  let(:renderer) do
    Class.new(RailsAiContext::Serializers::Base) do
      include RailsAiContext::Serializers::StackOverviewHelper
      include RailsAiContext::Serializers::ToolGuideHelper
      include RailsAiContext::Serializers::ModelSection
    end.new(context)
  end

  %i[summary listing full].each do |density|
    it "keeps every #{density} line within the line width" do
      rows = renderer.model_rows(density)

      expect(rows.reject { |row| row.size <= width }).to eq([])
    end
  end

  it "names the most connected models in the root file and counts the rest" do
    rows = renderer.model_rows(:summary)
    named = rows.grep(/\A- \*\*Model\d+\*\*/).map { |row| row[/Model\d+/] }

    expect(named).to eq(%w[Model1 Model2 Model3 Model4 Model5 Model10 Model100 Model101 Model102 Model103].first(named.size))
    expect(named.size).to eq(RailsAiContext::Serializers::Budget.cap(:key_models))
    expect(rows.join("\n")).to include("...590 more")
  end

  # The share a model list takes is set by the caps, not by the app.
  it "costs the root file a bounded number of bytes whatever the app's size" do
    bytes = renderer.model_rows(:summary).join("\n").bytesize
    bound = RailsAiContext::Serializers::Budget.cap(:key_models) * 3 * width + 2 * width

    expect(bytes).to be <= bound
  end

  it "lists a rules file's models one row each, alphabetically, and counts the rest" do
    rows = renderer.model_rows(:listing)

    expect(rows.first).to start_with("- **Model1** (table: model1s) - has_many :things_1_1")
    expect(rows.last).to start_with("- ...570 more models")
  end

  it "writes the same summary into the root file" do
    root = RailsAiContext::Serializers::RootFile.new(context).call

    expect(root).to include(renderer.model_rows(:summary).first(3).join("\n"))
  end

  it "writes the same rows into every rules file's model list" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      RailsAiContext::Serializers::ClaudeRulesSerializer.new(context).call(dir)
      RailsAiContext::Serializers::CursorRulesSerializer.new(context).call(dir)
      RailsAiContext::Serializers::CopilotInstructionsSerializer.new(context).call(dir)
      RailsAiContext::Serializers::OpencodeRulesSerializer.new(context).call(dir)
      first = renderer.model_rows(:listing).first

      %w[.claude/rules/rails-models.md .cursor/rules/rails-models.mdc .github/instructions/rails-models.instructions.md app/models/AGENTS.md].each do |path|
        expect(File.read(File.join(dir, path))).to include(first), path
      end
    end
  end
end
