# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

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
        File.write(File.join(root, ".cursorrules"), "x")

        surface = surface_class.new("y")
        described_class.cleanup_removed_tools(surface, previous: %i[claude cursor], selected: %i[claude], root: root)

        removal = surface.lines.select { |(_, text)| text.include?("Removed") }
        expect(removal).not_to be_empty
        expect(removal.map(&:first)).to all(eq(:ok))
      end
    end

    it "warns about a path it could not remove instead of claiming it went" do
      skip "root can remove anything" if Process.uid.zero?

      Dir.mktmpdir do |root|
        File.write(File.join(root, ".cursorrules"), "x")
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
