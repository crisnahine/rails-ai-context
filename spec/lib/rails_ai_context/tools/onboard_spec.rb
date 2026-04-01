# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::Onboard do
  before { described_class.reset_cache! }

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "includes app name in output" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Welcome")
    end

    it "quick mode returns a paragraph without section headers" do
      result = described_class.call(detail: "quick")
      text = result.content.first[:text]
      expect(text).not_to include("## ")
      expect(text).to include("Rails")
    end

    it "standard mode includes structured sections" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("## Stack")
      expect(text).to include("## Testing")
      expect(text).to include("## Getting Started")
    end

    it "full mode includes additional sections beyond standard" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("## Stack")
      expect(text).to include("Full Walkthrough")
    end

    it "handles missing context data gracefully" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp",
        rails_version: "8.0",
        ruby_version: "3.4"
      })
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("TestApp")
      expect(text).not_to include("error")
    end
  end
end
