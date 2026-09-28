# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The four compact files render one pipeline, so their sections arrive in one order.
RSpec.describe "Compact context file section order" do
  let(:context) do
    serializer_context(
      gems: { notable_gems: [ { name: "devise", category: :auth } ] },
      conventions: { architecture: [ "MVC" ], patterns: [], config_files: [] },
      _warnings: [ { introspector: "schema", error: "No database" } ]
    )
  end

  let(:expected) do
    [ "Stack", "Key models", "Gems", "Architecture", "Commands", "Warnings", "Rules", "Tools" ]
  end

  def headings(content)
    content.scan(/^## (\S+(?: \S+)?)/).flatten.map { |h| h.sub(/ \(.*/, "").sub(/ -.*/, "").strip }
  end

  before do
    @original_mode = RailsAiContext.configuration.context_mode
    RailsAiContext.configuration.context_mode = :compact
  end

  after { RailsAiContext.configuration.context_mode = @original_mode }

  it "CLAUDE.md" do
    expect(headings(RailsAiContext::Serializers::ClaudeSerializer.new(context).call)).to eq(expected)
  end

  it "AGENTS.md" do
    expect(headings(RailsAiContext::Serializers::OpencodeSerializer.new(context).call)).to eq(expected)
  end

  it ".github/copilot-instructions.md" do
    expect(headings(RailsAiContext::Serializers::CopilotSerializer.new(context).call)).to eq(expected)
  end

  it ".cursorrules" do
    content = Dir.mktmpdir do |dir|
      RailsAiContext::Serializers::CursorRulesSerializer.new(context).call(dir)
      File.read(File.join(dir, ".cursorrules"))
    end

    expect(headings(content)).to eq(expected)
  end
end
