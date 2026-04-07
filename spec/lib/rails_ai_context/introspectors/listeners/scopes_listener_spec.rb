# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::ScopesListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects simple scopes" do
    results = parse_and_dispatch("scope :active, -> { where(active: true) }")
    expect(results.size).to eq(1)
    expect(results.first[:name]).to eq("active")
  end

  it "detects scopes with parameters" do
    results = parse_and_dispatch("scope :by_role, ->(role) { where(role: role) }")
    expect(results.first[:name]).to eq("by_role")
  end

  it "detects multiple scopes" do
    source = <<~RUBY
      scope :active, -> { where(active: true) }
      scope :recent, -> { order(created_at: :desc) }
    RUBY
    results = parse_and_dispatch(source)
    expect(results.map { |s| s[:name] }).to contain_exactly("active", "recent")
  end

  it "includes confidence tag" do
    results = parse_and_dispatch("scope :active, -> { where(active: true) }")
    expect(results.first[:confidence]).to eq("[VERIFIED]").or eq("[INFERRED]")
  end

  it "includes line location" do
    results = parse_and_dispatch("scope :active, -> { where(active: true) }")
    expect(results.first[:location]).to eq(1)
  end
end
