# frozen_string_literal: true

require "spec_helper"

# An exception nobody planned for is an error on every surface: isError over
# MCP and exit 1 on the CLI. Answered as ordinary text, a crash read as a
# result and the exit code said nothing was wrong.
RSpec.describe "a tool that raises unexpectedly" do
  {
    RailsAiContext::Tools::Onboard => [ :cached_context, {} ],
    RailsAiContext::Tools::Diagnose => [ :classify_error, { error: "NoMethodError: undefined method `foo' for nil" } ],
    RailsAiContext::Tools::GenerateTest => [ :cached_context, { model: "User" } ],
    RailsAiContext::Tools::ReviewChanges => [ :rails_app, {} ],
    RailsAiContext::Tools::RuntimeInfo => [ :gather_cache, { section: "cache" } ],
    RailsAiContext::Tools::SessionContext => [ :render_status, { action: "status" } ]
  }.each do |tool, (seam, params)|
    it "#{tool.tool_name} answers with an error result" do
      allow(tool).to receive(seam).and_raise(NoMethodError, "undefined method 'to_sentence' for an instance of Array")

      response = tool.call(**params)

      expect(response.error?).to be(true), response.content.first[:text]
      expect(response.content.first[:text]).to start_with("Tool #{tool.tool_name} failed: NoMethodError: undefined method 'to_sentence'")
    end
  end

  it "marks the CLI run failed, which is exit 1" do
    allow(RailsAiContext::Tools::Onboard).to receive(:cached_context).and_raise(NoMethodError, "boom")
    runner = RailsAiContext::CLI::ToolRunner.new("onboard", [])

    expect(runner.run).to include("Tool rails_onboard failed: NoMethodError: boom")
    expect(runner.error).to be(true)
  end
end
