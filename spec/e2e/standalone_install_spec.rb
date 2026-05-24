# frozen_string_literal: true

require_relative "e2e_helper"

# Install path B: Standalone - `gem install rails-ai-context` into an
# isolated GEM_HOME (no Gemfile entry), then run `rails-ai-context init`
# from inside the Rails app directory. CLAUDE.md #33 documents that this
# path pre-loads the gem before Rails boot and restores $LOAD_PATH entries
# stripped by `Bundler.setup`.
#
# This is the path most users take when they don't want to modify their
# Gemfile (shared apps, short-lived exploration, gem-install-then-try).
RSpec.describe "E2E: standalone install", type: :e2e do
  before(:all) do
    @builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "standalone_app",
      install_path: :standalone
    ).build!
    @cli = E2E::CliRunner.new(@builder)
  end

  describe "installation" do
    it "installs the gem to an isolated GEM_HOME" do
      expect(File.exist?(File.join(@builder.gem_home, "bin", "rails-ai-context"))).to be(true)
    end

    it "does NOT add a gem line to the Gemfile" do
      gemfile = File.read(File.join(@builder.app_path, "Gemfile"))
      expect(gemfile).not_to include("rails-ai-context")
    end

    it "generates per-AI-client MCP config files (same as in-Gemfile path)" do
      %w[.mcp.json .cursor/mcp.json .vscode/mcp.json opencode.json .codex/config.toml].each do |relative|
        path = File.join(@builder.app_path, relative)
        expect(File.exist?(path)).to be(true), "expected #{relative} to be generated"
      end
    end
  end

  describe "CLI works without a Gemfile entry" do
    it "`rails-ai-context version` reports the gem version" do
      result = @cli.cli("version")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to include(RailsAiContext::VERSION)
    end

    it "`rails-ai-context tool schema` returns the Post table" do
      result = @cli.cli_tool("schema")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to match(/posts|Post/)
    end

    it "`rails-ai-context tool routes` returns scaffolded post routes" do
      result = @cli.cli_tool("routes")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to match(/posts|Post/)
    end

    it "`rails-ai-context doctor` completes successfully" do
      result = @cli.cli("doctor")
      expect(result.success?).to be(true), result.to_s
    end
  end
end
