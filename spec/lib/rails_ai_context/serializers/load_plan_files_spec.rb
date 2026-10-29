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

  # A link is somebody's own arrangement: taking the block out through one
  # emptied the AGENTS.md this run had just written.
  it "leaves a .cursorrules that links to AGENTS.md alone, and AGENTS.md whole" do
    File.write(path("AGENTS.md"), "# my agents\n")
    File.symlink("AGENTS.md", path(".cursorrules"))

    result = run(:claude, :cursor)

    expect(block("AGENTS.md")).to include("## Tools (")
    expect(result[:trimmed]).to eq([])
    expect(result[:not_applicable][path(".cursorrules")]).to eq(RailsAiContext::SafeFile::LINKED)
  end

  # The import is only as good as the file it names.
  it "gives CLAUDE.md the content when AGENTS.md cannot take its block, which Cursor reads too" do
    File.write(path("AGENTS.md"), "# mine\n#{marker::BEGIN_MARKER}\nold\n")

    result = run(:claude, :cursor)

    expect(block("CLAUDE.md")).to include("## Tools (")
    expect(result[:not_applicable][path("AGENTS.md")]).to eq(marker::UNPAIRED)
  end

  # Codex reads AGENTS.md alone, so with it refused its rules carry the overview.
  it "keeps a tool's own overview when the only root file it reads refused" do
    File.write(path("AGENTS.md"), "# mine\n#{marker::BEGIN_MARKER}\nold\n")
    FileUtils.mkdir_p(path("app/controllers"))

    run(:codex, :claude)

    expect(block("CLAUDE.md")).to include("## Tools (")
    expect(RailsAiContext::Serializers::LoadPlan.new(%i[codex claude]).without("AGENTS.md").root_carries?(:codex)).to be(false)
  end

  # Many repos link one name to the other; an import written through the link
  # replaced the content it names, and the file imported itself.
  %w[CLAUDE.md AGENTS.md].each do |linked|
    it "gives both names the content when #{linked} links to the other" do
      target = (%w[CLAUDE.md AGENTS.md] - [ linked ]).first
      File.write(path(target), "# shared\n")
      File.symlink(target, path(linked))

      run(:claude, :codex)

      expect(block(target)).to include("## Tools (")
      expect(File.read(path(target))).not_to include("@AGENTS.md")
    end
  end

  it "keeps Claude's overview and guide when CLAUDE.md cannot take its import" do
    File.write(path("CLAUDE.md"), "# mine\n#{marker::BEGIN_MARKER}\nold\n")

    result = run(:claude, :codex)

    expect(result[:not_applicable][path("CLAUDE.md")]).to eq(marker::UNPAIRED)
    expect(File.read(path(".claude/rules/rails-context.md"))).to include("Overview")
    expect(File.read(path(".claude/rules/rails-mcp-tools.md"))).to include("Anti-Hallucination Protocol")
  end

  # A rule the gem owns by name, but a link is someone's own arrangement.
  it "leaves a linked rule file the run no longer writes" do
    FileUtils.mkdir_p(path(".claude/rules"))
    File.write(path("elsewhere.md"), "kept\n")
    File.symlink("../../elsewhere.md", path(".claude/rules/rails-context.md"))

    result = run(:claude)

    expect(File.read(path("elsewhere.md"))).to eq("kept\n")
    expect(File.symlink?(path(".claude/rules/rails-context.md"))).to be(true)
    expect(result[:not_applicable][path(".claude/rules/rails-context.md")]).to eq(RailsAiContext::SafeFile::LINKED)
  end

  # Cursor reads CLAUDE.md too, so a Cursor-only run rewrites the full copy a
  # Claude-only run left there into the import.
  it "rewrites a CLAUDE.md a Cursor-only run reads" do
    allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
    run(:claude)
    allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude cursor])
    run(:cursor)

    expect(block("CLAUDE.md")).to eq("@AGENTS.md")
    expect(block("AGENTS.md")).to include("## Tools (")
  end

  # A one-off run for a tool the record does not name left its root file
  # behind, read beside the next run's copy and never refreshed again.
  it "keeps planning for a root file the gem's block is still in" do
    allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
    run(:claude)
    run(:cursor)
    run(:claude)

    expect(block("CLAUDE.md")).to eq("@AGENTS.md")
    expect(block("AGENTS.md")).to include("## Tools (")
  end

  # An unset selection means every AI tool, as a run with no format does.
  it "plans a one-tool run against every AI tool when none are recorded" do
    allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
    run(:claude)

    expect(block("CLAUDE.md")).to eq("@AGENTS.md")
    expect(block("AGENTS.md")).to include("## Tools (")
  end

  # The root AGENTS.md OpenCode always reads states the filters, services and jobs.
  it "leaves the root file's facts out of app/controllers/AGENTS.md" do
    FileUtils.mkdir_p(path("app/controllers"))
    allow_any_instance_of(RailsAiContext::Serializers::OpencodeRulesSerializer).to receive(:service_names).and_return(%w[PaymentService])
    run(:opencode)

    expect(File.read(path("app/controllers/AGENTS.md"))).not_to include("**Services:**", "**Global before_actions:**")
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
