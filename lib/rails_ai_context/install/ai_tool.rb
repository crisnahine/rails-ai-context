# frozen_string_literal: true

module RailsAiContext
  module Install
    # What each AI tool means to this gem, in one table: what to call it, what
    # context files it gets, where its MCP config lives and in what shape, and
    # what it left behind in older releases. The generator, the rake task and
    # the standalone CLI all asked these questions separately and answered
    # them from copies that drifted.
    #
    # Vocabulary per CONTEXT.md: "AI tool" for the assistant, "context files"
    # for what the gem generates for it.
    AiTool = Struct.new(:number, :key, :name, :files, :context_paths, :mcp_config, :legacy_paths,
                        keyword_init: true)

    class AiTool
      ALL = [
        new(
          number: "1", key: :claude, name: "Claude Code",
          files: "CLAUDE.md + .claude/rules/",
          context_paths: %w[CLAUDE.md .claude/rules],
          mcp_config: { path: ".mcp.json", root_key: "mcpServers", format: :mcp_json },
          legacy_paths: [ ".claude/rules/rails-ui-patterns.md", ".claude/rules/rails-accessibility.md" ]
        ),
        new(
          number: "2", key: :cursor, name: "Cursor",
          files: ".cursor/rules/ + .cursorrules (legacy fallback)",
          context_paths: %w[.cursor/rules .cursorrules],
          mcp_config: { path: ".cursor/mcp.json", root_key: "mcpServers", format: :mcp_json },
          legacy_paths: [ ".cursor/rules/rails-ui-patterns.mdc" ]
        ),
        new(
          number: "3", key: :copilot, name: "GitHub Copilot",
          files: ".github/copilot-instructions.md + .github/instructions/",
          context_paths: %w[.github/copilot-instructions.md .github/instructions],
          mcp_config: { path: ".vscode/mcp.json", root_key: "servers", format: :vscode_json },
          legacy_paths: [ ".github/instructions/rails-ui-patterns.instructions.md" ]
        ),
        new(
          number: "4", key: :opencode, name: "OpenCode",
          files: "AGENTS.md",
          context_paths: %w[AGENTS.md app/models/AGENTS.md app/controllers/AGENTS.md],
          mcp_config: { path: "opencode.json", root_key: "mcp", format: :opencode_json },
          legacy_paths: []
        ),
        new(
          number: "5", key: :codex, name: "Codex CLI",
          files: "AGENTS.md + .codex/config.toml",
          context_paths: %w[AGENTS.md app/models/AGENTS.md app/controllers/AGENTS.md],
          mcp_config: { path: ".codex/config.toml", root_key: nil, format: :codex_toml },
          legacy_paths: []
        )
      ].freeze

      class << self
        def all
          ALL
        end

        def find(key)
          key = key.to_sym if key.respond_to?(:to_sym)
          ALL.find { |tool| tool.key == key }
        end

        def mcp_configs_by_key
          ALL.to_h { |tool| [ tool.key, tool.mcp_config ] }
        end

        def legacy_files
          ALL.flat_map { |tool| tool.legacy_paths.map { |path| { path: path, ai_tool: tool.key } } }
        end
      end
    end
  end
end
