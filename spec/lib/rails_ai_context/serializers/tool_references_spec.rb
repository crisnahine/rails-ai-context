# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Every file a run writes, read back as the AI tool reads it. The guide
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
