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

    it "defaults to every tool out loud on EOF" do
      surface = surface_class.new(nil)

      expect(described_class.select_ai_tools(surface))
        .to eq(RailsAiContext::Install::AiTool.all.map(&:key))
      expect(surface.text).to include("No tools selected - defaulting to all.")
    end

    it "defaults to every tool on input that names nothing" do
      surface = surface_class.new("9,zebra")

      expect(described_class.select_ai_tools(surface))
        .to eq(RailsAiContext::Install::AiTool.all.map(&:key))
      expect(surface.text).to include("No tools selected - defaulting to all.")
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

    it "uses one label per mode" do
      surface = surface_class.new("1")
      described_class.select_setup(surface)
      expect(surface.text).to include("Selected: MCP + CLI fallback")
    end

    it "says what MCP-only leaves alone" do
      surface = surface_class.new("3")
      described_class.select_setup(surface)
      expect(surface.text).to include("MCP config only (no context files)")
      expect(surface.text).to include("leaves CLAUDE.md, AGENTS.md and rules untouched")
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
        expect(surface.text).to include("Removed MCP entry from .cursor/mcp.json", "Removed MCP entry from a/.cursor/mcp.json")
        expect(JSON.parse(File.read(File.join(root, ".cursor/mcp.json")))["mcpServers"].keys).to eq(%w[mine])
        expect(File.exist?(File.join(root, "a/.cursor/mcp.json"))).to be(false)
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

        expect(surface.lines).to include([ :warn, a_string_including("Could not update a/.cursor/mcp.json: it holds comments") ])
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

  describe ".mark_gitignore" do
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
end
