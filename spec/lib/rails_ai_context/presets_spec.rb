# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Presets do
  describe "DEFINITIONS" do
    it "defines the architecture, debugging, and migration presets" do
      expect(described_class::DEFINITIONS.keys).to contain_exactly("architecture", "debugging", "migration")
    end

    it "gives every preset a description and a non-empty tool list" do
      described_class::DEFINITIONS.each_value do |preset|
        expect(preset[:desc]).to be_a(String)
        expect(preset[:desc]).not_to be_empty
        expect(preset[:tools]).to be_an(Array)
        expect(preset[:tools]).not_to be_empty
      end
    end

    it "only references tools that resolve to a real registered tool (same lookup the rake task and CLI use)" do
      described_class::DEFINITIONS.each do |preset_name, preset|
        preset[:tools].each do |tool_spec|
          expect { RailsAiContext::CLI::ToolRunner.new(tool_spec[:name], tool_spec[:params]) }
            .not_to raise_error, "#{preset_name} preset references unknown tool '#{tool_spec[:name]}'"
        end
      end
    end

    it "excludes tools that require a caller-supplied target and would only emit a not-provided error with no params" do
      argument_hungry_tools = %w[migration_advisor validate analyze_feature]

      described_class::DEFINITIONS.each_value do |preset|
        tool_names = preset[:tools].map { |t| t[:name] }
        expect(tool_names & argument_hungry_tools).to be_empty
      end
    end
  end

  describe ".run" do
    it "runs every tool in the preset, framing on err and tool output on out" do
      out = StringIO.new
      err = StringIO.new
      expect(described_class.run("migration", out: out, err: err)).to be true

      expect(err.string).to include("Preset: migration")
      expect(err.string.scan(/^Running: /).size).to eq(3)
      expect(out.string).not_to be_empty
    end

    it "answers false for a name that matches no preset and prints nothing" do
      out = StringIO.new
      err = StringIO.new
      expect(described_class.run("nope", out: out, err: err)).to be false
      expect(out.string).to be_empty
    end

    it "keeps going when one tool raises" do
      allow(RailsAiContext::CLI::ToolRunner).to receive(:new).and_wrap_original do |m, name, params, **kw|
        raise "boom" if name == "runtime_info"
        m.call(name, params, **kw)
      end
      err = StringIO.new
      described_class.run("migration", out: StringIO.new, err: err)
      expect(err.string).to include("[error] runtime_info: boom")
    end
  end

  describe ".listing" do
    it "renders one line per preset in the caller's invocation form" do
      text = described_class.listing(invocation: ->(key) { "rails-ai-context preset #{key}" })
      expect(text).to include("rails-ai-context preset architecture")
      expect(text.lines.size).to eq(described_class::DEFINITIONS.size + 2)
    end
  end
end
