# frozen_string_literal: true

require "spec_helper"

# GUIDE.md stated 29 generated files while listing 18. The total and the five
# per-tool headings are now right, and nothing held them there: the next rule
# file added to any RULE_FILES table would break the same claim again. Derive
# the counts from the tables that write the files.
RSpec.describe "the generated-file counts in GUIDE.md" do
  # A constant assigned in a describe block lands on Object, where a name this
  # generic can collide with an app's own.
  let(:rule_tables) do
    {
      claude: RailsAiContext::Serializers::ClaudeRulesSerializer::RULE_FILES,
      cursor: RailsAiContext::Serializers::CursorRulesSerializer::RULE_FILES,
      copilot: RailsAiContext::Serializers::CopilotInstructionsSerializer::RULE_FILES
    }
  end

  # The generic file no AI tool owns.
  let(:json_context_file) { ".ai-context.json" }

  def guide
    @guide ||= File.read(File.expand_path("../../../docs/GUIDE.md", __dir__))
  end

  # An AiTool's context_paths name the root file first and the split targets
  # after it; a rules_dir stands for every file its serializer writes there.
  def files_for(tool)
    tool.context_paths.flat_map do |path|
      next [ path ] unless path == tool.rules_dir

      rule_tables.fetch(tool.key).keys.map { |name| File.join(path, name) }
    end
  end

  let(:tools) { RailsAiContext::Install::AiTool.all }

  it "states the total the tables add up to" do
    total = tools.flat_map { |tool| files_for(tool) }.uniq.size + 1

    expect(guide).to include("generates **#{total} files**")
    expect(guide).to include("Generate all #{total} context files")
  end

  it "heads each tool's section with the number of files that tool gets" do
    tools.each do |tool|
      # Codex writes the same AGENTS.md set as OpenCode, so GUIDE.md lists it
      # once, under OpenCode.
      next if tool.key == :codex

      expect(guide).to include("### #{tool.name} (#{files_for(tool).size} files)"), tool.name
    end
  end

  it "gives the generic JSON file a section of its own" do
    expect(guide).to include("### Generic (1 file)")
    expect(guide).to include("`#{json_context_file}`")
  end

  it "leaves no name of its own on Object" do
    expect(Object.const_defined?(:RULE_TABLES)).to be(false)
    expect(Object.const_defined?(:JSON_CONTEXT_FILE)).to be(false)
  end

  # The paragraph under the total shows what a surface prints for a file the
  # app has nothing to put in. `rails ai:context` is the emoji surface.
  it "shows the wording each surface actually prints" do
    %i[emoji plain].each do |style|
      line = format(
        RailsAiContext::ContextFileReport.style(style)[:not_applicable],
        ".claude/rules/rails-models.md", "no models"
      )

      expect(guide).to include(line), style.to_s
    end
  end
end
