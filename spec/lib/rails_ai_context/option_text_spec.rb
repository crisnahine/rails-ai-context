# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::OptionText do
  it "prints a string as written" do
    expect(described_class.call("published?")).to eq("published?")
  end

  it "prints a symbol as a symbol literal, so it reads as a method name" do
    expect(described_class.call(:published?)).to eq(":published?")
  end

  it "prints any other value as its literal" do
    expect(described_class.call([ :a, 1 ])).to eq("[:a, 1]")
    expect(described_class.call(nil)).to eq("nil")
  end
end
