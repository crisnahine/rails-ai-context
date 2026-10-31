# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Install::InitializerFile do
  let(:configure) { "RailsAiContext.configure do |config|\nend\n" }
  let(:bare) { "if defined?(RailsAiContext)\n  #{configure}end\n" }
  let(:current) { "#{described_class::GUARD_LINE}\n  #{configure}end\n" }

  describe ".configures?" do
    it "is true only for a file that calls configure" do
      expect(described_class.configures?(configure)).to be true
      expect(described_class.configures?("# RailsAiContext.configure is off\n")).to be false
    end

    it "counts a call spelled from the top-level constant" do
      expect(described_class.configures?("::RailsAiContext.configure do |c|\n  c.tool_mode = :mcp\nend\n")).to be true
    end

    it "is false for a call that is only text inside a heredoc" do
      expect(described_class.configures?("NOTE = <<~TEXT\n  RailsAiContext.configure\nTEXT\n")).to be false
    end
  end

  describe ".bare_guard?" do
    it "tells the old guard from the current one" do
      expect(described_class.bare_guard?(bare)).to be true
      expect(described_class.bare_guard?(current)).to be false
    end

    it "tells the old guard by its condition, whatever trails it" do
      expect(described_class.bare_guard?("if defined?(RailsAiContext) # absent outside development\n  #{configure}end\n")).to be true
      expect(described_class.bare_guard?("if defined?(RailsAiContext) \n  #{configure}end\n")).to be true
      expect(described_class.bare_guard?("if defined?(RailsAiContext) && ENV[\"X\"]\n  #{configure}end\n")).to be false
    end
  end

  describe ".guarded?" do
    it "counts either spelling the gem writes, and nothing else" do
      expect(described_class.guarded?(bare)).to be true
      expect(described_class.guarded?(current)).to be true
      expect(described_class.guarded?(configure)).to be false
    end
  end

  describe ".any_guard_before_configure?" do
    it "accepts a hand-written guard above the configure call" do
      expect(described_class.any_guard_before_configure?("return unless defined?(RailsAiContext)\n#{configure}")).to be true
      expect(described_class.any_guard_before_configure?("if RailsAiContext.respond_to?(:configure)\n#{configure}end\n")).to be true
    end

    it "rejects a guard that only follows the call, and a file with no call" do
      expect(described_class.any_guard_before_configure?("#{configure}defined?(RailsAiContext)\n")).to be false
      expect(described_class.any_guard_before_configure?("if defined?(RailsAiContext)\nend\n")).to be false
    end

    it "rejects a guard that is only a comment above the call" do
      expect(described_class.any_guard_before_configure?("# was: if defined?(RailsAiContext)\nRailsAiContext.configure do |c|\nend\n")).to be false
    end

    it "rejects a guard that ends before the call, so the call always runs" do
      call = "RailsAiContext.configure do |c|\nend\n"
      expect(described_class.any_guard_before_configure?("if defined?(RailsAiContext)\n  puts 1\nend\n#{call}")).to be false
      expect(described_class.any_guard_before_configure?("puts 1 if defined?(RailsAiContext)\n#{call}")).to be false
    end

    it "accepts the call under a modifier guard, after `&&`, and after an exit unless the gem is there" do
      expect(described_class.any_guard_before_configure?("RailsAiContext.configure { |c| } if defined?(::RailsAiContext)\n")).to be true
      expect(described_class.any_guard_before_configure?("defined?(RailsAiContext) && RailsAiContext.configure { |c| }\n")).to be true
      expect(described_class.any_guard_before_configure?("defined?(RailsAiContext) or return\nRailsAiContext.configure { |c| }\n")).to be true
    end
  end
end
