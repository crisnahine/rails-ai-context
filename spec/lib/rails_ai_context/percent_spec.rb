# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Percent do
  describe ".floor" do
    # A `be` locale translates 2728 of 2729 keys. Rounding called that 100.0%
    # on the same line that says one key is missing.
    it "never rounds a share short of the whole up to 100" do
      expect(described_class.floor(2728, 2729)).to eq(99.9)
    end

    it "answers 100.0 only for the whole" do
      expect(described_class.floor(2729, 2729)).to eq(100.0)
    end

    it "keeps one decimal place" do
      expect(described_class.floor(1, 3)).to eq(33.3)
    end

    it "answers a whole number when asked for no decimals" do
      expect(described_class.floor(199, 200, decimals: 0)).to eq(99)
      expect(described_class.floor(200, 200, decimals: 0)).to eq(100)
    end

    # In floats 29 / 100 * 100 * 10 is 289.99999999999994, which floors a full step low.
    it "answers an exact share exactly" do
      expect(described_class.floor(29, 100)).to eq(29.0)
      expect(described_class.floor(57, 100)).to eq(57.0)
      expect(described_class.floor(29, 50, decimals: 0)).to eq(58)
    end

    it "answers zero rather than dividing by zero" do
      expect(described_class.floor(5, 0)).to eq(0)
    end
  end
end
