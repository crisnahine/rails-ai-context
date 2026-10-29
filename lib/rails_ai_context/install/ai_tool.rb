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
    #
    # context_paths lists the root file first, then the split-rule targets. The writers,
    # doctor and cleanup all read this table, so a moved path changes every surface at once.
    #
    # rule_files names what the gem writes inside rules_dir. The directory is shared with
    # rules the user writes by hand, so cleanup removes these names and nothing else.
    #
    # mcp_config[:folder_variable] is how the tool's config names the folder it sits in, where
    # it has a name for it: a workspace entry's app path starts from that name. The others get
    # a bare relative path, which they resolve against the folder they were started in.
    #
    # next_step is what the user does in the tool before it starts a project's MCP server: each
    # tool holds one back behind its own approval or trust step.
    #
    # retired_paths are files an earlier release wrote a block into and this one
    # no longer writes: a run takes the block out, and cleanup still knows them.
    #
    # root is the file the tool's root context goes in when no other file it reads carries
    # it, and reads the root files it loads at the start of every session on every surface
    # it has, by default, each with the doc saying so: Serializers::LoadPlan writes the
    # content once into a file every chosen tool reads. A tool that expands `@path` imports
    # in a file can be pointed at the content instead of given a copy.
    #
    # mcp_config[:client] is the program that reads the config, and [:jsonc] whether it reads
    # JSONC - comments and trailing commas - or refuses them, as JSON does. VS Code reads
    # .vscode/mcp.json as a standalone configuration file, with its JSONC parser and trailing
    # commas allowed; OpenCode reads opencode.json with jsonc-parser, trailing commas allowed.
    # Claude Code reads .mcp.json with JSON.parse. Cursor's is held to JSON as well, the form
    # every reader takes: nothing shows its reader takes JSONC.
    AiTool = Struct.new(:number, :key, :name, :files, :context_paths, :rules_dir, :rule_files, :mcp_config,
                        :legacy_paths, :owned_dir, :next_step, :root, :reads, :retired_paths, keyword_init: true)

    class AiTool
      Read = Data.define(:path, :imports, :source)

      AGENTS_MD_SOURCE = "https://cursor.com/help/customization/rules#how-does-claudemd-work-in-cursor"
      ALL = [
        new(
          number: "1", key: :claude, name: "Claude Code",
          files: "CLAUDE.md + .claude/rules/",
          context_paths: %w[CLAUDE.md .claude/rules],
          rules_dir: ".claude/rules",
          rule_files: %w[rails-context.md rails-schema.md rails-models.md rails-mcp-tools.md rails-components.md],
          mcp_config: { path: ".mcp.json", root_key: "mcpServers", format: :mcp_json, client: "Claude Code", jsonc: false },
          next_step: "start a new Claude Code session in this folder and approve each rails-ai-context server when it asks; /mcp lists them",
          legacy_paths: [ ".claude/rules/rails-ui-patterns.md", ".claude/rules/rails-accessibility.md" ],
          owned_dir: ".claude",
          root: "CLAUDE.md",
          # A root CLAUDE.md is read in place of AGENTS.md, and expands its imports at launch.
          reads: [ Read.new(path: "CLAUDE.md", imports: true, source: "https://code.claude.com/docs/en/memory#import-additional-files") ]
        ),
        new(
          number: "2", key: :cursor, name: "Cursor",
          files: "AGENTS.md + .cursor/rules/",
          context_paths: %w[AGENTS.md .cursor/rules],
          retired_paths: %w[.cursorrules],
          rules_dir: ".cursor/rules",
          rule_files: %w[rails-project.mdc rails-models.mdc rails-controllers.mdc rails-mcp-tools.mdc],
          mcp_config: { path: ".cursor/mcp.json", root_key: "mcpServers", format: :mcp_json,
                        folder_variable: "${workspaceFolder}", client: "Cursor", jsonc: false },
          next_step: "restart Cursor, then turn rails-ai-context on under MCP in Customize if it is off; the MCP Logs output panel shows it starting",
          legacy_paths: [ ".cursor/rules/rails-ui-patterns.mdc" ],
          owned_dir: ".cursor",
          root: "AGENTS.md",
          # .cursorrules is legacy, and an @path in a rule is a pointer the agent
          # reads, never inlined. A release that put the content in .mdc rules alone
          # had a chat agent miss it, so the content goes in AGENTS.md.
          reads: [
            Read.new(path: "AGENTS.md", imports: false, source: AGENTS_MD_SOURCE),
            Read.new(path: "CLAUDE.md", imports: false, source: AGENTS_MD_SOURCE)
          ]
        ),
        new(
          number: "3", key: :copilot, name: "GitHub Copilot",
          files: ".github/copilot-instructions.md + .github/instructions/",
          context_paths: %w[.github/copilot-instructions.md .github/instructions],
          rules_dir: ".github/instructions",
          rule_files: %w[
            rails-context.instructions.md rails-models.instructions.md
            rails-controllers.instructions.md rails-mcp-tools.instructions.md
          ],
          mcp_config: { path: ".vscode/mcp.json", root_key: "servers", format: :vscode_json,
                        folder_variable: "${workspaceFolder}", client: "VS Code", jsonc: true },
          next_step: "open this folder in VS Code as a trusted workspace and send a Copilot Chat message; MCP: List Servers in the Command Palette shows rails-ai-context",
          legacy_paths: [ ".github/instructions/rails-ui-patterns.instructions.md" ],
          root: ".github/copilot-instructions.md",
          # github.com chat, Visual Studio, JetBrains, Xcode and code review read this one
          # alone; AGENTS.md and CLAUDE.md reach only the CLI, VS Code and the cloud agent.
          reads: [
            Read.new(path: ".github/copilot-instructions.md", imports: false,
                     source: "https://docs.github.com/en/copilot/reference/custom-instructions-support")
          ]
        ),
        new(
          number: "4", key: :opencode, name: "OpenCode",
          files: "AGENTS.md",
          context_paths: %w[AGENTS.md app/models/AGENTS.md app/controllers/AGENTS.md],
          mcp_config: { path: "opencode.json", root_key: "mcp", format: :opencode_json, client: "OpenCode", jsonc: true,
                        env_key: "environment" },
          next_step: "restart OpenCode in this folder; opencode mcp list shows rails-ai-context",
          legacy_paths: [],
          root: "AGENTS.md",
          # CLAUDE.md is read only where there is no AGENTS.md.
          reads: [ Read.new(path: "AGENTS.md", imports: false, source: "https://opencode.ai/docs/rules/#precedence") ]
        ),
        new(
          number: "5", key: :codex, name: "Codex CLI",
          files: "AGENTS.md + .codex/config.toml",
          context_paths: %w[AGENTS.md app/models/AGENTS.md app/controllers/AGENTS.md],
          mcp_config: { path: ".codex/config.toml", root_key: nil, format: :codex_toml, client: "Codex CLI" },
          next_step: "trust this folder when Codex CLI asks (it skips the project config of an untrusted one), then start a new codex session here; /mcp lists rails-ai-context",
          legacy_paths: [],
          owned_dir: ".codex",
          root: "AGENTS.md",
          reads: [ Read.new(path: "AGENTS.md", imports: false, source: "https://learn.chatgpt.com/docs/agent-configuration/agents-md") ]
        )
      ].freeze

      # Every path the gem writes or once wrote for the tool, as cleanup and
      # doctor read them.
      def owned_paths
        context_paths + Array(retired_paths)
      end

      # What a summary lists for the tool. `files` names Codex CLI's MCP
      # config beside its context files, and a CLI-mode or per-app summary
      # writes no MCP config, so it leaves that part out.
      def files_label(mcp: true)
        mcp ? files : context_files
      end

      class << self
        def all
          ALL
        end

        def keys
          ALL.map(&:key)
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

      # What `rails ai:context:<key>` writes for the tool: its files without
      # its MCP config, which only the install writes.
      def context_files
        files.split(" + ").reject { |file| file == mcp_config[:path] }.join(" + ")
      end
    end
  end
end
