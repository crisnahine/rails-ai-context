# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::NodeSource do
  def call_node(source)
    Prism.parse(source).value.statements.body.first
  end

  it "keeps a heredoc's body, which the node's own slice stops before" do
    node = call_node(<<~RUBY)
      where(<<~SQL, id)
        state = 'open'
      SQL
    RUBY

    expect(node.slice).not_to include("state = 'open'")
    expect(described_class.text(node)).to include("where(<<~SQL, id)")
    expect(described_class.text(node)).to include("state = 'open'")
  end

  it "answers the slice when the node opens no heredoc" do
    node = call_node("where(state: 'open')")

    expect(described_class.text(node)).to eq("where(state: 'open')")
  end

  it "keeps every heredoc body a node opens" do
    node = call_node(<<~RUBY)
      pair(<<~A, <<~B)
        first
      A
        second
      B
    RUBY

    text = described_class.text(node)
    expect(text).to include("first")
    expect(text).to include("second")
  end
end
