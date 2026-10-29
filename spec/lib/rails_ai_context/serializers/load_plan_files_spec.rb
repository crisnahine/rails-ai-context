# frozen_string_literal: true

require "spec_helper"

# What a run writes for a selection of AI tools, read the way each tool reads it.
RSpec.describe "Context files for a selection of AI tools" do
  let(:context) { RailsAiContext.introspect }
  let(:marker) { RailsAiContext::Serializers::SectionMarkerWriter }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  before { allow(RailsAiContext.configuration).to receive(:output_dir_for).and_return(@dir) }

  def run(*formats)
    RailsAiContext::Serializers::ContextFileSerializer.new(context, format: formats).call
  end

  def block(name)
    text = File.read(File.join(@dir, name))
    text[(text.index(marker::BEGIN_MARKER) + marker::BEGIN_MARKER.size)...text.index(marker::END_MARKER)].strip
  end

  def path(name) = File.join(@dir, name)

  it "points CLAUDE.md at the AGENTS.md that carries the content" do
    run(:claude, :codex)

    expect(block("CLAUDE.md")).to eq("@AGENTS.md")
    expect(block("AGENTS.md")).to eq(RailsAiContext::Serializers::RootFile.new(context).call.strip)
  end

  # The import is useless without its target, so a Claude-only run writes both.
  it "writes AGENTS.md beside the CLAUDE.md that imports it, whichever tool the run is for" do
    allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude codex])
    run(:claude)

    expect(block("CLAUDE.md")).to eq("@AGENTS.md")
    expect(File).to exist(path("AGENTS.md"))
  end

  it "gives Cursor the root content in AGENTS.md, and no always-on rule or .cursorrules of its own" do
    result = run(:cursor)

    expect(block("AGENTS.md")).to include("## Tools (")
    expect(File).not_to exist(path(".cursor/rules/rails-project.mdc"))
    expect(File).not_to exist(path(".cursor/rules/rails-mcp-tools.mdc"))
    expect(File).to exist(path(".cursor/rules/rails-models.mdc"))
    expect(File).not_to exist(path(".cursorrules"))
    expect(result[:written]).not_to include(path(".cursorrules"))
  end

  it "takes the gem's block out of an old .cursorrules and keeps the user's lines" do
    File.write(path(".cursorrules"), "#{marker::BEGIN_MARKER}\nold\n#{marker::END_MARKER}\n\nMy own rule.\n")

    result = run(:cursor)

    expect(File.read(path(".cursorrules"))).to eq("My own rule.\n")
    expect(result[:trimmed]).to eq([ path(".cursorrules") ])
  end

  it "deletes a .cursorrules that held only the gem's block" do
    File.write(path(".cursorrules"), "#{marker::BEGIN_MARKER}\nold\n#{marker::END_MARKER}\n")

    result = run(:cursor)

    expect(File).not_to exist(path(".cursorrules"))
    expect(result[:removed]).to eq([ path(".cursorrules") ])
  end

  # The root file states the overview and the tools guide; a rule loaded every
  # session beside it said them again.
  it "removes the overview and tools rules a root file makes a second copy of" do
    FileUtils.mkdir_p(path(".claude/rules"))
    %w[rails-context.md rails-mcp-tools.md].each { |name| File.write(path(".claude/rules/#{name}"), "old\n") }

    result = run(:claude)

    expect(Dir.children(path(".claude/rules")).sort).not_to include("rails-context.md", "rails-mcp-tools.md")
    expect(result[:removed]).to include(path(".claude/rules/rails-context.md"), path(".claude/rules/rails-mcp-tools.md"))
  end

  it "keeps the overview and the guide in the rules when root files are off" do
    allow(RailsAiContext.configuration).to receive(:generate_root_files).and_return(false)
    run(:claude, :copilot)

    expect(File.read(path(".claude/rules/rails-context.md"))).to include("Overview")
    expect(File.read(path(".claude/rules/rails-mcp-tools.md"))).to include("Anti-Hallucination Protocol")
    expect(File).to exist(path(".github/instructions/rails-context.instructions.md"))
    expect(File).not_to exist(path("CLAUDE.md"))
  end
end
