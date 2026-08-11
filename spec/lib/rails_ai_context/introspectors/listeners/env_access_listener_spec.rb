# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::EnvAccessListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    listener   = described_class.new
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(result.value)
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

  describe "names built at runtime" do
    it "does not read an interpolated name as a key" do
      results = parse_and_dispatch('ENV.fetch("#{prefix}URL", nil)')
      expect(results).to be_empty
    end

    it "does not read an interpolated subscript as a key" do
      results = parse_and_dispatch('ENV["#{prefix}DB"]')
      expect(results).to be_empty
    end
  end

  describe "default" do
    it "carries a literal string default" do
      results = parse_and_dispatch('ENV.fetch("PORT", "3000")')
      expect(results.first).to include(has_default: true, default: "3000")
    end

    it "carries a literal number default" do
      results = parse_and_dispatch("ENV.fetch(\"SENTINEL_PORT\", 26_379)")
      expect(results.first[:default]).to eq("26379")
    end

    it "carries a nil default" do
      expect(parse_and_dispatch('ENV.fetch("URL", nil)').first[:default]).to eq("nil")
    end

    it "leaves an index expression out of the default" do
      results = parse_and_dispatch('ENV.fetch("PORT", defaults[:port])')
      expect(results.first).to include(has_default: true, default: nil)
    end

    it "leaves a method call out of the default" do
      results = parse_and_dispatch('ENV.fetch("PASSWORD", default_password)')
      expect(results.first[:default]).to be_nil
    end

    it "leaves a block default out" do
      results = parse_and_dispatch('ENV.fetch("PORT") { compute_port }')
      expect(results.first).to include(has_default: true, default: nil)
    end
  end
end
