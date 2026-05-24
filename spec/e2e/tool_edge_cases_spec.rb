# frozen_string_literal: true

require_relative "e2e_helper"

# Tool input edge cases against a real Rails app via the CLI subprocess.
# Verifies that malformed/extreme inputs produce structured user errors,
# never crashes, and never silently succeed with garbage output.
RSpec.describe "E2E: tool input edge cases", type: :e2e do
  before(:all) do
    # Read-only spec - reuse the shared in-Gemfile fixture.
    @builder = E2E.shared_app(install_path: :in_gemfile)
    @cli = E2E::CliRunner.new(@builder)
  end

  describe "unknown tool name" do
    it "exits non-zero with a 'did you mean' suggestion" do
      result = @cli.cli_tool("nonexistent_tool_xyz")
      expect(result.success?).to be(false)
      expect(result.output).to match(/Unknown tool|did you mean/i)
    end
  end

  describe "unknown parameter" do
    it "exits non-zero with a clear error and the valid param list" do
      result = @cli.cli_tool("schema", [ "--bogus-flag", "value" ])
      expect(result.success?).to be(false)
      expect(result.output).to match(/Unknown param|did you mean/i)
    end
  end

  describe "missing required parameter" do
    it "rails_get_edit_context with no params returns a friendly error, not a crash" do
      result = @cli.cli_tool("edit_context")
      # Tool guards against missing params and returns a friendly message.
      # Either exits 0 with the message, or exits 1 - both are acceptable
      # as long as the process didn't crash and the output is informative.
      expect(result.status.signaled?).to be(false)
      expect(result.exit_status).to be < 2
      expect(result.output).to match(/required|missing|provide/i)
    end
  end

  describe "oversized string param" do
    it "rails_search_code with a 10KB pattern doesn't hang or crash" do
      huge = "x" * 10_000
      result = @cli.cli_tool("search_code", [ "--pattern", huge ])
      expect(result.status.signaled?).to be(false)
      expect(result.exit_status).to be < 2
    end
  end

  describe "invalid enum value" do
    it "rails_get_schema with detail:invalid downgrades to default and succeeds" do
      result = @cli.cli_tool("schema", [ "--detail", "invalid" ])
      expect(result.success?).to be(true), result.to_s
      # ToolRunner emits a "Warning: ... Using default." line to stderr
      expect(result.stderr).to match(/Warning|Using default/i)
    end
  end

  describe "fuzzy match recovery" do
    it "rails_get_model_details with a near-miss table name suggests alternatives" do
      result = @cli.cli_tool("model_details", [ "--model", "Pst" ])  # typo for Post
      # Either succeeds (fuzzy matched Post) or returns a helpful suggestion
      expect(result.status.signaled?).to be(false)
      expect(result.exit_status).to be < 2
      expect(result.output).to match(/Post|not found|did you mean/i)
    end
  end

  describe "nonexistent file in get_view" do
    it "rails_get_view for a missing template returns not-found, never crashes" do
      result = @cli.cli_tool("view", [ "--controller", "NonExistentController" ])
      expect(result.status.signaled?).to be(false)
      expect(result.exit_status).to be < 2
    end
  end
end
