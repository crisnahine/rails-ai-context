# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "generators/rails_ai_context/install/install_generator"

RSpec.describe RailsAiContext::Install::AiTool do
  describe ".all" do
    it "lists the five supported tools in prompt order" do
      expect(described_class.all.map(&:key)).to eq(%i[claude cursor copilot opencode codex])
    end

    it "numbers them from one" do
      expect(described_class.all.map(&:number)).to eq(%w[1 2 3 4 5])
    end
  end

  describe ".find" do
    it "finds by key" do
      expect(described_class.find(:cursor).name).to eq("Cursor")
    end

    it "finds by string key" do
      expect(described_class.find("cursor").key).to eq(:cursor)
    end

    it "returns nil for a key it does not know" do
      expect(described_class.find(:emacs)).to be_nil
    end
  end

  describe ".find_by_number" do
    it "finds the tool a prompt answer names" do
      expect(described_class.find_by_number("3").key).to eq(:copilot)
    end

    it "returns nil for a number outside the menu" do
      expect(described_class.find_by_number("9")).to be_nil
    end
  end

  # Golden: these are what the generator and the exe printed and cleaned up
  # before the tables moved here. Byte for byte, or the swap is not safe.
  describe "identity, against what the tables held" do
    GOLDEN = {
      claude: {
        name: "Claude Code",
        files: "CLAUDE.md + .claude/rules/",
        context_paths: %w[CLAUDE.md .claude/rules],
        mcp_config: { path: ".mcp.json", root_key: "mcpServers", format: :mcp_json },
        legacy_paths: [ ".claude/rules/rails-ui-patterns.md", ".claude/rules/rails-accessibility.md" ]
      },
      cursor: {
        name: "Cursor",
        files: ".cursor/rules/ + .cursorrules (legacy fallback)",
        context_paths: %w[.cursor/rules .cursorrules],
        mcp_config: { path: ".cursor/mcp.json", root_key: "mcpServers", format: :mcp_json },
        legacy_paths: [ ".cursor/rules/rails-ui-patterns.mdc" ]
      },
      copilot: {
        name: "GitHub Copilot",
        files: ".github/copilot-instructions.md + .github/instructions/",
        context_paths: %w[.github/copilot-instructions.md .github/instructions],
        mcp_config: { path: ".vscode/mcp.json", root_key: "servers", format: :vscode_json },
        legacy_paths: [ ".github/instructions/rails-ui-patterns.instructions.md" ]
      },
      opencode: {
        name: "OpenCode",
        files: "AGENTS.md",
        context_paths: %w[AGENTS.md app/models/AGENTS.md app/controllers/AGENTS.md],
        mcp_config: { path: "opencode.json", root_key: "mcp", format: :opencode_json },
        legacy_paths: []
      },
      codex: {
        name: "Codex CLI",
        files: "AGENTS.md + .codex/config.toml",
        context_paths: %w[AGENTS.md app/models/AGENTS.md app/controllers/AGENTS.md],
        mcp_config: { path: ".codex/config.toml", root_key: nil, format: :codex_toml },
        legacy_paths: []
      }
    }.freeze

    GOLDEN.each do |key, expected|
      describe key do
        let(:tool) { RailsAiContext::Install::AiTool.find(key) }

        it "keeps its name" do
          expect(tool.name).to eq(expected[:name])
        end

        it "keeps the files line the prompt printed" do
          expect(tool.files).to eq(expected[:files])
        end

        it "keeps the context files cleanup removes" do
          expect(tool.context_paths).to eq(expected[:context_paths])
        end

        it "keeps its MCP config shape" do
          expect(tool.mcp_config).to eq(expected[:mcp_config])
        end

        it "keeps its legacy leftovers" do
          expect(tool.legacy_paths).to eq(expected[:legacy_paths])
        end
      end
    end
  end

  # The tables that used to live in four places are now views onto this one.
  # The golden values above are the pin; these only prove the wiring.
  describe "the views its consumers read" do
    it "feeds the generator's prompt table" do
      expect(RailsAiContext::Generators::InstallGenerator::AI_TOOLS.keys).to eq(%w[1 2 3 4 5])
      expect(RailsAiContext::Generators::InstallGenerator::AI_TOOLS["2"])
        .to eq(key: :cursor, name: "Cursor", files: ".cursor/rules/ + .cursorrules (legacy fallback)", format: :cursor)
    end

    it "feeds the MCP config table" do
      expect(RailsAiContext::McpConfigGenerator::TOOL_CONFIGS)
        .to eq(described_class.mcp_configs_by_key)
    end

    it "feeds the legacy cleanup list" do
      expect(RailsAiContext::LegacyCleanup::LEGACY_FILES).to eq(described_class.legacy_files)
    end
  end
end
