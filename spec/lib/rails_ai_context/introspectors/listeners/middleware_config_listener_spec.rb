# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::MiddlewareConfigListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects config.middleware.use" do
    results = parse_and_dispatch(<<~RUBY)
      Rails.application.configure do
        config.middleware.use Rack::Deflater
        config.middleware.use ActionDispatch::SSL
      end
    RUBY

    expect(results.size).to eq(2)
    expect(results.first[:middleware]).to eq("Rack::Deflater")
    expect(results.first[:action]).to eq("use")
    expect(results.last[:middleware]).to eq("ActionDispatch::SSL")
  end

  it "detects insert_before" do
    results = parse_and_dispatch(<<~RUBY)
      config.middleware.insert_before ActionDispatch::Static, MyMiddleware
    RUBY

    expect(results.size).to eq(1)
    expect(results.first[:action]).to eq("insert_before")
    expect(results.first[:middleware]).to eq("MyMiddleware")
  end

  it "detects insert_after" do
    results = parse_and_dispatch(<<~RUBY)
      config.middleware.insert_after Rack::Sendfile, AnotherMiddleware
    RUBY

    expect(results.size).to eq(1)
    expect(results.first[:action]).to eq("insert_after")
    expect(results.first[:middleware]).to eq("AnotherMiddleware")
  end

  it "detects unshift" do
    results = parse_and_dispatch("config.middleware.unshift CorsMiddleware")
    expect(results.size).to eq(1)
    expect(results.first[:action]).to eq("unshift")
    expect(results.first[:middleware]).to eq("CorsMiddleware")
  end

  it "ignores non-middleware config calls" do
    results = parse_and_dispatch(<<~RUBY)
      config.cache_store = :redis_cache_store
      config.time_zone = "UTC"
    RUBY

    expect(results).to be_empty
  end

  it "includes line locations" do
    results = parse_and_dispatch("config.middleware.use Rack::Deflater")
    expect(results.first[:location]).to eq(1)
  end
end
