# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MountListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    listener   = described_class.new
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(result.value)
    listener.results
  end

  it "detects mount with at: keyword" do
    results = parse_and_dispatch('mount Sidekiq::Web, at: "/sidekiq"')
    expect(results.size).to eq(1)
    expect(results.first).to include(engine: "Sidekiq::Web", path: "/sidekiq")
  end

  it "detects mount with hash rocket syntax" do
    results = parse_and_dispatch('mount Sidekiq::Web => "/sidekiq"')
    expect(results.size).to eq(1)
    expect(results.first).to include(engine: "Sidekiq::Web", path: "/sidekiq")
  end

  it "detects mount with simple constant" do
    results = parse_and_dispatch('mount GrapeApi, at: "/api"')
    expect(results.size).to eq(1)
    expect(results.first).to include(engine: "GrapeApi", path: "/api")
  end

  # `mount` is literally `match(path, to: app, via: :all, anchor: false)`,
  # and an app attached at an exact path is written with `match` so that a
  # mount at /metrics does not also swallow /metrics-admin. The endpoint is
  # the same object either way.
  it "detects a Rack app attached with match ... to:" do
    results = parse_and_dispatch("match '/metrics', to: MetricsApp, via: :all, as: :metrics_app")

    expect(results.size).to eq(1)
    expect(results.first).to include(engine: "MetricsApp", path: "/metrics")
  end

  it "detects one attached with get ... to: a constant" do
    results = parse_and_dispatch('get "/health", to: HealthApp')

    expect(results.first).to include(engine: "HealthApp", path: "/health")
  end

  it "ignores a controller route whose to: is a string" do
    results = parse_and_dispatch("match 'orders/edit' => 'orders#edit', via: :all")

    expect(results).to be_empty
  end

  it "ignores a route pointing at a controller action with to:" do
    results = parse_and_dispatch('get "/orders", to: "orders#index"')

    expect(results).to be_empty
  end

  it "detects multiple mounts" do
    results = parse_and_dispatch(<<~RUBY)
      mount Sidekiq::Web, at: "/sidekiq"
      mount ActionCable.server, at: "/cable"
      mount LetterOpenerWeb::Engine, at: "/letter_opener"
    RUBY

    # ActionCable.server is a method call, not a constant - should be skipped
    engines = results.map { |r| r[:engine] }
    expect(engines).to include("Sidekiq::Web")
    expect(engines).to include("LetterOpenerWeb::Engine")
  end

  it "ignores non-mount calls" do
    results = parse_and_dispatch('get "/users", to: "users#index"')
    expect(results).to be_empty
  end

  it "ignores mount with a receiver" do
    results = parse_and_dispatch('router.mount Sidekiq::Web, at: "/sidekiq"')
    expect(results).to be_empty
  end

  it "includes line locations" do
    results = parse_and_dispatch(<<~RUBY)
      # routes
      mount Sidekiq::Web, at: "/sidekiq"
    RUBY

    expect(results.first[:location]).to eq(2)
  end
end
