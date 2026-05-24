# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MountListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
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
