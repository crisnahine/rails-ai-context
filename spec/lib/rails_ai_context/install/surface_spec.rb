# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Install::Surface do
  it "hands say its text and level, defaulting to a plain blank line" do
    said = []
    surface = described_class.new(->(text, level) { said << [ text, level ] }, ->(_) { })

    surface.say("Pick one", :emph)
    surface.say

    expect(said).to eq([ [ "Pick one", :emph ], [ "", :plain ] ])
  end

  it "answers ask with what the entry read, nil at end of input" do
    answers = [ "1,3", nil ]
    surface = described_class.new(->(*) { }, ->(_prompt) { answers.shift })

    expect(surface.ask("> ")).to eq("1,3")
    expect(surface.ask("> ")).to be_nil
  end
end
