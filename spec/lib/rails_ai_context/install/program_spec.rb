# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"

RSpec.describe RailsAiContext::Install::Program do
  let(:surface_class) do
    Class.new do
      attr_reader :lines

      def initialize(*answers)
        @answers = answers
        @lines = []
      end

      def say(text = "", level = :plain)
        @lines << [ level, text ]
      end

      def ask(_prompt)
        @answers.shift
      end

      def text
        @lines.map(&:last).join("\n")
      end
    end
  end

  # The reason a config was left as it is goes where the install speaks,
  # not to a Rails log the person running it never reads.
  describe ".write_mcp_configs" do
    it "says why a config was left as it is, and what to add by hand" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, ".vscode"))
        File.write(File.join(root, ".vscode/mcp.json"), %({\n  // mine\n  "servers": {}\n}\n))
        surface = surface_class.new
        allow(RailsAiContext).to receive(:log_warn)

        described_class.write_mcp_configs(surface, tools: %i[copilot], tool_mode: :mcp, root: root, standalone: true)

        expect(surface.lines).to include(
          [ :warn, "Could not write .vscode/mcp.json - that tool will not auto-discover the MCP server" ],
          [ :warn, a_string_including("holds comments", "Add {\"servers\":{\"rails-ai-context\"") ]
        )
        expect(RailsAiContext).not_to have_received(:log_warn)
      end
    end
  end

  # A committed plugin setting starts Claude Code's server for everyone who
  # opens the app, and one in .mcp.json would list every tool twice.
  describe ".write_mcp_configs, where the app's committed settings turn the Claude Code plugin on" do
    def commit_plugin(root, **more)
      FileUtils.mkdir_p(File.join(root, ".claude"))
      File.write(File.join(root, ".claude", "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }, **more))
    end

    # Where Claude Code never ran, as on CI, the committed setting is the whole setup.
    def never_ran
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(File.join(Dir.tmpdir, "rails-ai-context-never-ran"))
    end

    def rails_app(root)
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config", "application.rb"), "")
      File.realpath(root)
    end

    def user_plugin
      config = ENV.fetch("CLAUDE_CONFIG_DIR")
      FileUtils.mkdir_p(File.join(config, "plugins"))
      File.write(File.join(config, "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
      File.write(File.join(config, "plugins", "installed_plugins.json"),
                 JSON.generate("version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user" } ] }))
    end

    after do
      config = ENV.fetch("CLAUDE_CONFIG_DIR")
      FileUtils.rm_rf([ File.join(config, "plugins"), File.join(config, "settings.json"), File.dirname(RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS) ])
    end

    it "writes the other tools' configs and no .mcp.json server, and says why" do
      never_ran
      Dir.mktmpdir do |root|
        commit_plugin(root)
        surface = surface_class.new

        written = described_class.write_mcp_configs(surface, tools: %i[claude cursor], tool_mode: :mcp, root: root, standalone: true)

        expect(written[:plugin_off]).to be(false)
        expect(File.exist?(File.join(root, ".mcp.json"))).to be(false)
        expect(File.exist?(File.join(root, ".cursor", "mcp.json"))).to be(true)
        expect(surface.text).to include("Claude Code: no server written into .mcp.json here: the rails-ai-context plugin serves this app, " \
                                        "as .claude/settings.json says; doctor names anything missing")
      end
    end

    # The entry is the team's to remove; the install never deletes one.
    it "keeps a server .mcp.json already holds, and says it runs beside the plugin" do
      never_ran
      Dir.mktmpdir do |root|
        commit_plugin(root)
        File.write(File.join(root, ".mcp.json"), JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        surface = surface_class.new

        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)

        expect(JSON.parse(File.read(File.join(root, ".mcp.json")))["mcpServers"].keys).to eq(%w[rails-ai-context])
        expect(surface.text).to include("still holds `rails-ai-context`, which runs beside it: remove it from .mcp.json")
      end
    end

    # Off for this user, the plugin leaves .mcp.json's server to serve them, which turning it back on would double.
    it "says .mcp.json's server serves a user who turned the committed plugin off, under any name" do
      Dir.mktmpdir do |root|
        commit_plugin(root)
        File.write(File.join(root, ".claude", "settings.local.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => false }))
        File.write(File.join(root, ".mcp.json"), JSON.generate("mcpServers" => { "rac-x" => { "command" => "bundle", "args" => %w[exec rails-ai-context serve] } }))
        surface = surface_class.new

        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)

        expect(surface.text).to include("your .claude/settings.local.json turns it off for you, so .mcp.json's `rac-x` serves you")
        expect(surface.text).not_to include("plugin enable")
      end
    end

    # In a repository's subfolder, the local file that wins is the repository's.
    it "names the local file that turns the committed plugin off where it is" do
      skip "Claude Code keeps each folder's local settings apart on Windows" if Gem.win_platform?

      Dir.mktmpdir do |repo|
        root = File.join(repo, "shop")
        FileUtils.mkdir_p([ File.join(repo, ".git"), File.join(repo, ".claude") ])
        commit_plugin(root)
        File.write(File.join(repo, ".claude", "settings.local.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => false }))
        surface = surface_class.new

        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)

        expect(surface.text).to include("your ../.claude/settings.local.json turns it off: `claude plugin enable")
      end
    end

    # A teammate's local install turns the committed plugin on twice over, and turns nothing off.
    it "says the plugin serves a folder of one app where its local settings turn it on too" do
      never_ran
      Dir.mktmpdir do |root|
        commit_plugin(root)
        File.write(File.join(root, ".claude", "settings.local.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
        server = RailsAiContext::McpConfigGenerator::Server.new(name: "rails-ai-context-a", standalone: true, app_path: "a")
        surface = surface_class.new

        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, servers: [ server ])

        expect(surface.text).to include("the rails-ai-context plugin serves this app, as .claude/settings.json says")
      end
    end

    # Local settings win over the committed file, and the install still leaves .mcp.json to the team.
    it "names the local setting that turns the committed plugin off" do
      Dir.mktmpdir do |root|
        commit_plugin(root)
        File.write(File.join(root, ".claude", "settings.local.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => false }))
        surface = surface_class.new

        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)

        expect(File.exist?(File.join(root, ".mcp.json"))).to be(false)
        expect(surface.text).to include("your .claude/settings.local.json turns it off: " \
                                        "`claude plugin enable rails-ai-context@rails-ai-context --scope local` turns it back on")
      end
    end

    # The .mcp.json server is the team's: a teammate who has not turned it off starts it beside the plugin.
    it "says a .mcp.json server this user's settings turn off still runs beside the plugin for teammates" do
      Dir.mktmpdir do |dir|
        root = rails_app(dir)
        user_plugin
        commit_plugin(root)
        File.write(File.join(root, ".mcp.json"), JSON.generate("mcpServers" => { "rails" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        File.write(File.join(root, ".claude", "settings.local.json"), JSON.generate("disabledMcpjsonServers" => [ "rails" ]))
        surface = surface_class.new

        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)
        expect(surface.text).to include("and .mcp.json still holds `rails`, which your settings turn off, but teammates' sessions start it " \
                                        "beside the plugin: remove it from .mcp.json")

        FileUtils.rm_f(File.join(root, ".claude", "settings.local.json"))
        commit_plugin(root, "disabledMcpjsonServers" => [ "rails" ])
        surface = surface_class.new
        expect(described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)[:plugin_off]).to be(false)
        expect(surface.text).to include("the rails-ai-context plugin serves this app, as .claude/settings.json says; doctor names anything missing")
      end
    end

    it "says the committed plugin does not start for a user who has Claude Code but never installed it" do
      Dir.mktmpdir do |dir|
        root = rails_app(dir)
        commit_plugin(root)
        surface = surface_class.new

        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)

        expect(surface.text).to include("Claude Code: no server written into .mcp.json here: the app's .claude/settings.json turns the " \
                                        "rails-ai-context plugin on, but it does not start for you here: doctor names why")
      end
    end

    # The file that turns the plugin on is the folder's, not the app's below it.
    it "names a workspace folder's settings as this folder's" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        rails_app(File.join(root, "shop"))
        commit_plugin(root)
        server = RailsAiContext::McpConfigGenerator::Server.new(name: "rails-ai-context-shop", standalone: true, app_path: "shop")
        surface = surface_class.new

        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, servers: [ server ])

        expect(surface.text).to include("Claude Code: no server written into .mcp.json here: .claude/settings.json in this folder turns the " \
                                        "rails-ai-context plugin on, but it does not start for you here: doctor names why")
      end
    end

    # Typed from the folder above, every file is named from there, as is where a session runs the plugin.
    it "names each file and the session folder from where init was typed" do
      never_ran
      Dir.mktmpdir do |dir|
        root = rails_app(dir)
        commit_plugin(root)
        File.write(File.join(root, ".mcp.json"), JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        surface = surface_class.new
        surface.define_singleton_method(:place) { "shop" }

        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)

        expect(surface.text).to include("Claude Code: no server written into shop/.mcp.json: the rails-ai-context plugin serves this app for " \
                                        "sessions started in shop, as shop/.claude/settings.json says, and shop/.mcp.json still holds " \
                                        "`rails-ai-context`, which runs beside it: remove it from shop/.mcp.json")
      end
    end

    # No local setting turns back on what managed settings turn off.
    it "asks whoever manages the settings where they turn the committed plugin off" do
      Dir.mktmpdir do |dir|
        root = rails_app(dir)
        user_plugin
        commit_plugin(root)
        managed = RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS
        FileUtils.mkdir_p(File.dirname(managed))
        File.write(managed, JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => false }))
        surface = surface_class.new

        expect(described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)[:plugin_off]).to be(true)
        expect(surface.text).to include("turns the rails-ai-context plugin on, and managed settings turn it off: ask whoever manages your " \
                                        "Claude Code settings to turn it on")

        File.write(File.join(root, ".mcp.json"), JSON.generate("mcpServers" => { "rails" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        surface = surface_class.new
        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)
        expect(surface.text).to include("and managed settings turn it off for you, so .mcp.json's `rails` serves you")
      end
    end

    # managed-mcp.json starts its own servers alone, the plugin's never.
    it "names managed-mcp.json's server of the gem's where that file decides" do
      Dir.mktmpdir do |dir|
        root = rails_app(dir)
        user_plugin
        commit_plugin(root)
        managed_mcp = File.join(File.dirname(RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS), "managed-mcp.json")
        FileUtils.mkdir_p(File.dirname(managed_mcp))
        File.write(managed_mcp, JSON.generate("mcpServers" => { "rails" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        surface = surface_class.new

        expect(described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)[:plugin_off]).to be(true)
        expect(surface.text).to include("but managed-mcp.json decides which servers start, and its `rails` serves this app")

        File.write(managed_mcp, JSON.generate("mcpServers" => {}))
        surface = surface_class.new
        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)
        expect(surface.text).to include("and none of them serves this app: ask whoever manages your Claude Code settings to add one")
      end
    end

    # Managed files and local settings hold where Claude Code never ran, so the summary must not name the plugin.
    it "says the plugin is off where a managed file or a local setting keeps it off, Claude Code run or not" do
      never_ran
      Dir.mktmpdir do |dir|
        root = rails_app(dir)
        commit_plugin(root)
        written = -> { described_class.write_mcp_configs(surface_class.new, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true) }
        managed = RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS
        FileUtils.mkdir_p(File.dirname(managed))

        File.write(File.join(root, ".claude", "settings.local.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => false }))
        expect(written.()[:plugin_off]).to be(true)

        FileUtils.rm_f(File.join(root, ".claude", "settings.local.json"))
        File.write(File.join(File.dirname(managed), "managed-mcp.json"), JSON.generate("mcpServers" => {}))
        expect(written.()[:plugin_off]).to be(true)
      end
    end

    # The plugin serves a folder holding one app, and fails to start in a folder of several.
    it "writes a workspace's servers only where the folder holds several apps, and says the plugin fails there" do
      skip "Claude Code keeps each folder's local settings apart on Windows" if Gem.win_platform?

      Dir.mktmpdir do |root|
        commit_plugin(root)
        server = ->(app) { RailsAiContext::McpConfigGenerator::Server.new(name: "rails-ai-context-#{app}", standalone: true, app_path: app) }

        described_class.write_mcp_configs(surface_class.new, tools: %i[claude], tool_mode: :mcp, root: root, servers: [ server.("a") ])
        expect(File.exist?(File.join(root, ".mcp.json"))).to be(false)

        surface = surface_class.new
        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, servers: [ server.("a"), server.("b") ])
        expect(File.exist?(File.join(root, ".mcp.json"))).to be(true)
        expect(surface.text).to include("Claude Code: .claude/settings.json turns on the rails-ai-context plugin, which serves one app, not a folder " \
                                        "of them, so it has nothing to serve here: `claude plugin disable rails-ai-context@rails-ai-context " \
                                        "--scope project` turns it off for this folder")

        # Outside a repository the folder's local file is its own, which a local disable turns off.
        File.write(File.join(root, ".claude", "settings.local.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
        surface = surface_class.new
        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, servers: [ server.("a"), server.("b") ])
        expect(surface.text).to include("so it has nothing to serve here: `claude plugin disable rails-ai-context@rails-ai-context --scope local` " \
                                        "turns it off for this folder")

        # A project disable cannot turn off what the repository's local settings turn on.
        FileUtils.mkdir_p(File.join(root, ".git"))
        surface = surface_class.new
        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, servers: [ server.("a"), server.("b") ])
        expect(surface.text).to include("your local settings turn it on for the apps below as well, so start Claude Code in one of them")
      end
    end
  end

  describe ".write_mcp_configs, with an entry of the user's under the gem's name" do
    it "says it kept the user's entry" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, ".mcp.json"), %({"mcpServers": {"rails-ai-context": {"url": "http://localhost:3000/mcp"}}}))
        surface = surface_class.new

        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)

        expect(surface.lines).to include([ :muted, ".mcp.json (unchanged)" ],
                                         [ :muted, a_string_including(".mcp.json: kept rails-ai-context") ])
      end
    end
  end

  describe ".select_ai_tools" do
    it "parses numbers into tool keys and shows every tool with its files" do
      surface = surface_class.new("1,3")

      expect(described_class.select_ai_tools(surface)).to eq(%i[claude copilot])
      expect(surface.text).to include("Which AI tools do you use?")
      expect(surface.text).to include("-> CLAUDE.md + .claude/rules/")
      expect(surface.text).to include("Selected: Claude Code, GitHub Copilot")
    end

    it "answers every tool on 'a'" do
      surface = surface_class.new("a")

      expect(described_class.select_ai_tools(surface))
        .to eq(RailsAiContext::Install::AiTool.all.map(&:key))
    end

    # An empty answer is the default the prompt has always had, and
    # `--defaults` answers every prompt that way: "No tools selected" over
    # a run that selected all five read like an error.
    it "selects every tool on an empty answer and on EOF, saying which and nothing else" do
      [ "", nil ].each do |answer|
        surface = surface_class.new(answer)

        expect(described_class.select_ai_tools(surface))
          .to eq(RailsAiContext::Install::AiTool.all.map(&:key))
        expect(surface.text).to end_with("\nSelected: Claude Code, Cursor, GitHub Copilot, OpenCode, Codex CLI")
        expect(surface.text).not_to include("No tools selected")
      end
    end

    it "says so when the answer names no tool, and selects every one" do
      surface = surface_class.new("9,zebra")

      expect(described_class.select_ai_tools(surface))
        .to eq(RailsAiContext::Install::AiTool.all.map(&:key))
      expect(surface.text).to include(%("9,zebra" names no tool - selecting all.))
    end

    # A re-run asks the same question with no hint of the answer it gave
    # last time.
    it "shows the current selection above the question" do
      surface = surface_class.new("1")

      described_class.select_ai_tools(surface, current: %i[claude copilot])

      expect(surface.text).to include("Currently selected: 1,3 (Claude Code, GitHub Copilot)")
    end

    it "shows no current selection on a first run" do
      surface = surface_class.new("1")

      described_class.select_ai_tools(surface, current: nil)

      expect(surface.text).not_to include("Currently selected")
    end
  end

  # A third answer, with 1 and 2 keeping the meaning they have always had so
  # anything piping input into the installer still works.
  describe ".select_setup" do
    it "answers the three shapes an install can take" do
      expect(described_class.select_setup(surface_class.new("1")).to_a).to eq([ :mcp, true ])
      expect(described_class.select_setup(surface_class.new("2")).to_a).to eq([ :cli, true ])
      expect(described_class.select_setup(surface_class.new("3")).to_a).to eq([ :mcp, false ])
    end

    it "treats an empty answer and EOF as the default" do
      expect(described_class.select_setup(surface_class.new("")).to_a).to eq([ :mcp, true ])
      expect(described_class.select_setup(surface_class.new(nil)).to_a).to eq([ :mcp, true ])
    end

    it "confirms each answer in the words the question offered it" do
      { "1" => "Selected: MCP config + context files",
        "2" => "Selected: Context files only (CLI mode, no MCP server)",
        "3" => "Selected: MCP config only (writes no CLAUDE.md, AGENTS.md or rules files)" }.each do |answer, line|
        surface = surface_class.new(answer)
        described_class.select_setup(surface)
        expect(surface.text).to include("  #{answer}. ")
        expect(surface.text).to end_with("\n#{line}")
      end
    end
  end

  describe ".cleanup_removed_tools" do
    it "asks nothing when the selection did not shrink" do
      surface = surface_class.new
      described_class.cleanup_removed_tools(surface, previous: %i[claude], selected: %i[claude cursor], root: ".")
      expect(surface.lines).to be_empty
    end

    it "keeps everything on the default answer" do
      expect(RailsAiContext::Install::Cleanup).not_to receive(:remove)

      surface = surface_class.new("n")
      described_class.cleanup_removed_tools(surface, previous: %i[claude cursor], selected: %i[claude], root: ".")
      expect(surface.text).to include("These AI tools were removed from your selection:")
    end

    # The CLI surface prefixes every :warn line with "Warning: ", so a line
    # reporting a successful removal must not carry that level.
    it "reports a removal at a level that is not a warning" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, ".cursorrules"), "<!-- BEGIN rails-ai-context -->\nx\n<!-- END rails-ai-context -->\n")

        surface = surface_class.new("y")
        described_class.cleanup_removed_tools(surface, previous: %i[claude cursor], selected: %i[claude], root: root)

        removal = surface.lines.select { |(_, text)| text.include?("Removed") }
        expect(removal).not_to be_empty
        expect(removal.map(&:first)).to all(eq(:ok))
      end
    end

    it "says so when it kept the user's own lines in a file" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, ".cursorrules"), "mine\n<!-- BEGIN rails-ai-context -->\nx\n<!-- END rails-ai-context -->\n")

        surface = surface_class.new("y")
        described_class.cleanup_removed_tools(surface, previous: %i[claude cursor], selected: %i[claude], root: root)

        expect(surface.text).to include("Removed the generated section from .cursorrules")
        expect(File.read(File.join(root, ".cursorrules"))).to eq("mine\n")
      end
    end

    it "says a file was kept, and claims no removal, when nothing in it was generated" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, ".cursorrules"), "my own rules\n")

        surface = surface_class.new("y")
        described_class.cleanup_removed_tools(surface, previous: %i[claude cursor], selected: %i[claude], root: root)

        expect(surface.text).to include("Kept .cursorrules")
        expect(surface.text).not_to include("Cursor files removed")
        expect(File.read(File.join(root, ".cursorrules"))).to eq("my own rules\n")
      end
    end

    # A workspace keeps the context files in each app and the MCP entries in
    # itself; a dropped tool's go from both, named from the workspace.
    it "cleans each app's files and the workspace's MCP entries" do
      Dir.mktmpdir do |root|
        %w[a b].each do |app|
          FileUtils.mkdir_p(File.join(root, app))
          File.write(File.join(root, app, ".cursorrules"), "<!-- BEGIN rails-ai-context -->\nx\n<!-- END rails-ai-context -->\n")
        end
        FileUtils.mkdir_p(File.join(root, ".cursor"))
        File.write(File.join(root, ".cursor/mcp.json"), JSON.generate("mcpServers" => {
          "rails-ai-context-a" => { "command" => "rails-ai-context", "args" => %w[serve --app-path a] }, "mine" => {}
        }))
        FileUtils.mkdir_p(File.join(root, "a/.cursor"))
        File.write(File.join(root, "a/.cursor/mcp.json"),
                   JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))

        surface = surface_class.new("y")
        described_class.cleanup_removed_tools(surface, previous: %i[claude cursor], selected: %i[claude], root: root,
                                                       app_roots: [ File.join(root, "a"), File.join(root, "b") ])

        expect(surface.text).to include("Removed a/.cursorrules", "Removed b/.cursorrules")
        expect(surface.text).to include("Removed rails-ai-context from .cursor/mcp.json",
                                        "Removed a/.cursor/mcp.json (rails-ai-context was its only server)",
                                        "Removed a/.cursor/")
        expect(JSON.parse(File.read(File.join(root, ".cursor/mcp.json")))["mcpServers"].keys).to eq(%w[mine])
        expect(File.exist?(File.join(root, "a/.cursor"))).to be(false)
      end
    end

    # "Removed MCP entry" over a file that was deleted whole read like a bug.
    it "names a config it deleted whole as removed, and keeps a directory that holds anything else" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, ".codex"))
        File.write(File.join(root, ".codex/config.toml"), %([mcp_servers.rails-ai-context]\ncommand = "rails-ai-context"\nargs = ["serve"]\n))
        FileUtils.mkdir_p(File.join(root, ".vscode"))
        File.write(File.join(root, ".vscode/mcp.json"),
                   JSON.generate("servers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        File.write(File.join(root, ".vscode/settings.json"), "{}\n")

        surface = surface_class.new("y")
        described_class.cleanup_removed_tools(surface, previous: %i[claude copilot codex], selected: %i[claude], root: root)

        expect(surface.text).to include("Removed .codex/config.toml (rails-ai-context was its only server)", "Removed .codex/",
                                        "Removed .vscode/mcp.json (rails-ai-context was its only server)")
        expect(surface.text).not_to include("Removed .vscode/\n")
        expect(Dir.exist?(File.join(root, ".codex"))).to be(false)
        expect(File.exist?(File.join(root, ".vscode/settings.json"))).to be(true)
      end
    end

    # OpenCode's AGENTS.md is Codex CLI's too, so it stays when only one of
    # them is dropped - and saying nothing read as a cleanup that skipped
    # the tool.
    it "says which shared file it kept, and for which tool" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, "AGENTS.md"), "<!-- BEGIN rails-ai-context -->\nx\n<!-- END rails-ai-context -->\n")

        surface = surface_class.new("y")
        described_class.cleanup_removed_tools(surface, previous: %i[opencode codex], selected: %i[codex], root: root)

        expect(surface.text).to include("Kept AGENTS.md - Codex CLI uses it too")
        expect(surface.text).not_to include("OpenCode files removed")
        expect(File.exist?(File.join(root, "AGENTS.md"))).to be(true)
      end
    end

    # Both dropped, and only OpenCode's files asked to go: Codex CLI's stay,
    # AGENTS.md among them, which went with OpenCode's.
    it "keeps a shared file for a dropped tool whose files the answer kept" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, "AGENTS.md"), "<!-- BEGIN rails-ai-context -->\nx\n<!-- END rails-ai-context -->\n")
        File.write(File.join(root, "opencode.json"),
                   JSON.generate("mcp" => { "rails-ai-context" => { "type" => "local", "command" => %w[rails-ai-context serve] } }))

        surface = surface_class.new("1")
        described_class.cleanup_removed_tools(surface, previous: %i[claude opencode codex], selected: %i[claude], root: root)

        expect(File.exist?(File.join(root, "AGENTS.md"))).to be(true)
        expect(File.exist?(File.join(root, "opencode.json"))).to be(false)
        expect(surface.text).to include("Kept AGENTS.md - Codex CLI uses it too")
      end
    end

    it "says which config it left as it is, named from where it was run" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "a/.cursor"))
        File.write(File.join(root, "a/.cursor/mcp.json"),
                   %({\n  // ours\n  "mcpServers": { "rails-ai-context": { "command": "rails-ai-context", "args": ["serve"] } }\n}\n))
        surface = surface_class.new("y")

        described_class.cleanup_removed_tools(surface, previous: %i[claude cursor], selected: %i[claude], root: root,
                                                       app_roots: [ File.join(root, "a") ])

        expect(surface.lines).to include([ :warn, a_string_including("Could not update a/.cursor/mcp.json: Cursor cannot read it: it holds comments") ])
        expect(surface.text).not_to include("Cursor files removed")
      end
    end

    it "warns about a path it could not remove instead of claiming it went" do
      skip "root can remove anything" if Process.uid.zero?

      Dir.mktmpdir do |root|
        File.write(File.join(root, ".cursorrules"), "<!-- BEGIN rails-ai-context -->\nx\n<!-- END rails-ai-context -->\n")
        File.chmod(0o500, root)

        surface = surface_class.new("y")
        described_class.cleanup_removed_tools(surface, previous: %i[claude cursor], selected: %i[claude], root: root)

        expect(surface.lines).to include([ :warn, a_string_including("Could not remove .cursorrules") ])
        expect(surface.text).not_to include("Removed .cursorrules")
        expect(surface.text).not_to include("Cursor files removed")
      ensure
        File.chmod(0o700, root)
      end
    end
  end

  # CLI mode starts no server, so a config the gem left behind would go on
  # starting one; it is offered for removal like a dropped tool's files.
  describe ".ask_mcp_removal and .remove_mcp_entries" do
    it "offers the configs that start the gem's server, and removes only its entries on yes" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, ".mcp.json"), JSON.generate("mcpServers" => {
          "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] }, "mine" => { "command" => "x" }
        }))
        FileUtils.mkdir_p(File.join(root, ".cursor"))
        File.write(File.join(root, ".cursor/mcp.json"),
                   JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))

        surface = surface_class.new("y")
        tools = described_class.ask_mcp_removal(surface, root: root)
        described_class.remove_mcp_entries(surface, tools, root: root)

        expect(tools).to eq(%i[claude cursor])
        expect(surface.text).to include("CLI mode starts no MCP server", "  .mcp.json", "  .cursor/mcp.json")
        expect(surface.text).to include("Removed rails-ai-context from .mcp.json",
                                        "Removed .cursor/mcp.json (rails-ai-context was its only server)", "Removed .cursor/")
        expect(JSON.parse(File.read(File.join(root, ".mcp.json")))["mcpServers"].keys).to eq(%w[mine])
      end
    end

    it "keeps them on the default answer, and asks nothing when none is left" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, ".mcp.json"),
                   JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))

        expect(described_class.ask_mcp_removal(surface_class.new(""), root: root)).to eq([])
        expect(File.exist?(File.join(root, ".mcp.json"))).to be(true)

        File.delete(File.join(root, ".mcp.json"))
        quiet = surface_class.new
        expect(described_class.ask_mcp_removal(quiet, root: root)).to eq([])
        expect(quiet.lines).to be_empty
      end
    end
  end

  # Typed outside the app, `init --app-path shop` reported `.mcp.json`,
  # which reads as a file where the user stands.
  describe "paths, named from where the command was typed" do
    it "names each file from the surface's place" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, ".gitignore"), "log/\n")
        surface = surface_class.new
        surface.define_singleton_method(:place) { "shop" }

        described_class.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: root, standalone: true)
        described_class.mark_gitignore(surface, root: root)

        expect(surface.text).to include("Created/Updated shop/.mcp.json", "Updated shop/.gitignore")
      end
    end
  end

  describe ".own_config_tools" do
    # A workspace's config above serves the app already; a second config in
    # the app would start a second server for it.
    it "leaves out a tool a workspace's config serves, and keeps the rest" do
      Dir.mktmpdir do |workspace|
        app = File.join(workspace, "a")
        FileUtils.mkdir_p(app)
        File.write(File.join(workspace, ".mcp.json"), JSON.generate("mcpServers" => {
          "rails-ai-context-a" => { "command" => "rails-ai-context", "args" => %w[serve --app-path a] }
        }))

        expect(described_class.own_config_tools(%i[claude cursor], root: app)).to eq(%i[cursor])
      end
    end
  end

  describe ".mark_gitignore" do
    # A private setup lists the files in .git/info/exclude and keeps the
    # tracked .gitignore as it was; a re-run must not dirty it again.
    it "adds nothing for a path git already ignores elsewhere" do
      Dir.mktmpdir do |root|
        system("git", "init", "-q", root, out: File::NULL, err: File::NULL)
        File.write(File.join(root, ".gitignore"), "log/\n")
        File.write(File.join(root, ".git", "info", "exclude"), ".ai-context.json\n.codex/config.toml\n")

        surface = surface_class.new
        described_class.mark_gitignore(surface, root: root)

        expect(File.read(File.join(root, ".gitignore"))).to eq("log/\n")
        expect(surface.lines).to be_empty
      end
    end

    it "appends the two entries once and says nothing the second time" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, ".gitignore"), "log/\n")

        surface = surface_class.new
        described_class.mark_gitignore(surface, root: root)
        content = File.read(File.join(root, ".gitignore"))
        expect(content).to include(".ai-context.json")
        expect(content).to include(".codex/config.toml")
        expect(surface.text).to include("Updated .gitignore")

        again = surface_class.new
        described_class.mark_gitignore(again, root: root)
        expect(again.lines).to be_empty
        expect(File.read(File.join(root, ".gitignore"))).to eq(content)
      end
    end

    it "appends nothing through a .gitignore that links out of the app, and names it" do
      Dir.mktmpdir do |root|
        Dir.mktmpdir do |outside|
          File.write(File.join(outside, "gitignore"), "log/\n")
          File.symlink(File.join(outside, "gitignore"), File.join(root, ".gitignore"))

          surface = surface_class.new
          described_class.mark_gitignore(surface, root: root)

          expect(File.read(File.join(outside, "gitignore"))).to eq("log/\n")
          expect(surface.text).to include("Left .gitignore as it is - it is a symlink or behind one, which this run does not follow")
        end
      end
    end

    it "appends through a .gitignore that links to a file inside the app" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, "shared.gitignore"), "log/\n")
        File.symlink("shared.gitignore", File.join(root, ".gitignore"))

        described_class.mark_gitignore(surface_class.new, root: root)

        expect(File.symlink?(File.join(root, ".gitignore"))).to be(true)
        expect(File.read(File.join(root, "shared.gitignore"))).to start_with("log/\n").and include(".codex/config.toml")
      end
    end

    # Only the `:json` context format writes .ai-context.json, so an
    # MCP-only app never produces one.
    it "leaves the JSON cache out when no context files are written" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, ".gitignore"), "log/\n")

        described_class.mark_gitignore(surface_class.new, root: root, context_files: false)

        content = File.read(File.join(root, ".gitignore"))
        expect(content).not_to include(".ai-context.json")
        expect(content).to include(".codex/config.toml")
      end
    end
  end

  # The answers an agent or a script gives on the command line, so the
  # install runs to the end without a terminal to type into.
  describe ".tools_flag" do
    it "reads tool names in the menu's order, whatever order they came in" do
      expect(described_class.tools_flag("cursor,claude")).to eq(%i[claude cursor])
      expect(described_class.tools_flag(" Codex  copilot ")).to eq(%i[copilot codex])
    end

    it "reads all as every tool" do
      expect(described_class.tools_flag("all")).to eq(%i[claude cursor copilot opencode codex])
    end

    it "is nil when the flag was not given" do
      expect(described_class.tools_flag(nil)).to be_nil
    end

    it "refuses a name that is no tool, naming the ones that are" do
      expect { described_class.tools_flag("claude,vim") }
        .to raise_error(ArgumentError, /"vim" is not an AI tool.*claude, cursor, copilot, opencode, codex or all/)
    end

    # Thor hands a string option given no value its own name.
    it "refuses an empty value and the flag's own name as a missing value" do
      expect { described_class.tools_flag("") }.to raise_error(ArgumentError, /--tools needs a value/)
      expect { described_class.tools_flag("tools") }.to raise_error(ArgumentError, /--tools needs a value/)
    end

    it "refuses a name that is no tool even beside all" do
      expect { described_class.tools_flag("all,vim") }.to raise_error(ArgumentError, /"vim" is not an AI tool/)
    end

    it "refuses a menu number, which reads differently once a tool is added" do
      expect { described_class.tools_flag("1") }.to raise_error(ArgumentError, /"1" is not an AI tool/)
    end
  end

  describe ".setup_flag" do
    it "is CLI mode with context files for --cli" do
      expect(described_class.setup_flag(cli: true, mcp_only: false).to_a).to eq([ :cli, true ])
    end

    it "is MCP with no context files for --mcp-only" do
      expect(described_class.setup_flag(cli: false, mcp_only: true).to_a).to eq([ :mcp, false ])
    end

    it "is MCP with context files for --mcp" do
      expect(described_class.setup_flag(cli: false, mcp_only: false, mcp: true).to_a).to eq([ :mcp, true ])
    end

    it "is nil when none was given" do
      expect(described_class.setup_flag(cli: false, mcp_only: false)).to be_nil
    end

    it "refuses two at once" do
      expect { described_class.setup_flag(cli: true, mcp_only: true) }
        .to raise_error(ArgumentError, /--mcp, --cli and --mcp-only/)
      expect { described_class.setup_flag(cli: true, mcp_only: false, mcp: true) }.to raise_error(ArgumentError)
    end
  end

  describe ".select_ai_tools, answered on the command line" do
    it "asks nothing and says what was selected" do
      surface = surface_class.new

      expect(described_class.select_ai_tools(surface, given: %i[claude codex])).to eq(%i[claude codex])
      expect(surface.text).not_to include("Which AI tools")
      expect(surface.lines).to include([ :ok, "Selected: Claude Code, Codex CLI" ])
    end
  end

  describe ".select_setup, answered on the command line" do
    it "asks nothing and says what was selected" do
      surface = surface_class.new
      given = described_class::Setup.new(:cli, true)

      expect(described_class.select_setup(surface, given: given)).to eq(given)
      expect(surface.text).not_to include("What should rails-ai-context write?")
      expect(surface.lines).to include([ :ok, "Selected: Context files only (CLI mode, no MCP server)" ])
    end
  end

  describe ".ask_removed_tools with prune" do
    it "takes every dropped tool without asking, and lists them" do
      surface = surface_class.new

      expect(described_class.ask_removed_tools(surface, previous: %i[claude cursor codex], selected: %i[claude], prune: true))
        .to eq(%i[cursor codex])
      expect(surface.text).to include("Cursor (", "Codex CLI (")
      expect(surface.text).not_to include("Remove their generated files?")
    end
  end

  describe ".ask_mcp_removal with prune" do
    it "takes every config that starts the gem without asking" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, ".mcp.json"), %({"mcpServers": {"rails-ai-context": {"command": "rails-ai-context"}}}))
        surface = surface_class.new

        expect(described_class.ask_mcp_removal(surface, root: root, prune: true)).to eq(%i[claude])
        expect(surface.text).not_to include("(y/N)")
      end
    end
  end

  # Each AI tool starts a project's MCP server only after a step in the tool.
  describe ".next_steps" do
    it "names each selected tool's step, in the menu's order" do
      lines = described_class.next_steps(%i[codex claude])

      expect(lines.size).to eq(2)
      expect(lines[0]).to start_with("Claude Code: ").and include("approve", "/mcp")
      expect(lines[1]).to start_with("Codex CLI: ").and include("trust")
    end

    it "has a step for every AI tool" do
      expect(described_class.next_steps(RailsAiContext::Install::AiTool.all.map(&:key)).size)
        .to eq(RailsAiContext::Install::AiTool.all.size)
    end

    # A command run from another folder names that folder, where each tool reads its config.
    it "names the folder each tool is started in where it is not this one" do
      expect(described_class.next_steps(%i[claude copilot codex], place: "in shop")).to eq([
        "Claude Code: start a new Claude Code session in shop and approve each rails-ai-context server when it asks; /mcp lists them",
        "GitHub Copilot: open shop in VS Code as a trusted workspace and send a Copilot Chat message; MCP: List Servers in the Command Palette shows rails-ai-context",
        "Codex CLI: trust shop when Codex CLI asks (it skips the project config of an untrusted one), then start a new codex session in shop; /mcp lists rails-ai-context"
      ])
    end

    # The plugin serves a folder holding one app from a session started there, beside the server init writes.
    it "asks a user whose own settings run the plugin to turn a one-app folder's server off for themselves" do
      config = ENV.fetch("CLAUDE_CONFIG_DIR")
      Dir.mktmpdir do |dir|
        ws = File.realpath(dir)
        app = File.join(ws, "shop")
        FileUtils.mkdir_p(File.join(app, "config"))
        File.write(File.join(app, "config", "application.rb"), "")
        File.write(File.join(ws, ".mcp.json"), JSON.generate("mcpServers" => { "rails-ai-context-shop" => { "command" => "rails-ai-context", "args" => %w[serve --app-path shop] } }))
        FileUtils.mkdir_p(File.join(config, "plugins"))
        File.write(File.join(config, "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
        File.write(File.join(config, "plugins", "installed_plugins.json"),
                   JSON.generate("version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user" } ] }))

        expect(described_class.next_steps(%i[claude], root: ws, app: app).first).to eq(
          "Claude Code: the rails-ai-context plugin already serves this app for you, so turn the .mcp.json server `rails-ai-context-shop` " \
          "off with /mcp in a session started here, or Claude Code lists every tool twice"
        )
      end
    ensure
      FileUtils.rm_rf([ File.join(config, "plugins"), File.join(config, "settings.json") ])
    end

    it "names the plugin as Claude Code's step where the app's committed settings turn it on" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(File.join(Dir.tmpdir, "rails-ai-context-never-ran"))
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, ".claude"))
        File.write(File.join(root, ".claude", "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))

        expect(described_class.next_steps(%i[claude], root: root)).to eq([ "Claude Code: the rails-ai-context plugin serves this app, " \
                                                                           "as .claude/settings.json says; doctor names anything missing" ])
      end
    end

    # A server in the folder above is no entry of the app's own .mcp.json, which the step names.
    it "names only the app's own .mcp.json server, not one a folder above holds" do
      config = ENV.fetch("CLAUDE_CONFIG_DIR")
      Dir.mktmpdir do |dir|
        up = File.realpath(dir)
        root = File.join(up, "shop")
        FileUtils.mkdir_p(File.join(root, "config"))
        File.write(File.join(root, "config", "application.rb"), "")
        File.write(File.join(up, ".mcp.json"), JSON.generate("mcpServers" => { "rails-ai-context-up" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        FileUtils.mkdir_p(File.join(config, "plugins"))
        File.write(File.join(config, "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
        File.write(File.join(config, "plugins", "installed_plugins.json"),
                   JSON.generate("version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user" } ] }))

        expect(described_class.next_steps(%i[claude], root: root).first).to eq("Claude Code: the rails-ai-context plugin serves this app for you")

        File.write(File.join(root, ".mcp.json"), JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        expect(described_class.next_steps(%i[claude], root: root).first).to eq(
          "Claude Code: the rails-ai-context plugin already serves this app for you, so turn the .mcp.json server `rails-ai-context` " \
          "off with /mcp in a session started here, or Claude Code lists every tool twice"
        )
      end
    ensure
      FileUtils.rm_f(File.join(config, "settings.json"))
      FileUtils.rm_rf(File.join(config, "plugins"))
    end

    # Sessions started in the app read its own .mcp.json, not the committed settings of the folder above it.
    it "takes Claude Code's step in the app where its own .mcp.json serves it below a folder that commits the plugin" do
      config = ENV.fetch("CLAUDE_CONFIG_DIR")
      Dir.mktmpdir do |dir|
        ws = File.realpath(dir)
        app = File.join(ws, "shop")
        FileUtils.mkdir_p([ File.join(app, "config"), File.join(ws, ".claude") ])
        File.write(File.join(app, "config", "application.rb"), "")
        File.write(File.join(ws, ".claude", "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
        File.write(File.join(app, ".mcp.json"), JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        FileUtils.mkdir_p(File.join(config, "plugins"))
        File.write(File.join(config, "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
        File.write(File.join(config, "plugins", "installed_plugins.json"),
                   JSON.generate("version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user" } ] }))

        expect(described_class.next_steps(%i[claude codex], root: ws, app: app)).to eq([
          "Claude Code: the rails-ai-context plugin already serves this app for you, so turn the .mcp.json server `rails-ai-context` " \
          "off with /mcp in a session started in shop, or Claude Code lists every tool twice",
          "Codex CLI: #{RailsAiContext::Install::AiTool.find(:codex).next_step}"
        ])
        expect(described_class.next_steps(%i[claude], root: ws, app: app, place: "in ws").first).to include("in a session started in ws/shop,")
      end
    ensure
      FileUtils.rm_f(File.join(config, "settings.json"))
      FileUtils.rm_rf(File.join(config, "plugins"))
    end

    # The .mcp.json is the team's; the plugin is this user's own.
    it "asks a user whose own settings run the plugin to turn the .mcp.json server off for themselves, until it is" do
      config = ENV.fetch("CLAUDE_CONFIG_DIR")
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        FileUtils.mkdir_p(File.join(root, "config"))
        File.write(File.join(root, "config", "application.rb"), "")
        File.write(File.join(root, ".mcp.json"), JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        FileUtils.mkdir_p(File.join(config, "plugins"))
        File.write(File.join(config, "settings.json"), JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
        File.write(File.join(config, "plugins", "installed_plugins.json"),
                   JSON.generate("version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user" } ] }))

        expect(described_class.next_steps(%i[claude], root: root, place: "in shop").first).to eq(
          "Claude Code: the rails-ai-context plugin already serves this app for you, so turn the .mcp.json server `rails-ai-context` " \
          "off with /mcp in a session started in shop, or Claude Code lists every tool twice"
        )

        File.write(File.join(config, ".claude.json"), JSON.generate("projects" => { root => { "disabledMcpServers" => [ "rails-ai-context" ] } }))
        # Off in /mcp, the doubled server is out of the way, and approving it again would bring it back.
        expect(described_class.next_steps(%i[claude], root: root).first).to eq("Claude Code: the rails-ai-context plugin serves this app for you")
      end
    ensure
      FileUtils.rm_f([ File.join(config, "settings.json"), File.join(config, ".claude.json") ])
      FileUtils.rm_rf(File.join(config, "plugins"))
    end
  end

  # The MCP-only setup writes no context files, so ones an earlier setup
  # generated stop being refreshed and go stale.
  describe ".ask_context_removal" do
    def generated_app(root)
      FileUtils.mkdir_p(File.join(root, ".cursor/rules"))
      File.write(File.join(root, ".cursor/rules/rails-project.mdc"), "x")
      File.write(File.join(root, "CLAUDE.md"), "# Mine\n\n<!-- BEGIN rails-ai-context -->\ngen\n<!-- END rails-ai-context -->\n")
      File.write(File.join(root, ".ai-context.json"), "{}")
      File.write(File.join(root, "AGENTS.md"), "# all mine\n")
    end

    it "lists the generated files and asks, keeping them on no" do
      Dir.mktmpdir do |root|
        generated_app(root)
        surface = surface_class.new("n")

        expect(described_class.ask_context_removal(surface, tools: %i[claude cursor opencode], root: root)).to be(false)
        expect(surface.text).to include("CLAUDE.md", ".cursor/rules/rails-project.mdc", ".ai-context.json")
        expect(surface.instance_variable_get(:@answers)).to be_empty
        expect(surface.text).not_to include("AGENTS.md")
      end
    end

    it "takes them all under prune, and removing them keeps what the user wrote" do
      Dir.mktmpdir do |root|
        generated_app(root)
        surface = surface_class.new("n")

        chosen = described_class.ask_context_removal(surface, tools: %i[claude cursor opencode], root: root, prune: true)
        described_class.remove_context_files(surface, %i[claude cursor opencode], root: root)

        expect(chosen).to be(true)
        expect(surface.instance_variable_get(:@answers)).to eq([ "n" ])
        expect(File.read(File.join(root, "CLAUDE.md"))).to eq("# Mine\n\n")
        expect(File.exist?(File.join(root, ".cursor"))).to be(false)
        expect(File.exist?(File.join(root, ".ai-context.json"))).to be(false)
        expect(File.read(File.join(root, "AGENTS.md"))).to eq("# all mine\n")
      end
    end

    it "offers a legacy rule file and a lone JSON cache too" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, ".claude/rules"))
        File.write(File.join(root, ".claude/rules/rails-ui-patterns.md"), "# stale")
        surface = surface_class.new

        expect(described_class.ask_context_removal(surface, tools: %i[claude], root: root, prune: true)).to be(true)
        expect(surface.text).to include(".claude/rules/rails-ui-patterns.md")
      end

      Dir.mktmpdir do |root|
        File.write(File.join(root, ".ai-context.json"), "{}")
        surface = surface_class.new

        expect(described_class.ask_context_removal(surface, tools: %i[claude], root: root, prune: true)).to be(true)
        described_class.remove_context_files(surface, %i[claude], root: root)
        expect(File.exist?(File.join(root, ".ai-context.json"))).to be(false)
      end
    end

    it "asks nothing when no generated file is there" do
      Dir.mktmpdir do |root|
        surface = surface_class.new

        expect(described_class.ask_context_removal(surface, tools: %i[claude], root: root)).to be(false)
        expect(surface.lines).to be_empty
      end
    end
  end

  # A re-run's default is what the app has, so re-running to repair an
  # install, or under --defaults, never switches its tools or its setup.
  describe "defaults on a re-run" do
    it "keeps the recorded tools on an empty answer" do
      surface = surface_class.new("")

      expect(described_class.select_ai_tools(surface, current: %i[cursor])).to eq(%i[cursor])
      expect(surface.lines).to include([ :ok, "Selected: Cursor" ])
    end

    it "keeps the recorded tools on an answer that names none, and says so" do
      surface = surface_class.new("9")

      expect(described_class.select_ai_tools(surface, current: %i[cursor])).to eq(%i[cursor])
      expect(surface.text).to include('"9" names no tool - keeping the current selection')
    end

    it "keeps the recorded setup on an empty answer, and offers it as the default" do
      surface = surface_class.new("")
      current = described_class::Setup.new(:cli, true)

      expect(described_class.select_setup(surface, current: current).to_a).to eq([ :cli, true ])
      expect(surface.text).to include("Currently: Context files only")
    end

    it "takes an answer over the recorded setup" do
      surface = surface_class.new("3")

      expect(described_class.select_setup(surface, current: described_class::Setup.new(:cli, true)).to_a)
        .to eq([ :mcp, false ])
    end

    it "reads the recorded setup, nil when none is recorded" do
      Dir.mktmpdir do |root|
        expect(described_class.recorded_setup(root: root)).to be_nil

        File.write(File.join(root, ".rails-ai-context.yml"), "ai_tools:\n- claude\ntool_mode: mcp\ncontext_files: false\n")
        expect(described_class.recorded_setup(root: root).to_a).to eq([ :mcp, false ])
      end
    end
  end
end
