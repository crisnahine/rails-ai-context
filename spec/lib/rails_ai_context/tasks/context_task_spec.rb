# frozen_string_literal: true

require "spec_helper"
require "rake"
require "tmpdir"

# The installer's summary sends a user to `rails ai:context:cursor` to add
# Cursor. That wrote Cursor's rules, which tell the AI to call the MCP
# tools, and no .cursor/mcp.json to start them with.
RSpec.describe "rails ai:context:<tool>" do
  around do |example|
    Dir.mktmpdir do |tmp|
      @root = Pathname.new(File.realpath(tmp))
      example.run
    end
  end

  before do
    allow(Rails).to receive(:root).and_return(@root)
    allow(RailsAiContext).to receive(:generate_context).and_return(written: [], skipped: [], not_applicable: {})
    allow(RailsAiContext::LegacyCleanup).to receive(:prompt_legacy_files)
  end

  def with_tool_mode(mode)
    config = RailsAiContext.configuration
    was = config.tool_mode
    config.tool_mode = mode
    yield
  ensure
    config.tool_mode = was
  end

  it "writes the tool's MCP config in MCP mode, with the tool joining the selection" do
    out = with_tool_mode(:mcp) { invoke_rake_task("ai:context:cursor") }

    expect(@root.join(".cursor/mcp.json")).to exist
    expect(out).to include("Created/Updated .cursor/mcp.json")
    expect(RailsAiContext::Install::SelectionRecord.read(root: @root)).to eq([ :cursor ])
  end

  it "writes no MCP config in CLI mode" do
    with_tool_mode(:cli) { invoke_rake_task("ai:context:cursor") }

    expect(@root.join(".cursor/mcp.json")).not_to exist
  end

  it "writes none for the JSON export, which is no AI tool" do
    with_tool_mode(:mcp) { invoke_rake_task("ai:context:json") }

    expect(Dir.children(@root)).to be_empty
  end
end
