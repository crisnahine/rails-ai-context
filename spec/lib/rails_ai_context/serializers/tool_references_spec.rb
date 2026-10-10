# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Every file a run writes, read back as the AI tool reads it. The guide named
# tools tools/list does not hold (`get_schema`, `get_context`), broke its own
# code spans, kept "use MCP tools" in eleven files of a CLI-mode app, and
# counted and listed the 45 built-ins whatever skip_tools and custom_tools
# made of them.
RSpec.describe "the tools every generated file names" do
  let(:context) { RailsAiContext.introspect }

  around do |example|
    config = RailsAiContext.configuration
    saved = config.tool_mode, config.skip_tools, config.custom_tools
    example.run
  ensure
    config.tool_mode, config.skip_tools, config.custom_tools = saved
  end

  # path => content of every markdown file one run writes.
  def generated_files
    Dir.mktmpdir do |dir|
      allow(RailsAiContext.configuration).to receive(:output_dir_for).and_return(dir)
      %w[app/models app/controllers].each { |sub| FileUtils.mkdir_p(File.join(dir, sub)) }
      written = RailsAiContext::Serializers::ContextFileSerializer.new(context, format: :all).call[:written]
      written.reject { |path| path.end_with?(".json") }.to_h { |path| [ path.delete_prefix("#{dir}/"), File.read(path) ] }
    end
  end

  def served_names
    RailsAiContext::Server.exposed_tools.map(&:tool_name)
  end

  describe "in :mcp mode" do
    before { RailsAiContext.configuration.tool_mode = :mcp }

    it "names only tools the server serves" do
      generated_files.each do |path, content|
        named = content.scan(/`((?:rails_)?get_\w+|rails_\w+)[`(]/).flatten.uniq

        expect(named - served_names).to eq([]), "#{path} names #{(named - served_names).join(', ')}"
      end
    end

    # A backtick inside a span (`undefined method `foo` for nil`) cuts it in
    # two, and each half starts or ends with the space beside the inner one.
    # "Read model files for business logic" sat beside "NEVER read ... model
    # files" in the same AI's context.
    it "tells the AI to read a model file only to edit it, in every file" do
      generated_files.each do |path, content|
        expect(content).not_to include("Read model files for"), path
      end
    end

    it "keeps every code span whole" do
      generated_files.each do |path, content|
        broken = content.lines.select do |line|
          line.count("`").odd? || line.scan(/`([^`]*)`/).flatten.any? { |span| span.match?(/\A\s|\s\z/) }
        end

        expect(broken).to eq([]), "#{path}: #{broken.first}"
      end
    end
  end

  describe "in :cli mode" do
    before { RailsAiContext.configuration.tool_mode = :cli }

    it "sends every file to the commands, none to an MCP tool" do
      generated_files.each do |path, content|
        expect(content).not_to match(/\bMCP\b/), "#{path} still says MCP"
        expect(content.scan(/`rails_\w+/)).to eq([]), "#{path} names an MCP tool"
      end
    end

    it "names the command for each pointer in the split files" do
      files = generated_files

      expect(files["app/models/AGENTS.md"]).to include("`rails 'ai:tool[model_details]' model=Name`")
      expect(files[".cursor/rules/rails-controllers.mdc"]).to include("Use `rails 'ai:tool[controllers]' controller=Name` for full detail.")
      expect(files[".claude/rules/rails-context.md"]).to include("ALWAYS use introspection tools (`rails 'ai:tool[TOOL_NAME]' param=value`)")
    end
  end

  describe "with tools skipped and a custom tool added" do
    let(:custom_tool) do
      Class.new(MCP::Tool) do
        tool_name "rails_get_widgets"
        description "Lists the app's widgets with their owners. Reads app/widgets."

        def self.call(server_context: nil)
          MCP::Tool::Response.new([ { type: "text", text: "none" } ])
        end
      end
    end

    before do
      RailsAiContext.configuration.tool_mode = :mcp
      RailsAiContext.configuration.skip_tools = %w[rails_security_scan rails_query]
      RailsAiContext.configuration.custom_tools = [ custom_tool ]
    end

    it "counts and lists what tools/list holds" do
      files = generated_files
      count = RailsAiContext::Server.builtin_tools.size - 2 + 1

      expect(served_names.size).to eq(count)
      expect(files["CLAUDE.md"]).to include("## Tools (#{count})", "### All #{count} tools", "`rails_get_widgets`")
      files.each do |path, content|
        expect(content).not_to include("rails_security_scan", "ai:tool[query]"), "#{path} documents a skipped tool"
      end
    end

    it "gives the custom tool a row of its own in the table" do
      table = generated_files[".claude/rules/rails-mcp-tools.md"]

      expect(table).to include("### All #{served_names.size} Tools")
      expect(table).to include("| `rails_get_widgets` | `rails 'ai:tool[widgets]'` | Lists the app's widgets with their owners. |")
    end
  end
end
