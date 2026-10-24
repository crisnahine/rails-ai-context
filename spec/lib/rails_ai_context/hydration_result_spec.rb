# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::HydrationResult do
  it "defaults to no hints" do
    result = described_class.new

    expect(result.hints).to eq([])
    expect(result.any?).to be(false)
  end

  it "has something to show when it carries a hint" do
    expect(described_class.new(hints: [ :user ]).any?).to be(true)
  end
end
