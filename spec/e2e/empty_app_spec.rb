# frozen_string_literal: true

require_relative "e2e_helper"

# Empty Rails app - no scaffold, no models, no controllers beyond
# ApplicationController, no routes beyond root. Every built-in tool MUST
# handle this gracefully (return a structured "no X found" response, not
# crash with NoMethodError or raise an exception).
#
# This is the harshest stress test for tools that assume Rails app
# fixtures exist. If a tool crashes here, it'll crash on any greenfield
# Rails app that hasn't started building features yet - which is exactly
# the moment a developer is most likely to install rails-ai-context.
RSpec.describe "E2E: empty Rails app", type: :e2e do
  before(:all) do
    # Skip the scaffold step that the regular TestAppBuilder runs by
    # subclassing it to no-op `scaffold_sample_model!`.
    @builder = build_empty_app
    @cli = E2E::CliRunner.new(@builder)
  end

  describe "every built-in tool exits cleanly" do
    # Each tool must either succeed (exit 0, even if output is "no X
    # found") or fail with a user-friendly structured error (exit 1
    # with a recognizable message). What we DON'T tolerate: signals,
    # uncaught exceptions, exit codes >= 2, or empty stderr+stdout.
    RailsAiContext::Server.builtin_tools.each do |tool_class|
      short = RailsAiContext::CLI::ToolRunner.short_name(tool_class.tool_name)

      it "#{tool_class.tool_name} doesn't crash on an empty app" do
        result = @cli.cli_tool(short)
        # Crash detection: signaled OR exit code >= 2.
        expect(result.status.signaled?).to be(false), "#{short} died from signal:\n#{result}"
        expect(result.exit_status).to be < 2, "#{short} exit=#{result.exit_status}:\n#{result}"
        # Must produce SOME output - silent failure is the worst kind.
        expect(result.output.strip).not_to be_empty, "#{short} produced no output"
      end
    end
  end

  private

  def build_empty_app
    # Use TestAppBuilder, then override scaffold to no-op via a singleton.
    builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "empty_app",
      install_path: :in_gemfile
    )
    # Stub out scaffold so we get a truly bare app (no Post model).
    def builder.scaffold_sample_model!
      # no-op - empty app deliberately has no models/scaffolds
    end
    builder.build!
  end
end
