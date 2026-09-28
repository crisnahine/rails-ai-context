# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::AstWalk do
  let(:tree) { Prism.parse("def a\n  b(1)\nend\nc").value }

  it "yields the root first, then every node in source order" do
    calls = described_class.each(tree).grep(Prism::CallNode).map(&:name)

    expect(described_class.each(tree).first).to be(tree)
    expect(calls).to eq(%i[b c])
  end

  it "reaches nodes nested inside a method body" do
    expect(described_class.each(tree).grep(Prism::IntegerNode).map(&:value)).to eq([ 1 ])
  end

  it "answers an enumerator without a block" do
    expect(described_class.each(tree)).to be_an(Enumerator)
  end
end
