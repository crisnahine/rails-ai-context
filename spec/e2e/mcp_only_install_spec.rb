# frozen_string_literal: true

require_relative "e2e_helper"

# `--mcp-only`: the MCP server and the CLI answer in full, and the gem writes
# to none of the files a user keeps by hand. Users who maintain their own
# CLAUDE.md, AGENTS.md and rules files had no supported way to ask for this.
RSpec.describe "E2E: MCP-only install", type: :e2e do
  before(:all) do
    @builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "mcp_only_app",
      install_path: :in_gemfile,
      generator_flags: [ "--mcp-only" ]
    ).build!
    @cli = E2E::CliRunner.new(@builder)
  end

  def app_file(relative) = File.join(@builder.app_path, relative)

  describe "what the install wrote" do
    it "writes the MCP config with the rails-ai-context entry" do
      expect(File.exist?(app_file(".mcp.json"))).to be(true)
      expect(File.read(app_file(".mcp.json"))).to include("rails-ai-context")
    end

    it "records the choice in the initializer and the YAML" do
      expect(File.read(app_file("config/initializers/rails_ai_context.rb")))
        .to include("config.context_files = false")
      expect(File.read(app_file(".rails-ai-context.yml"))).to include("context_files: false")
    end

    it "leaves every context file alone" do
      %w[
        CLAUDE.md .claude/rules AGENTS.md app/models/AGENTS.md app/controllers/AGENTS.md
        .cursor/rules .cursorrules .github/copilot-instructions.md .github/instructions
        .ai-context.json
      ].each do |relative|
        path = app_file(relative)
        expect(File.exist?(path) || Dir.exist?(path)).to be(false),
                                                         "expected #{relative} to be absent under --mcp-only"
      end
    end
  end

  describe "what still works" do
    it "`rails ai:context` writes nothing and exits 0" do
      result = @cli.run([ "bin/rails", "ai:context" ])

      expect(result.success?).to be(true), result.to_s
      expect(result.output).to include("MCP-only install")
      expect(File.exist?(app_file("CLAUDE.md"))).to be(false)
    end

    it "`rails ai:doctor` raises no context-file warning" do
      result = @cli.run([ "bin/rails", "ai:doctor" ])

      expect(result.output).not_to include("No context files generated")
    end

    it "answers tools/list over stdio with the full tool set" do
      client = E2E::McpStdioClient.new(@builder)
      begin
        client.start!
        client.initialize!
        tools = client.list_tools.dig("result", "tools") || []

        expect(tools.size).to eq(RailsAiContext::Server.builtin_tools.size)
      ensure
        client.stop!
      end
    end
  end
end
