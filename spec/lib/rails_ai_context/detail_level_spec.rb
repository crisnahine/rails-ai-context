# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::DetailLevel do
  describe ".valid?" do
    it "accepts the three levels" do
      expect(described_class::ALL).to eq(%w[summary standard full])
      expect(described_class::ALL.all? { |l| described_class.valid?(l) }).to be true
    end

    it "rejects anything else" do
      expect(described_class.valid?("detaled")).to be false
      expect(described_class.valid?(nil)).to be false
    end
  end

  describe ".normalize" do
    it "passes a known level through" do
      expect(described_class.normalize("full")).to eq("full")
    end

    it "reads an unknown level as the default" do
      expect(described_class.normalize("detaled")).to eq("standard")
      expect(described_class.normalize(nil)).to eq("standard")
    end

    it "accepts a symbol" do
      expect(described_class.normalize(:full)).to eq("full")
    end
  end

  describe ".at_least?" do
    it "orders summary below standard below full" do
      expect(described_class.at_least?("full", "standard")).to be true
      expect(described_class.at_least?("standard", "standard")).to be true
      expect(described_class.at_least?("summary", "standard")).to be false
    end
  end

  describe ".full? and .summary?" do
    it "answers for each level" do
      expect(described_class.full?("full")).to be true
      expect(described_class.full?("standard")).to be false
      expect(described_class.summary?("summary")).to be true
      expect(described_class.summary?("full")).to be false
    end
  end
end
