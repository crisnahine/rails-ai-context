# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::EnvAccessListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects ENV subscript access" do
    results = parse_and_dispatch('ENV["DATABASE_URL"]')
    expect(results.size).to eq(1)
    expect(results.first).to include(method: "[]", key: "DATABASE_URL", has_default: false)
  end

  it "detects ENV.fetch without default" do
    results = parse_and_dispatch('ENV.fetch("SECRET_KEY_BASE")')
    expect(results.size).to eq(1)
    expect(results.first).to include(method: "fetch", key: "SECRET_KEY_BASE", has_default: false)
  end

  it "detects ENV.fetch with default" do
    results = parse_and_dispatch('ENV.fetch("RAILS_ENV", "development")')
    expect(results.size).to eq(1)
    expect(results.first).to include(method: "fetch", key: "RAILS_ENV", has_default: true)
  end

  it "detects multiple ENV accesses" do
    results = parse_and_dispatch(<<~RUBY)
      ENV["HOST"]
      ENV.fetch("PORT", "3000")
      ENV["API_KEY"]
    RUBY

    expect(results.size).to eq(3)
    expect(results.map { |r| r[:key] }).to eq(%w[HOST PORT API_KEY])
  end

  it "ignores non-ENV subscript calls" do
    results = parse_and_dispatch('config["key"]')
    expect(results).to be_empty
  end

  it "ignores ENV method calls that are not [] or fetch" do
    results = parse_and_dispatch('ENV.key?("FOO")')
    expect(results).to be_empty
  end

  it "includes line locations" do
    results = parse_and_dispatch(<<~RUBY)
      x = 1
      ENV["DB"]
    RUBY

    expect(results.first[:location]).to eq(2)
  end
end
