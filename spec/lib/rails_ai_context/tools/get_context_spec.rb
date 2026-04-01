# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetContext do
  describe ".call" do
    it "requires at least one parameter" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Provide at least one of")
    end

    it "returns an MCP::Tool::Response" do
      result = described_class.call(model: "NonExistentModel")
      expect(result).to be_a(MCP::Tool::Response)
    end
  end

  describe "cross_reference_ivars" do
    it "uses actual Unicode characters, not escaped sequences" do
      # Access the private method to test directly
      ctrl_ivars = Set.new(%w[ user posts ])
      view_ivars = Set.new(%w[ user comments ])

      result = described_class.send(:cross_reference_ivars, ctrl_ivars, view_ivars)

      # Should use real Unicode checkmark/cross/warning, not literal \u2713
      expect(result).to include("\u2713") # ✓
      expect(result).to include("\u26A0") # ⚠
      expect(result).to include("\u2717") # ✗
      expect(result).not_to include('\\u2713')
      expect(result).not_to include('\\u2717')
      expect(result).not_to include('\\u26A0')
    end

    it "shows matched ivars as set in controller and used in view" do
      ctrl_ivars = Set.new(%w[ user ])
      view_ivars = Set.new(%w[ user ])

      result = described_class.send(:cross_reference_ivars, ctrl_ivars, view_ivars)

      expect(result).to include("@user")
      expect(result).to include("set in controller, used in view")
    end

    it "flags ivars used in view but not set in controller" do
      ctrl_ivars = Set.new
      view_ivars = Set.new(%w[ orphan ])

      result = described_class.send(:cross_reference_ivars, ctrl_ivars, view_ivars)

      expect(result).to include("@orphan")
      expect(result).to include("used in view but NOT set in controller")
    end

    it "flags ivars set in controller but not used in view" do
      ctrl_ivars = Set.new(%w[ unused ])
      view_ivars = Set.new

      result = described_class.send(:cross_reference_ivars, ctrl_ivars, view_ivars)

      expect(result).to include("@unused")
      expect(result).to include("set in controller but not used in view")
    end

    it "returns nil when both sets are empty" do
      result = described_class.send(:cross_reference_ivars, Set.new, Set.new)
      expect(result).to be_nil
    end
  end
end
