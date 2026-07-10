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

  describe ".names" do
    it "returns the preset keys" do
      expect(described_class.names).to match_array(described_class::DEFINITIONS.keys)
    end
  end

  describe ".fetch" do
    it "returns the preset definition for a known name" do
      expect(described_class.fetch("migration")).to eq(described_class::DEFINITIONS["migration"])
    end

    it "returns nil for an unknown name" do
      expect(described_class.fetch("nonexistent")).to be_nil
    end
  end
end
