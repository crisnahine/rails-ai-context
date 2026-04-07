# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::AssociationsListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects belongs_to" do
    results = parse_and_dispatch("belongs_to :user")
    expect(results.size).to eq(1)
    expect(results.first).to include(type: :belongs_to, name: :user)
  end

  it "detects has_many with options" do
    results = parse_and_dispatch("has_many :posts, dependent: :destroy")
    expect(results.first).to include(type: :has_many, name: :posts)
    expect(results.first[:options]).to include(dependent: :destroy)
  end

  it "detects has_one" do
    results = parse_and_dispatch("has_one :profile, dependent: :destroy")
    expect(results.first).to include(type: :has_one, name: :profile)
  end

  it "detects has_and_belongs_to_many" do
    results = parse_and_dispatch("has_and_belongs_to_many :tags")
    expect(results.first).to include(type: :has_and_belongs_to_many, name: :tags)
  end

  it "ignores method calls with a receiver" do
    results = parse_and_dispatch("self.has_many :posts")
    expect(results).to be_empty
  end

  it "marks static-arg associations as VERIFIED" do
    results = parse_and_dispatch("belongs_to :user, optional: true")
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end

  it "marks dynamic-arg associations as INFERRED" do
    results = parse_and_dispatch("has_many :items, class_name: compute_class")
    expect(results.first[:confidence]).to eq("[INFERRED]")
  end

  it "includes line location" do
    results = parse_and_dispatch("has_many :posts")
    expect(results.first[:location]).to eq(1)
  end
end
