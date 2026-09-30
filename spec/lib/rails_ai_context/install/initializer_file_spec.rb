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
  end

  describe ".bare_guard?" do
    it "tells the old guard from the current one" do
      expect(described_class.bare_guard?(bare)).to be true
      expect(described_class.bare_guard?(current)).to be false
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
  end
end
