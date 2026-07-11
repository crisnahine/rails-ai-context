# frozen_string_literal: true

require "spec_helper"

# Runtime smoke test: every registered tool must execute via ToolRunner
# against the combustion fixture without raising. Tools are allowed to
# return error-shaped responses (that's a normal outcome for e.g. missing
# params) - but they must not crash.
RSpec.describe "CLI smoke: every tool executes", type: :smoke do
  RailsAiContext::Server.builtin_tools.each do |tool_class|
    short = RailsAiContext::CLI::ToolRunner.short_name(tool_class.tool_name)

    it "#{tool_class.tool_name} runs via ToolRunner without raising" do
      runner = RailsAiContext::CLI::ToolRunner.new(short, [])
      expect { runner.run }.not_to raise_error
    end
  end

  it "documents the static-tier flags" do
    help = `ruby #{File.expand_path('../exe/rails-ai-context', __dir__)} help serve 2>&1`
    expect(help).to include("--no-boot")
    expect(help).to include("--app-path")
    expect(help).to include("--environment")
  end
end
