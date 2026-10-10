# frozen_string_literal: true

require "spec_helper"
require "rake"
require "tmpdir"

# The installer's summary sends a user to `rails ai:context:cursor` to add
# Cursor. That wrote Cursor's rules, which tell the AI to call the MCP
# tools, and no .cursor/mcp.json to start them with.
RSpec.describe "rails ai:context:<tool>" do
  around do |example|
    Dir.mktmpdir do |tmp|
      @root = Pathname.new(File.realpath(tmp))
      example.run
    end
  end

  before do
    allow(Rails).to receive(:root).and_return(@root)
    allow(RailsAiContext).to receive(:generate_context).and_return(written: [], skipped: [], not_applicable: {})
    allow(RailsAiContext::LegacyCleanup).to receive(:prompt_legacy_files)
  end

  def with_tool_mode(mode)
    config = RailsAiContext.configuration
    was = config.tool_mode
    config.tool_mode = mode
    yield
  ensure
    config.tool_mode = was
  end

  it "writes the tool's MCP config in MCP mode, with the tool joining the selection" do
    out = with_tool_mode(:mcp) { invoke_rake_task("ai:context:cursor") }

    expect(@root.join(".cursor/mcp.json")).to exist
    expect(out).to include("Created/Updated .cursor/mcp.json")
    expect(RailsAiContext::Install::SelectionRecord.read(root: @root)).to eq([ :cursor ])
  end

  it "writes no MCP config in CLI mode" do
    with_tool_mode(:cli) { invoke_rake_task("ai:context:cursor") }

    expect(@root.join(".cursor/mcp.json")).not_to exist
  end

  it "writes none for the JSON export, which is no AI tool" do
    with_tool_mode(:mcp) { invoke_rake_task("ai:context:json") }

    expect(Dir.children(@root)).to be_empty
  end
end

# The first `rails ai:context` asks what to write. Its answer moved the
# initializer's mode lines without naming the file, and an MCP-only answer
# was recorded nowhere when the app had no initializer, so every later run
# asked again.
RSpec.describe "rails ai:context, the run that asks" do
  around do |example|
    config = RailsAiContext.configuration
    saved = %i[ai_tools tool_mode context_files].to_h { |key| [ key, config.public_send(key) ] }
    stdin = $stdin
    Dir.mktmpdir do |tmp|
      @root = Pathname.new(File.realpath(tmp))
      example.run
    end
  ensure
    $stdin = stdin
    saved.each { |key, value| config.public_send("#{key}=", value) }
  end

  before do
    allow(Rails).to receive(:root).and_return(@root)
    allow(RailsAiContext).to receive(:generate_context).and_return(written: [], skipped: [], not_applicable: {})
    allow(RailsAiContext::LegacyCleanup).to receive(:prompt_legacy_files)
  end

  def answer(text)
    $stdin = StringIO.new(text)
  end

  it "names the initializer when only its mode lines moved" do
    initializer = @root.join("config/initializers/rails_ai_context.rb")
    FileUtils.mkdir_p(initializer.dirname)
    initializer.write(<<~RUBY)
      RailsAiContext.configure do |config|
        config.ai_tools = %i[claude]
      end
    RUBY
    RailsAiContext.configuration.ai_tools = [ :claude ]
    answer("1\n")

    out = invoke_rake_task("ai:context")

    expect(initializer.read).to include("config.tool_mode = :mcp", "config.context_files = true")
    expect(out.scan("Updated config/initializers/rails_ai_context.rb").size).to eq(1)
  end

  it "records an MCP-only answer, so the next run does not ask again" do
    RailsAiContext.configuration.ai_tools = nil
    answer("1\n3\n")

    out = invoke_rake_task("ai:context")

    expect(out).to include("MCP-only install: no context files written.")
    record = YAML.safe_load_file(@root.join(".rails-ai-context.yml"))
    expect(record).to include("ai_tools" => [ "claude" ], "tool_mode" => "mcp", "context_files" => false)
    expect(RailsAiContext::Install::SelectionRecord.tool_mode_set?(root: @root)).to be(true)
  end
end
