# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MountListener do
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

  # Rails serves /admin/stats, and a path read off the call alone says
  # /stats - a wrong path is worse than no path.
  it "carries the namespace a Rack app is attached inside" do
    results = parse_and_dispatch(<<~RUBY)
      namespace :admin do
        match "/stats", to: StatsApp, via: :all
      end
    RUBY

    expect(results.first).to include(engine: "StatsApp", path: "/admin/stats")
  end

  it "keeps the name Rails gives the mount" do
    results = parse_and_dispatch(<<~RUBY)
      scope "/store" do
        mount Shop::Engine, at: "/shop", as: "storefront"
      end
      namespace :admin do
        mount Wiki::Engine => "/w"
      end
    RUBY

    expect(results.map { |r| r.slice(:as, :name_prefix) }).to eq([ { as: "storefront" }, { name_prefix: "admin" } ])
  end

  it "carries a scope's path the same way" do
    results = parse_and_dispatch(<<~RUBY)
      scope "/internal" do
        mount StatsApp => "/stats"
      end
    RUBY

    expect(results.first).to include(engine: "StatsApp", path: "/internal/stats")
  end

  it "writes a mount under an optional scope the way Rails normalizes it" do
    results = parse_and_dispatch(<<~RUBY)
      scope "(/locale/:locale)" do
        mount Sidekiq::Web => "sidekiq"
      end
      scope "(:locale)" do
        mount StatsApp => "stats"
      end
    RUBY

    expect(results.map { |r| r[:path] }).to eq([ "(/locale/:locale)/sidekiq", "(/:locale)/stats" ])
  end

  it "leaves the path unknown when the enclosing scope's name cannot be read" do
    results = parse_and_dispatch(<<~RUBY)
      namespace SECTION do
        mount StatsApp => "/stats"
      end
    RUBY

    expect(results.first).to include(engine: "StatsApp")
    expect(results.first[:path]).to be_nil
  end

  it "leaves the path unknown when a scope's own prefix is an expression" do
    results = parse_and_dispatch(<<~RUBY)
      scope PREFIX do
        mount StatsApp => "/stats"
      end
    RUBY

    expect(results.first[:path]).to be_nil
  end

  # A `path:` option is a prefix like the positional one, and a constant or
  # an interpolation there names a segment this walk cannot read.
  it "leaves the path unknown when a path: option is an expression" do
    [
      "namespace :admin, path: ADMIN_PATH do\n  mount StatsApp => \"/stats\"\nend\n",
      "scope path: PREFIX do\n  mount StatsApp => \"/stats\"\nend\n",
      "scope path: \"/v\#{version}\" do\n  mount StatsApp => \"/stats\"\nend\n"
    ].each do |source|
      results = parse_and_dispatch(source)

      expect(results.first).to include(engine: "StatsApp")
      expect(results.first[:path]).to be_nil, source
    end
  end

  it "still reads a literal path: option" do
    results = parse_and_dispatch("namespace :admin, path: \"backoffice\" do\n  mount StatsApp => \"/stats\"\nend\n")

    expect(results.first).to include(path: "/backoffice/stats")
  end

  # The mount most Rails apps carry: the receiver call names the app.
  it "detects an app named by a call on a constant" do
    results = parse_and_dispatch('mount ActionCable.server => "/cable"')

    expect(results.first).to include(engine: "ActionCable.server", path: "/cable")
  end

  it "detects a Rack app attached with the path => app form" do
    results = parse_and_dispatch('get "/metrics" => MetricsApp')

    expect(results.first).to include(engine: "MetricsApp", path: "/metrics")
  end

  it "does not take a controller action in the path => form for an app" do
    expect(parse_and_dispatch('get "/posts" => "posts#index"')).to be_empty
  end

  it "does not leave a trailing slash on a mount at the scope's root" do
    results = parse_and_dispatch("namespace :admin do\n  mount StatsApp, at: \"/\"\nend\n")

    expect(results.first).to include(path: "/admin")
  end

  it "ignores a scope that sets a module and no path" do
    results = parse_and_dispatch(<<~RUBY)
      scope module: :admin do
        mount StatsApp => "/stats"
      end
    RUBY

    expect(results.first).to include(path: "/stats")
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

  it "names an app a constant builds with arguments" do
    results = parse_and_dispatch(<<~RUBY)
      mount Flipper::UI.app(Flipper) => "/feature-toggle"
    RUBY

    expect(results).to match([ a_hash_including(engine: "Flipper::UI.app", path: "/feature-toggle") ])
  end

  # `PagesController.action(:show)` is a controller endpoint, which the booted
  # tier counts as a dynamic route, not a mounted app.
  it "does not name a controller action endpoint as a mounted app" do
    results = parse_and_dispatch(<<~RUBY)
      get "/about", to: PagesController.action(:show)
      mount Flipper::UI.app(Flipper) => "/flags"
    RUBY

    expect(results.map { |r| r[:engine] }).to eq([ "Flipper::UI.app" ])
  end
end
