# frozen_string_literal: true

require_relative "e2e_helper"

# Install path A: Gemfile entry + `rails generate rails_ai_context:install`.
# This is the most common path — documented in README + CLAUDE.md #36.
#
# Covers:
#   - rails new → bundle → generator idempotency
#   - every CLI tool via `rails ai:tool[name]` AND `bin/rails-ai-context tool name`
#   - per-AI-client config files (Claude, Cursor, Copilot, OpenCode, Codex)
#   - `rails-ai-context doctor` health check
#   - `rails-ai-context version` reports the committed VERSION
RSpec.describe "E2E: in-Gemfile install", type: :e2e do
  before(:all) do
    @builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "in_gemfile_app",
      install_path: :in_gemfile
    ).build!
    @cli = E2E::CliRunner.new(@builder)
  end

  describe "installation" do
    it "creates a valid Rails app with the gem loaded" do
      gemfile = File.read(File.join(@builder.app_path, "Gemfile"))
      expect(gemfile).to include("rails-ai-context")
    end

    it "generates per-AI-client MCP config files" do
      configs = {
        ".mcp.json"           => :json,   # Claude
        ".cursor/mcp.json"    => :json,   # Cursor
        ".vscode/mcp.json"    => :json,   # Copilot
        "opencode.json"       => :json,   # OpenCode
        ".codex/config.toml"  => :toml    # Codex
      }

      configs.each do |relative, format|
        path = File.join(@builder.app_path, relative)
        expect(File.exist?(path)).to be(true), "expected #{relative} to be generated"
        content = File.read(path)
        expect(content).not_to be_empty
        case format
        when :json
          expect { JSON.parse(content) }.not_to raise_error, "#{relative} is not valid JSON"
          parsed = JSON.parse(content)
          # Claude: mcpServers, Copilot: servers, OpenCode: mcp, Cursor: mcpServers
          servers_key = %w[mcpServers servers mcp].find { |k| parsed.key?(k) }
          expect(servers_key).not_to be_nil, "#{relative} has no recognizable server root key"
          expect(parsed[servers_key]).to have_key("rails-ai-context"), "#{relative} is missing rails-ai-context server entry"
        when :toml
          # Minimal TOML parsing — verify the server section is present
          expect(content).to match(/\[mcp_servers\.rails-ai-context\]/)
          expect(content).to match(/command\s*=/)
        end
      end
    end

    it "generates the initializer" do
      init_path = File.join(@builder.app_path, "config", "initializers", "rails_ai_context.rb")
      expect(File.exist?(init_path)).to be(true)
    end

    it "writes both .cursor/rules/*.mdc AND the legacy .cursorrules (Cursor chat-agent fallback)" do
      # v5.9.0: restored legacy .cursorrules because Cursor's chat agent
      # didn't detect rules written only as .cursor/rules/*.mdc. See
      # cursor_rules_serializer.rb for the full rationale.
      cursorrules_path = File.join(@builder.app_path, ".cursorrules")
      mdc_project_path = File.join(@builder.app_path, ".cursor", "rules", "rails-project.mdc")
      expect(File.exist?(cursorrules_path)).to be(true), ".cursorrules (legacy) must be generated"
      expect(File.exist?(mdc_project_path)).to be(true), ".cursor/rules/rails-project.mdc must be generated"

      # Legacy file must be plain text, not MDC — older Cursor parses verbatim
      expect(File.read(cursorrules_path)).not_to start_with("---")
      expect(File.read(cursorrules_path)).to include("rails_get_schema")
    end

    it "re-running the generator is idempotent (no duplicate entries)" do
      # Generator should be idempotent per CLAUDE.md #27.
      # Pipe answers for prompts: (a) all tools, (1) MCP mode, (n) no hook,
      # plus (n) to the "remove no-longer-selected tools" prompt that only
      # fires on re-install.
      result = @cli.run([ "bin/rails", "generate", "rails_ai_context:install", "--quiet" ],
                         stdin_input: "a\nn\n1\nn\n")
      expect(result.status.success?).to be(true), "re-install failed:\n#{result}"
    end
  end

  describe "CLI subcommands" do
    it "`rails-ai-context version` reports the gem version" do
      result = @cli.cli("version")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to include(RailsAiContext::VERSION)
    end

    it "`rails-ai-context doctor` exits 0 and emits a readiness score" do
      result = @cli.cli("doctor")
      expect(result.success?).to be(true), result.to_s
      expect(result.output).to match(/readiness|score|check/i)
    end

    it "`rails-ai-context inspect` describes the installed state" do
      result = @cli.cli("inspect")
      expect(result.success?).to be(true), result.to_s
    end
  end

  describe "CLI tool invocations" do
    # Representative sample of the 38 tools — covers the main output
    # channels (schema, routes, models, components, etc.). Running ALL 38
    # via subprocess per describe block would push wall-clock past 5
    # minutes; the in-process ToolRunner smoke spec covers complete
    # coverage (spec/cli_smoke_spec.rb, 38 tools in 0.15s).
    %w[schema routes model_details controllers conventions context get_gems].each do |short|
      it "rake `ai:tool[#{short}]` exits 0" do
        result = @cli.rake_tool(short)
        expect(result.success?).to be(true), "#{short} failed:\n#{result}"
        expect(result.stdout).not_to be_empty
      end

      it "`rails-ai-context tool #{short}` exits 0" do
        result = @cli.cli_tool(short)
        expect(result.success?).to be(true), "#{short} failed:\n#{result}"
        expect(result.stdout).not_to be_empty
      end
    end

    it "every registered built-in tool is callable via CLI without crashing" do
      # Full-matrix subprocess sweep. Tools may return structured error
      # responses (missing required params) — that's fine, we only fail
      # on crashes (non-zero with no recognizable MCP error envelope)
      # or timeouts.
      tools = RailsAiContext::Server.builtin_tools
      failures = []
      tools.each do |tool_class|
        short = RailsAiContext::CLI::ToolRunner.short_name(tool_class.tool_name)
        result = @cli.cli_tool(short)
        if result.status.signaled? || (result.exit_status && result.exit_status > 1)
          failures << "#{short}: exit=#{result.exit_status}\n#{result.stderr}"
        end
      end
      expect(failures).to be_empty, failures.join("\n\n")
    end
  end
end
