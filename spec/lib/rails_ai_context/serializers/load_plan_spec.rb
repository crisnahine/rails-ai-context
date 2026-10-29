# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::LoadPlan do
  def kinds(tools, root_files: true)
    plan = described_class.new(tools, root_files: root_files)
    [ "AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md", ".cursorrules" ].to_h { |path| [ path, plan.root(path) ] }.compact
  end

  it "writes the content once in AGENTS.md and points CLAUDE.md at it" do
    expect(kinds(%i[claude codex])).to eq("AGENTS.md" => :content, "CLAUDE.md" => :import)
  end

  # CLAUDE.md and AGENTS.md are each read by two of these; AGENTS.md is read
  # by more AI tools in all, so it holds the content and Cursor reads one copy.
  it "picks the file more AI tools read when two reach as many chosen ones" do
    expect(kinds(%i[claude cursor codex])).to eq("AGENTS.md" => :content, "CLAUDE.md" => :import)
  end

  it "gives Claude Code alone the content in CLAUDE.md" do
    expect(kinds(%i[claude])).to eq("CLAUDE.md" => :content)
  end

  # Cursor reads CLAUDE.md and AGENTS.md as it reads its own always-on rules.
  it "gives Cursor the AGENTS.md the other tools share" do
    expect(kinds(%i[claude cursor])).to eq("AGENTS.md" => :content, "CLAUDE.md" => :import)
    expect(kinds(%i[opencode cursor])).to eq("AGENTS.md" => :content)
    expect(kinds(%i[cursor])).to eq("AGENTS.md" => :content)
  end

  # github.com chat, Visual Studio, JetBrains and code review read only
  # copilot-instructions.md, so Copilot keeps a whole copy.
  it "keeps Copilot's own copy beside AGENTS.md" do
    expect(kinds(%i[copilot codex])).to eq("AGENTS.md" => :content, ".github/copilot-instructions.md" => :content)
  end

  it "covers every AI tool with one content file each needs" do
    expect(kinds(RailsAiContext::Install::AiTool.keys)).to eq(
      "AGENTS.md" => :content, "CLAUDE.md" => :import, ".github/copilot-instructions.md" => :content
    )
  end

  it "never writes .cursorrules, which Cursor calls legacy" do
    expect(described_class.new(%i[cursor], root_files: true).root(".cursorrules")).to be_nil
    expect(described_class.new(%i[cursor], root_files: false).root(".cursorrules")).to be_nil
  end

  # With root files off the user keeps their own, and each tool's rules carry an overview.
  it "writes no root file when root files are off" do
    expect(kinds(%i[claude codex cursor], root_files: false)).to eq({})
  end

  it "says which AI tools read the content from a root file" do
    plan = described_class.new(%i[claude cursor copilot], root_files: true)
    expect(%i[claude cursor copilot].map { |tool| plan.root_carries?(tool) }).to eq([ true, true, true ])
    expect(described_class.new(%i[claude], root_files: false).root_carries?(:claude)).to be(false)
  end
end
