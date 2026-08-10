# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "generators/rails_ai_context/install/install_generator"
require "tmpdir"

# The three install entries used to answer "what did you pick last time?"
# from different files: the generator read the initializer, the standalone
# CLI read the YAML, and re-running through the other one silently dropped
# the selection. They read through one module now, so this is a fast spec
# rather than three e2e runs.
RSpec.describe "Install entry parity" do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  attr_reader :root

  def generator_read
    generator = RailsAiContext::Generators::InstallGenerator.new
    allow(Rails).to receive(:root).and_return(Pathname.new(root))
    generator.send(:read_previous_ai_tools)
  end

  def cli_read
    RailsAiContext::Install::SelectionRecord.read(root: root)
  end

  def write_initializer(tools)
    FileUtils.mkdir_p(File.join(root, "config", "initializers"))
    File.write(File.join(root, "config", "initializers", "rails_ai_context.rb"),
               "RailsAiContext.configure do |config|\n  config.ai_tools = %i[#{tools.join(' ')}]\nend\n")
  end

  it "lets the generator see a selection only the YAML recorded" do
    RailsAiContext::Install::SelectionRecord.write(%i[copilot codex], root: root)

    expect(generator_read).to eq(%i[copilot codex])
  end

  it "lets the standalone CLI see a selection only the initializer recorded" do
    write_initializer(%i[cursor opencode])

    expect(cli_read).to eq(%i[cursor opencode])
  end

  it "gives both entries the same answer when both records exist" do
    write_initializer(%i[claude])
    RailsAiContext::Install::SelectionRecord.write(%i[claude cursor], root: root)

    expect(generator_read).to eq(cli_read)
  end

  # The write half. Whichever entry recorded the selection, the record has to
  # be complete enough that the next entry - reading initializer-first - finds
  # the same answer rather than the stale one.
  it "records into both files, so a later read cannot find a stale initializer" do
    write_initializer(%i[claude])

    RailsAiContext::Install::SelectionRecord.write(%i[codex], root: root)

    expect(File.read(File.join(root, "config", "initializers", "rails_ai_context.rb")))
      .to include("config.ai_tools = %i[codex]")
    expect(YAML.safe_load_file(File.join(root, ".rails-ai-context.yml"))["ai_tools"]).to eq(%w[codex])
    expect(generator_read).to eq([ :codex ])
    expect(cli_read).to eq([ :codex ])
  end

  it "leaves no entry able to write a record another entry would misread" do
    RailsAiContext::Install::SelectionRecord.write(%i[cursor], root: root)

    expect(generator_read).to eq(cli_read)
  end

  it "keeps a hand-edited initializer authoritative for both entries" do
    RailsAiContext::Install::SelectionRecord.write(%i[claude cursor], root: root)
    write_initializer(%i[copilot])

    expect(generator_read).to eq([ :copilot ])
    expect(cli_read).to eq([ :copilot ])
  end
end
