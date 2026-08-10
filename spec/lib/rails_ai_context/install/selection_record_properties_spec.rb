# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The record lives across two files a user may have edited by hand, and the
# bugs it has had were all combinations: an initializer shape crossed with a
# YAML shape crossed with what was being written. These assert the properties
# over that cross product rather than naming the combinations one at a time.
#
# Deterministic by construction, so a failure names the exact starting state.
RSpec.describe "SelectionRecord properties" do
  SR = RailsAiContext::Install::SelectionRecord

  # Every initializer a real project might have when install runs again.
  INITIALIZERS = {
    absent: nil,
    empty_file: "",
    no_configure_block: "# just a comment\n",
    configure_no_selection: "RailsAiContext.configure do |config|\n  config.preset = :full\nend\n",
    generated_default: "RailsAiContext.configure do |config|\n" \
                       "  # config.ai_tools = %i[claude cursor copilot opencode codex]  # default: all\n" \
                       "  config.preset = :full\nend\n",
    recorded: "RailsAiContext.configure do |config|\n  config.ai_tools = %i[claude]\n  config.preset = :full\nend\n",
    hand_written_array: "RailsAiContext.configure do |config|\n  config.ai_tools = [:claude, :cursor]\nend\n",
    constant: "RailsAiContext.configure do |config|\n  config.ai_tools = SOME_CONSTANT\nend\n"
  }.freeze

  YAMLS = {
    absent: nil,
    empty: "",
    recorded: "ai_tools:\n  - cursor\n",
    with_extras: "preset: full\nai_tools:\n  - cursor\ntool_mode: mcp\n",
    with_a_date: "ai_tools:\n  - cursor\ngenerated_at: 2026-01-01\n",
    unparseable: "ai_tools: [unclosed\n",
    unknown_tool: "ai_tools:\n  - emacs\n"
  }.freeze

  SELECTIONS = [ [ :codex ], %i[claude cursor], %i[claude cursor copilot opencode codex] ].freeze

  KNOWN = RailsAiContext::Install::AiTool.all.map(&:key).freeze

  def in_project(initializer, yaml)
    Dir.mktmpdir do |root|
      if initializer
        FileUtils.mkdir_p(File.join(root, "config", "initializers"))
        File.write(File.join(root, "config", "initializers", "rails_ai_context.rb"), initializer)
      end
      File.write(File.join(root, ".rails-ai-context.yml"), yaml) if yaml
      yield root
    end
  end

  def each_project
    INITIALIZERS.each do |init_name, initializer|
      YAMLS.each do |yaml_name, yaml|
        in_project(initializer, yaml) { |root| yield "#{init_name}/#{yaml_name}", root }
      end
    end
  end

  it "reads back exactly what it wrote, from every starting state" do
    failures = []

    each_project do |state, root|
      SELECTIONS.each do |selection|
        SR.write(selection, root: root)
        got = SR.read(root: root)
        failures << "#{state}: wrote #{selection.inspect}, read #{got.inspect}" if got != selection
      end
    end

    expect(failures).to be_empty,
      "#{failures.size} state(s) did not round-trip:\n#{failures.first(10).join("\n")}"
  end

  # The initializer wins on read, so a write that updates only the YAML
  # leaves the next read returning the stale selection.
  it "never leaves the two files disagreeing after a write" do
    failures = []

    each_project do |state, root|
      SR.write([ :codex ], root: root)

      initializer_path = File.join(root, "config", "initializers", "rails_ai_context.rb")
      next unless File.exist?(initializer_path)

      content = File.read(initializer_path)
      next unless content.match?(SR::SELECTION_LINE)

      from_initializer = content.match(SR::SELECTION_LINE)[1].split.map(&:to_sym)
      failures << "#{state}: initializer says #{from_initializer.inspect}" if from_initializer != [ :codex ]
    end

    expect(failures).to be_empty,
      "#{failures.size} state(s) left a stale initializer:\n#{failures.first(10).join("\n")}"
  end

  it "never writes a second assignment beside one it cannot rewrite" do
    failures = []

    each_project do |state, root|
      SR.write([ :codex ], root: root)

      path = File.join(root, "config", "initializers", "rails_ai_context.rb")
      next unless File.exist?(path)

      assignments = File.read(path).scan(/^[ \t]*config\.ai_tools\s*=/).size
      failures << "#{state}: #{assignments} assignments" if assignments > 1
    end

    expect(failures).to be_empty,
      "#{failures.size} state(s) ended with more than one assignment:\n#{failures.first(10).join("\n")}"
  end

  it "never reports a tool this gem does not know" do
    unknown = []

    each_project do |state, root|
      got = SR.read(root: root)
      next if got.nil?

      strays = got - KNOWN
      unknown << "#{state}: #{strays.inspect}" if strays.any?
    end

    expect(unknown).to be_empty, "#{unknown.size} state(s) reported an unknown tool:\n#{unknown.join("\n")}"
  end

  it "reports nothing recorded as nil, never as an empty list" do
    empties = []

    each_project do |state, root|
      got = SR.read(root: root)
      empties << state if got == []
    end

    expect(empties).to be_empty, "#{empties.size} state(s) returned []:\n#{empties.join("\n")}"
  end

  it "keeps the rest of an initializer it edits" do
    failures = []

    each_project do |state, root|
      path = File.join(root, "config", "initializers", "rails_ai_context.rb")
      next unless File.exist?(path) && File.read(path).include?("config.preset")

      SR.write([ :codex ], root: root)
      failures << state unless File.read(path).include?("config.preset = :full")
    end

    expect(failures).to be_empty,
      "#{failures.size} state(s) lost an unrelated config line:\n#{failures.join("\n")}"
  end

  it "keeps unrelated YAML keys" do
    in_project(nil, YAMLS[:with_extras]) do |root|
      SR.write([ :codex ], root: root)
      data = YAML.safe_load_file(File.join(root, ".rails-ai-context.yml"))

      expect(data["preset"]).to eq("full")
      expect(data["tool_mode"]).to eq("mcp")
    end
  end

  it "settles after one write, so a repeat reports no change" do
    noisy = []

    each_project do |state, root|
      SR.write([ :codex ], root: root)
      second = SR.write([ :codex ], root: root)

      noisy << "#{state}: #{second[:yaml]}" unless second[:yaml] == :unchanged
    end

    expect(noisy).to be_empty,
      "#{noisy.size} state(s) reported a change on an identical rewrite:\n#{noisy.first(10).join("\n")}"
  end

  # `rails ai:context:<tool>` adds one. It must never drop what was there.
  it "never loses a recorded tool when adding another" do
    losses = []

    each_project do |state, root|
      before = SR.read(root: root) || []
      SR.add(:codex, root: root)
      after = SR.read(root: root) || []

      missing = before - after
      losses << "#{state}: lost #{missing.inspect}" if missing.any?
    end

    expect(losses).to be_empty, "#{losses.size} state(s) lost a tool:\n#{losses.first(10).join("\n")}"
  end

  it "never raises, from any starting state" do
    each_project do |state, root|
      expect {
        SR.read(root: root)
        SR.write([ :codex ], root: root)
        SR.add(:claude, root: root)
        SR.messages(SR.write([ :cursor ], root: root))
      }.not_to raise_error, "raised for #{state}"
    end
  end
end
