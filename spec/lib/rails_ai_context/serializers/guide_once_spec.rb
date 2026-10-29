# frozen_string_literal: true

require "spec_helper"

# The root file's tools guide is loaded in every session, so each thing it
# says it says once, in the form the tool mode uses, and plainly: Claude
# Code's docs say piled-on emphasis makes Claude over-apply a rule.
RSpec.describe "The tools guide in the root file" do
  let(:context) { RailsAiContext.introspect }

  around do |example|
    mode = RailsAiContext.configuration.tool_mode
    example.run
  ensure
    RailsAiContext.configuration.tool_mode = mode
  end

  def root_file(mode)
    RailsAiContext.configuration.tool_mode = mode
    RailsAiContext::Serializers::RootFile.new(context).call
  end

  # Words a reader meets in capitals anyway. A local: a constant here lands on Object.
  acronyms = %w[MCP CLI API JSON SQL ERB HTML URL CSS RSS XML YAML STI FK FKS ID UUID HTTP PATCH GET POST PUT DELETE AI RSPEC N/A TODO README].freeze

  %i[mcp cli].each do |mode|
    it "shouts nothing in :#{mode} mode" do
      prose = root_file(mode).gsub(/`[^`]*`/, "").gsub(/\[[A-Z_]+[^\]]*\]/, "")
      shouted = prose.scan(/\b[A-Z]{3,}\b/).uniq - acronyms

      expect(shouted).to eq([])
    end

    it "says to read a file only to edit it once, in :#{mode} mode" do
      expect(root_file(mode).scan(/read (?:a |the )?files? only/i).size).to eq(1)
    end

    it "states the validate rule once, in :#{mode} mode" do
      expect(root_file(mode).scan(/after (?:each|every) edit/i).size).to eq(1)
    end
  end

  # The MCP client lists the tools and their parameters itself.
  it "gives each example in its MCP form alone in :mcp mode" do
    output = root_file(:mcp)

    expect(output).not_to include("→ CLI:", "` or `rails", "` or `rails-ai-context")
    expect(output).to include("rails_get_context(")
    expect(output).not_to match(/^### All \d+ tools/)
  end

  # The eval saw an agent read the model file and miss an association a
  # concern declares, and read db/schema.rb once the rule named no tool for it.
  it "maps each reference question to the call that answers it" do
    output = root_file(:mcp)

    expect(output).to include("1. **Read a file only to edit it.** For reference, ask the tool:\n" \
                              "   - a table's columns, indexes and keys: `rails_get_schema(table:\"X\")`\n" \
                              "   - a model's associations, validations and scopes, its concerns' included: `rails_get_model_details(model:\"X\")`")
  end

  it "lists the commands in :cli mode, where nothing else does" do
    output = root_file(:cli)

    expect(output).to match(/^### All \d+ tools/)
    expect(output).not_to include("rails_get_context(")
  end

  # In :cli mode the commands are the reference an agent asks on request.
  it "says where a command's parameters are in :cli mode" do
    expect(root_file(:cli)).to include("--help")
  end

  # With root files off, the overview rule and the guide rule both load in
  # every session, so the overview carries no rule of its own.
  it "states each rule once across the always-loaded rules when root files are off" do
    Dir.mktmpdir do |dir|
      allow(RailsAiContext.configuration).to receive(:generate_root_files).and_return(false)
      RailsAiContext.configuration.tool_mode = :mcp
      RailsAiContext::Serializers::ClaudeRulesSerializer.new(context).call(dir)
      always = %w[rails-context.md rails-mcp-tools.md].map { |name| File.read(File.join(dir, ".claude/rules", name)) }.join

      expect(always.scan(/read a file only/i).size).to eq(1)
      expect(always.scan(/start with `?detail/i).size).to be <= 1
    end
  end

  it "names the CLI fallback once in :mcp mode" do
    expect(root_file(:mcp).scan("not connected").size).to eq(1)
  end
end
