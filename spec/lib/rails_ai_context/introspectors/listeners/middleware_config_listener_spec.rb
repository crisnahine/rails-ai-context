# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::MiddlewareConfigListener do
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

  it "reads the app's own stack, however the initializer reaches it" do
    results = parse_and_dispatch(<<~RUBY)
      Rails.application.middleware.unshift PrometheusExporter::Middleware
      Rails.application.middleware.unshift Mastodon::Middleware::PrometheusQueueTime, instrument: false
      Rails.application.configure do |app|
        app.middleware.insert_after ActionDispatch::DebugExceptions, Appsignal::Rack::RailsInstrumentation
      end
    RUBY

    expect(results.map { |r| r[:middleware] }).to eq([
      "PrometheusExporter::Middleware",
      "Mastodon::Middleware::PrometheusQueueTime",
      "Appsignal::Rack::RailsInstrumentation"
    ])
  end

  it "leaves another rack stack alone" do
    results = parse_and_dispatch(<<~RUBY)
      GoodJob::Engine.middleware.use Rack::Auth::Basic
      builder.middleware.use Rack::Timeout
    RUBY

    expect(results).to be_empty
  end

  it "leaves an engine's config alone, however deep the constant sits" do
    results = parse_and_dispatch(<<~RUBY)
      MyEngine.config.middleware.use Rack::Timeout
      GoodJob::Engine.config.middleware.use Rack::Auth::Basic
      Admin::Engine.application.config.middleware.use Rack::Attack
    RUBY

    expect(results).to be_empty
  end

  it "reads the app's own application class, and only that constant" do
    results = parse_and_dispatch(<<~RUBY, app_class: "MyApp::Application")
      MyApp::Application.config.middleware.use A1
      ::MyApp::Application.config.middleware.use A2
      MyApp::Application.middleware.use A3
      OtherApp::Application.config.middleware.use B1
      MyEngine.config.middleware.use B2
    RUBY

    expect(results.map { |r| r[:middleware] }).to eq(%w[A1 A2 A3])
  end

  it "reads no application constant when it does not know the app's" do
    results = parse_and_dispatch("MyApp::Application.config.middleware.use A1")

    expect(results).to be_empty
  end

  it "reads every way an initializer reaches the app's own stack" do
    results = parse_and_dispatch(<<~RUBY)
      config.middleware.use A1
      Rails.configuration.middleware.use A2
      Rails.application.config.middleware.use A3
      Rails.application.middleware.use A4
      Rails.application.configure do |app|
        app.middleware.use A5
        app.config.middleware.use A6
      end
    RUBY

    expect(results.map { |r| r[:middleware] }).to eq(%w[A1 A2 A3 A4 A5 A6])
  end

  it "includes line locations" do
    results = parse_and_dispatch("config.middleware.use Rack::Deflater")
    expect(results.first[:location]).to eq(1)
  end
end
