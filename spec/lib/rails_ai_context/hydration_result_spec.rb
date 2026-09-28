# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::HydrationResult do
  it "defaults to no hints and no warnings" do
    result = described_class.new

    expect(result.hints).to eq([])
    expect(result.warnings).to eq([])
    expect(result.any?).to be(false)
  end

  it "has something to show when it carries a hint, whatever the warnings" do
    expect(described_class.new(hints: [ :user ]).any?).to be(true)
    expect(described_class.new(warnings: [ "x" ]).any?).to be(false)
  end
end
