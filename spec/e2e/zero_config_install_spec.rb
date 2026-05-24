# frozen_string_literal: true

require_relative "e2e_helper"

# Install path C: Zero-config - `gem install rails-ai-context` into an
# isolated GEM_HOME, then run `rails-ai-context serve` (or any CLI tool)
# directly without running `init` or the Rails generator. Nothing is
# written to the app, no Gemfile entry, no config files. Useful for
# "just try it" scenarios and ensures CLI tools work with pure defaults.
RSpec.describe "E2E: zero-config install", type: :e2e do
  before(:all) do
    @builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "zero_config_app",
      install_path: :zero_config
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

    it "does NOT generate per-AI-client config files (no init run)" do
      # Zero-config path deliberately skips init - config files should be absent.
      %w[.mcp.json .cursor/mcp.json .vscode/mcp.json opencode.json .codex/config.toml].each do |relative|
        path = File.join(@builder.app_path, relative)
        expect(File.exist?(path)).to be(false), "expected #{relative} to NOT exist in zero-config mode"
      end
    end

    it "does NOT generate the initializer" do
      init_path = File.join(@builder.app_path, "config", "initializers", "rails_ai_context.rb")
      expect(File.exist?(init_path)).to be(false)
    end
  end

  describe "CLI still works with defaults" do
    it "`rails-ai-context version` reports the gem version" do
      result = @cli.cli("version")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to include(RailsAiContext::VERSION)
    end

    it "`rails-ai-context tool schema` returns the Post table without any config" do
      result = @cli.cli_tool("schema")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to match(/posts|Post/)
    end

    it "`rails-ai-context tool routes` works without any config" do
      result = @cli.cli_tool("routes")
      expect(result.success?).to be(true), result.to_s
    end

    it "`rails-ai-context tool model_details` works without any config" do
      result = @cli.cli_tool("model_details")
      expect(result.success?).to be(true), result.to_s
    end
  end
end
