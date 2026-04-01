# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::SearchCode do
  describe ".call" do
    it "rejects invalid file_type with special characters" do
      result = described_class.call(pattern: "test", file_type: "rb;rm -rf /")
      text = result.content.first[:text]
      expect(text).to include("Invalid file_type")
    end

    it "accepts valid alphanumeric file_type" do
      result = described_class.call(pattern: "class", file_type: "rb")
      text = result.content.first[:text]
      expect(text).not_to include("Invalid file_type")
    end

    it "uses smart result limiting and shows total count" do
      result = described_class.call(pattern: "class")
      text = result.content.first[:text]
      expect(text).to include("total results")
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "prevents path traversal" do
      result = described_class.call(pattern: "test", path: "../../etc")
      text = result.content.first[:text]
      expect(text).to match(/Path not (found|allowed)/)
    end

    it "returns results for a valid search" do
      result = described_class.call(pattern: "ActiveRecord::Schema")
      text = result.content.first[:text]
      expect(text).to include("Search:")
    end

    it "returns a not-found message for unmatched patterns" do
      result = described_class.call(pattern: "zzz_impossible_pattern_zzz_42")
      text = result.content.first[:text]
      expect(text).to include("No results found")
    end

    it "rejects empty patterns" do
      result = described_class.call(pattern: "   ")
      text = result.content.first[:text]
      expect(text).to include("Pattern is required")
    end

    it "rejects invalid regex patterns" do
      result = described_class.call(pattern: "[invalid")
      text = result.content.first[:text]
      expect(text).to include("Invalid regex")
    end

    it "rejects unknown match_type" do
      result = described_class.call(pattern: "test", match_type: "bogus")
      text = result.content.first[:text]
      expect(text).to include("Unknown match_type")
    end
  end

  describe ".ripgrep_available?" do
    after { described_class.instance_variable_set(:@rg_available, nil) }

    it "caches the result including false" do
      # Reset to nil so we can observe caching
      described_class.instance_variable_set(:@rg_available, nil)

      # First call: should run system check
      result = described_class.send(:ripgrep_available?)

      # Store the result and call again — should not re-check
      expect(described_class.instance_variable_get(:@rg_available)).not_to be_nil

      # Force false and verify it stays cached
      described_class.instance_variable_set(:@rg_available, false)
      expect(described_class.send(:ripgrep_available?)).to eq(false)
    end
  end
end
