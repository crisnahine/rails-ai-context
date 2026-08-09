# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::CountPhrase do
  let(:includer) do
    Class.new do
      include RailsAiContext::CountPhrase

      def render(count, noun, plural: nil) = count_phrase(count, noun, plural: plural)
    end.new
  end

  it "keeps the noun singular at one" do
    expect(includer.render(1, "model")).to eq("1 model")
  end

  it "pluralizes above one" do
    expect(includer.render(3, "model")).to eq("3 models")
  end

  it "pluralizes at zero, which reads as none rather than one" do
    expect(includer.render(0, "model")).to eq("0 models")
  end

  it "pluralizes the last word of a compound noun" do
    expect(includer.render(2, "framework route")).to eq("2 framework routes")
    expect(includer.render(1, "framework route")).to eq("1 framework route")
  end

  it "uses the inflector rather than appending an s" do
    expect(includer.render(2, "query")).to eq("2 queries")
    expect(includer.render(2, "category")).to eq("2 categories")
  end

  # The inflector says "indices"; every database's own docs say "indexes".
  it "takes an explicit plural where the inflector is wrong for the domain" do
    expect(includer.render(2, "index", plural: "indexes")).to eq("2 indexes")
    expect(includer.render(1, "index", plural: "indexes")).to eq("1 index")
  end

  it "is private, so it stays an internal rendering detail" do
    expect(includer).not_to respond_to(:count_phrase)
  end
end
