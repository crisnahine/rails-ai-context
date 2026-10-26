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

  # The file a user edits to change the selection is the one whose write the boot keeps.
  it "names the file that writes the selection, whatever the configure block's param is called" do
    invoke_rake_task("ai:context:cursor")
    initializer = @root.join("config/initializers/rails_ai_context.rb")
    FileUtils.mkdir_p(initializer.dirname)
    File.write(initializer, "RailsAiContext.configure { |c| c.ai_tools = %i[claude] }\n")
    expect(RailsAiContext::RakeTasks.ai_tools_record_hint).to eq("config/initializers/rails_ai_context.rb (config.ai_tools)")

    File.write(initializer, "RailsAiContext.configure do |config|\n  config.preset = :full\nend\n=begin\nconfig.ai_tools = %i[claude]\n=end\n")
    expect(RailsAiContext::RakeTasks.ai_tools_record_hint).to eq(".rails-ai-context.yml (ai_tools)")
  end

  it "says no context file is written when the selection names no tool" do
    File.write(@root.join(".rails-ai-context.yml"), "tool_mode: cli\n")
    config = RailsAiContext.configuration
    was = config.ai_tools
    config.ai_tools = []
    out = with_tool_mode(:cli) { invoke_rake_task("ai:context") }

    expect(out).to include("No AI tool is selected")
    expect(out).not_to include("for all AI tools")
  ensure
    config.ai_tools = was
  end

  it "writes no MCP config in CLI mode" do
    with_tool_mode(:cli) { invoke_rake_task("ai:context:cursor") }

    expect(@root.join(".cursor/mcp.json")).not_to exist
  end

  it "prints its report when the app's own rake file defines a top-level print_result" do
    allow(RailsAiContext).to receive(:generate_context)
      .and_return(written: [ @root.join("CLAUDE.md").to_s ], skipped: [], not_applicable: {})
    Object.class_eval { private def print_result(object) = puts("#{object.class.name},#{object.id}") }

    out = with_tool_mode(:cli) { invoke_rake_task("ai:context:claude") }

    expect(out).to include("CLAUDE.md")
    expect(out).not_to include("Hash,")
  ensure
    Object.send(:remove_method, :print_result) if Object.private_method_defined?(:print_result, false)
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

  [ [ "the first run", nil, "1\n1\n" ], [ "a run that asks only the setup", [ :claude ], "1\n" ] ].each do |run, tools, typed|
    it "leaves an initializer that does not parse on #{run}, and says so once" do
      initializer = @root.join("config/initializers/rails_ai_context.rb")
      FileUtils.mkdir_p(initializer.dirname)
      body = "RailsAiContext.configure do |config|\n  config.ai_tools = %i[claude]\n"
      initializer.write(body)
      RailsAiContext.configuration.ai_tools = tools
      answer(typed)

      out = invoke_rake_task("ai:context")

      expect(initializer.read).to eq(body)
      expect(out.scan("config/initializers/rails_ai_context.rb does not parse as Ruby, so it was left as it is").size).to eq(1)
      expect(out).not_to include("Updated config/initializers")
    end
  end

  it "says which line of the app's settings it could not follow on the first run, and what answers instead" do
    initializer = @root.join("config/initializers/rails_ai_context.rb")
    FileUtils.mkdir_p(initializer.dirname)
    initializer.write("RailsAiContext.configure do |config|\n  config.ai_tools = %i[codex]\n  tools = config.ai_tools\n  tools << :copilot\nend\n")
    RailsAiContext.configuration.ai_tools = nil
    answer("1\n1\n")

    out = invoke_rake_task("ai:context")

    expect(out).to include("config/initializers/rails_ai_context.rb:3: `ai_tools` is changed in place or written by its name, so the YAML or the default answers here")
  end

  it "asks the setup and still writes no context file when the selection names no tool" do
    RailsAiContext.configuration.ai_tools = []
    answer("2\n")

    out = invoke_rake_task("ai:context")

    expect(out).to include("Selected: no AI tool", "No AI tool is selected, so no context file is written.")
    expect(out).not_to include("Writing context files for")
  end

  it "stops before it asks or writes anything when the record will not read, and names it" do
    @root.join(".rails-ai-context.yml").write("ai_tools: [claude\n")
    RailsAiContext.configuration.ai_tools = nil
    answer("1\n1\n")

    expect { expect { invoke_rake_task("ai:context") }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) } }
      .to output("Error: .rails-ai-context.yml cannot be read (invalid YAML at line 1), so nothing was changed. " \
                 "Fix it, or move it aside, and run this again.\n").to_stderr
    expect(Dir.children(@root)).to eq([ ".rails-ai-context.yml" ])
    expect(@root.join(".rails-ai-context.yml").read).to eq("ai_tools: [claude\n")
    expect(RailsAiContext).not_to have_received(:generate_context)
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

  # A second config in the app would start a second server for it.
  it "writes no config of the app's own for a tool a workspace's config above already serves" do
    app = @root.join("a")
    FileUtils.mkdir_p(app)
    allow(Rails).to receive(:root).and_return(app)
    @root.join(".mcp.json").write(JSON.generate("mcpServers" => {
      "rails-ai-context-a" => { "command" => "rails-ai-context", "args" => %w[serve --app-path a] }
    }))
    RailsAiContext.configuration.ai_tools = nil
    answer("1,2\n3\n")

    invoke_rake_task("ai:context")

    expect(app.join(".mcp.json")).not_to exist
    expect(app.join(".cursor/mcp.json")).to exist
  end

  it "warns and still records the answer when writing the MCP configs raises" do
    allow(RailsAiContext::McpConfigGenerator).to receive(:new).and_raise(RuntimeError, "planted")
    RailsAiContext.configuration.ai_tools = nil
    answer("1\n1\n")

    out = invoke_rake_task("ai:context")

    expect(out).to include("Could not create MCP config files: planted")
    expect(RailsAiContext).to have_received(:generate_context)
    expect(@root.join(".rails-ai-context.yml")).to exist
  end
end
