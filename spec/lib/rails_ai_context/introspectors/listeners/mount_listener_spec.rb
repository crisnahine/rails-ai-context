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

  it "reads no path from a mount at an expression" do
    [ 'mount MetricsRack => ENV.fetch("QA_METRICS_PATH", "/qa_metrics")',
      "mount MetricsRack, at: ENV.fetch(\"P\")",
      "mount MetricsRack, at: METRICS_PATH",
      "mount MetricsRack => METRICS_PATH",
      'mount MetricsRack, at: "/m#{n}"' ].each do |code|
      expect(parse_and_dispatch(code).first).to include(engine: "MetricsRack", path: nil), code
    end
  end

  it "writes a path given without its leading slash the way Rails does" do
    expect(parse_and_dispatch("mount PgHero::Engine, at: 'pghero'").first).to include(path: "/pghero")
  end

  # Live (Rails 7.0.10 and 8.1.4) draws each at the symbol's name: /hc, /hc2, GET /metrics.
  it "reads a path written as a symbol" do
    expect(parse_and_dispatch("mount HealthCheck, at: :hc").first).to include(path: "/hc")
    expect(parse_and_dispatch("mount HealthCheck => :hc2").first).to include(path: "/hc2")
    expect(parse_and_dispatch("get :metrics, to: HealthCheck").first).to include(path: "/metrics")
  end

  # Live (Rails 7.0.10 and 8.1.4): a symbol naming a canonical action draws at the member, collection or
  # singular resource's own path; the same name as a string, or outside one, keeps its segment.
  it "draws a symbol naming a canonical action at the scope's own path" do
    routes = RailsAiContext::Introspectors::Listeners::RoutesDslListener.new
    results = RailsAiContext::Introspectors::SourceIntrospector.walk_source(<<~ROUTES, { routes: -> { routes }, mounts: -> { described_class.new(routes: routes) } })[:mounts]
      resources :posts do
        collection do
          get :index, to: HealthCheck
          mount HealthCheck, at: :index
          get "index", to: HealthCheck
        end
        member { get :show, to: HealthCheck }
        get :show, on: :member, to: HealthCheck
        get :new, on: :collection, to: HealthCheck
        get :index, to: HealthCheck
      end
      resource(:account) { member { get :show, to: HealthCheck } }
      get :index, to: HealthCheck
    ROUTES

    expect(results.map { |r| r[:path] }).to eq(
      %w[/posts /posts /posts/index /posts/:id /posts/:id /posts /posts/:post_id/index /account /index]
    )
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

  # A live RouteSet attaches HealthCheck at /admin/hc and StatsApp at /stats: tap and then hand their block the mapper.
  it "reads a mount on the mapper a tap block takes as its parameter" do
    results = parse_and_dispatch(<<~RUBY)
      tap { |m| m.namespace(:admin) { m.mount HealthCheck, at: "/hc" } }
      self.then { it.mount StatsApp => "/stats" }
    RUBY

    expect(results.map { |r| r.slice(:engine, :path) }).to eq([ { engine: "HealthCheck", path: "/admin/hc" }, { engine: "StatsApp", path: "/stats" } ])
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

  # A live RouteSet mounts what APPS[:a] holds at /a, and the booted tier counts it as an
  # unrouted mount; a verb route to a held value is a dynamic route there, not a mount.
  it "lists a mount of a value a constant holds at its path with an inferred app, and no verb route to one" do
    results = parse_and_dispatch(<<~ROUTES)
      get "x", to: HANDLERS[:x]
      get "y", to: HANDLERS.fetch(:y)
      get "z" => HANDLERS[:z]
      match "w" => APPS.fetch(:w), via: :get
      mount APPS.dig(:admin) => "/admin"
      mount APPS[:a] => "/a"
      mount HANDLERS[:x], at: "/x"
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq(
      [ [ "[INFERRED]", "/admin" ], [ "[INFERRED]", "/a" ], [ "[INFERRED]", "/x" ] ]
    )
  end

  # A live RouteSet serves /b, /d and /m with HealthCheck, /api with API and /v with Api::V1, draws /a and /r
  # to posts#index, serves /e and /l with a lambda, and /u with a value only a boot can read.
  it "names a Rack app a constant the file assigns by what it holds, and no app for a string or a value it cannot see" do
    results = parse_and_dispatch(<<~ROUTES)
      TO = "posts#index"
      ALIAS = HealthCheck
      LAM = ->(env) { [200, {}, []] }
      get "a", to: TO
      get "r" => TO
      get "b", to: HealthCheck
      get "d", to: ALIAS
      get "e", to: LAM
      get "u", to: UNSEEN
      get "v", to: Api::V1
      mount ALIAS, at: "/m"
      mount LAM, at: "/l"
      mount API, at: "/api"
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq(
      [ [ "HealthCheck", "/b" ], [ "HealthCheck", "/d" ], [ "Api::V1", "/v" ], [ "HealthCheck", "/m" ], [ "API", "/api" ] ]
    )
  end

  # Ruby defines APP inside Shop, so the mount's bare APP is another constant, named as written.
  it "reads only a constant written outside a class or module body as the app a mount names" do
    results = parse_and_dispatch(<<~ROUTES)
      module Shop
        APP = HealthCheck
      end
      mount APP, at: "/m"
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq([ [ "APP", "/m" ] ])
  end

  # A live RouteSet serves /m, /n and /p with HealthCheck, reading each constant where Ruby finds it, and /u with the class Admin::UI.
  it "names a Rack app a constant written in a module holds, as Ruby looks the reference up" do
    results = parse_and_dispatch(<<~ROUTES)
      module Shop
        APP = HealthCheck
        mount APP, at: "/m"
      end
      mount Shop::APP, at: "/n"
      module Ops; end
      Ops::APP = HealthCheck
      get "p", to: Ops::APP
      get "u", to: Admin::UI
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq([ [ "HealthCheck", "/m" ], [ "HealthCheck", "/n" ], [ "HealthCheck", "/p" ], [ "Admin::UI", "/u" ] ])
  end

  # A live RouteSet serves /n, /p, /g and /i with a HealthCheck and /b with a Rack::Builder, which the booted tier names
  # by the instance's class, and /c with the class CN; what Builder.app returns at /a only a boot can read.
  it "names a Rack app the file builds as the booted tier does: an instance by its class, a built class by its constant" do
    results = parse_and_dispatch(<<~ROUTES)
      NEWAPP = HealthCheck.new
      PROBE = HealthCheck.new(:deep)
      BUILT = Rack::Builder.new { run HealthCheck }
      CN = Class.new { def self.call(env) = [200, {}, []] }
      BA = Rack::Builder.app do
        run HealthCheck
      end
      mount NEWAPP, at: "/n"
      mount PROBE => "/p"
      mount BUILT, at: "/b"
      mount CN, at: "/c"
      mount BA, at: "/a"
      get "g", to: NEWAPP
      mount HealthCheck.new, at: "/i"
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq(
      [ [ "HealthCheck", "/n" ], [ "HealthCheck", "/p" ], [ "Rack::Builder", "/b" ], [ "CN", "/c" ], [ "HealthCheck", "/g" ],
        [ "HealthCheck", "/i" ] ]
    )
  end

  # A live RouteSet on 7.0 and 8.1 mounts the class CN2 at /c and the module CM2 at /d: `::Class.new` is `Class.new`.
  it "names an app built with a rooted Class.new or Module.new by its constant" do
    results = parse_and_dispatch(<<~ROUTES)
      CN2 = ::Class.new { def self.call(env) = [200, {}, []] }
      CM2 = ::Module.new { def self.call(env) = [200, {}, []] }
      mount CN2, at: "/c"
      mount CM2, at: "/d"
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq([ [ "CN2", "/c" ], [ "CM2", "/d" ] ])
  end

  # A live RouteSet on 7.0 and 8.1 mounts a HealthCheck at /n and /g: AL is HealthCheck, so AL.new is one of its instances.
  it "names an instance built through a constant holding a class by that class" do
    results = parse_and_dispatch(<<~ROUTES)
      AL = HealthCheck
      mount AL.new, at: "/n"
      get "g", to: AL.new
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq([ [ "HealthCheck", "/n" ], [ "HealthCheck", "/g" ] ])
  end

  # A live RouteSet on 7.0 and 8.1 mounts Admin::UI at /u: inside module Admin, Ruby finds UI there before the top level.
  it "names a mounted class by the constant Ruby finds through Module.nesting" do
    results = parse_and_dispatch(<<~ROUTES)
      module Admin
        class UI
          def self.call(env) = [200, {}, []]
        end
        Rails.application.routes.draw do
          mount UI, at: "/u"
        end
      end
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq([ [ "Admin::UI", "/u" ] ])
  end

  # A live RouteSet on 7.0 and 8.1 mounts HealthCheck at /hc: tap yields the mapper, which an optional first parameter takes.
  it "lists a mount on an optional parameter of a tap block on the mapper" do
    results = parse_and_dispatch('tap { |m = 1| m.mount HealthCheck, at: "/hc" }')

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq([ [ "HealthCheck", "/hc" ] ])
  end

  # A live RouteSet on 7.0 and 8.1 mounts HealthCheck at /w and /v: `||=` assigns a constant not yet defined, and only then.
  it "reads a constant an ||= assigns as its value, and one it leaves alone as before" do
    results = parse_and_dispatch(<<~ROUTES)
      APW ||= HealthCheck
      APV = HealthCheck
      APV ||= Other
      mount APW, at: "/w"
      mount APV, at: "/v"
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq([ [ "HealthCheck", "/w" ], [ "HealthCheck", "/v" ] ])
  end

  # A constant holding a call reads as the call written in place: a factory call is named by what builds it, a call
  # with a block is no app this walk names, held or not.
  it "names a mount of a constant holding a call as a mount of that call" do
    results = parse_and_dispatch(<<~ROUTES)
      FAPP = Flipper::UI.app(Flipper)
      BAPP = Rack::Builder.app { run HealthCheck }
      mount FAPP, at: "/f"
      mount Flipper::UI.app(Flipper), at: "/g"
      mount BAPP, at: "/b"
      mount Rack::Builder.app { run HealthCheck }, at: "/c"
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq([ [ "Flipper::UI.app", "/f" ], [ "Flipper::UI.app", "/g" ] ])
  end

  # A live RouteSet draws /a to /f to posts#index, and mounts at /m what APPS[:a] holds, which only a boot can name.
  it "lists no app for a verb route to a constant holding a call the file does not build, and an inferred one for its mount" do
    results = parse_and_dispatch(<<~ROUTES)
      TOF = "posts#index".freeze
      TOH = STRS[:a]
      TOE = ENV.fetch("X_TO", "posts#index")
      TOM = APPS[:a]
      get "a", to: TOF
      get "b" => TOF
      get "c", to: TOH
      get "d" => TOH
      get "e", to: TOE
      get "f" => TOE
      mount TOM, at: "/m"
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq([ [ "[INFERRED]", "/m" ] ])
  end

  it "mounts an app under scope nil at its own path, as Rails' scope adds no segment for it" do
    results = parse_and_dispatch(<<~ROUTES)
      scope nil do
        mount Web => "/s"
      end
    ROUTES

    expect(results.map { |r| [ r[:engine], r[:path] ] }).to eq([ [ "Web", "/s" ] ])
  end
end
