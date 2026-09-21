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

  describe ".select_tool_mode" do
    it "answers :cli on 2 and :mcp on anything else, EOF included" do
      expect(described_class.select_tool_mode(surface_class.new("2"))).to eq(:cli)
      expect(described_class.select_tool_mode(surface_class.new(""))).to eq(:mcp)
      expect(described_class.select_tool_mode(surface_class.new(nil))).to eq(:mcp)
    end

    it "uses one label per mode" do
      surface = surface_class.new("1")
      described_class.select_tool_mode(surface)
      expect(surface.text).to include("Selected: MCP + CLI fallback")
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
