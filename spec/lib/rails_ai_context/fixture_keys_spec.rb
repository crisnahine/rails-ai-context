# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::FixtureKeys do
  it "reads an ordinary top-level key as a fixture name" do
    expect(described_class.name?("admin")).to be(true)
    expect(described_class.name?(:one)).to be(true)
  end

  # ActiveRecord drops both, so `users(:DEFAULTS)` raises "No fixture named".
  it "does not read the DEFAULTS anchor or an underscored key as one" do
    expect(described_class.name?("DEFAULTS")).to be(false)
    expect(described_class.name?("_fixture")).to be(false)
  end
end
