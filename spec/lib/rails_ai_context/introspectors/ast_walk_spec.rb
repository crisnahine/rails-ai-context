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

  it "finds the def that starts at an offset, and nothing where no def starts" do
    source = "class A\n  private def b = 1\n  def c; end\nend\n"
    tree = Prism.parse(source).value

    expect(described_class.def_at(tree, source.index("def c"))&.name).to eq(:c)
    expect(described_class.def_at(tree, source.index("def b"))&.name).to eq(:b)
    expect(described_class.def_at(tree, source.index("private"))).to be_nil
  end
end
