# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::RouteIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  # The booted answer for a route set drawn from source, the static answer for the same source in
  # config/routes.rb (no routes.rb when source is nil), and the set itself.
  def tiers(source)
    set = ActionDispatch::Routing::RouteSet.new.tap { |s| s.draw { instance_eval(source.to_s) } }
    booted = described_class.new(double("app", routes: set, routes_reloader: nil, root: Rails.root)).call
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "routes.rb"), "Rails.application.routes.draw do\n#{source}end\n") if source
      [ booted, described_class.new(RailsAiContext::StaticApp.new(dir)).static_call, set ]
    end
  end

  describe "#call" do
    subject(:result) { introspector.call }

    it "reads the endpoints of a mounted Grape API from its source, as the static tier does" do
      api = File.join(Rails.root, "app/api/booted_grape.rb")
      FileUtils.mkdir_p(File.dirname(api))
      File.write(api, "class BootedGrape < Grape::API\n  prefix :api\n  get(:ping) { }\nend\n")
      allow(introspector).to receive(:detect_mounted_engines).and_return([ { engine: "BootedGrape", path: "/g" } ])

      expect(result[:grape_endpoints]).to eq("BootedGrape" => [ { verb: "GET", path: "/g/api/ping", params: [], file: "app/api/booted_grape.rb" } ])
    ensure
      FileUtils.rm_rf(File.join(Rails.root, "app/api"))
    end

    it "counts total routes" do
      expect(result[:total_routes]).to be > 0
    end

    it "groups routes by controller" do
      expect(result[:by_controller]).to have_key("users")
      expect(result[:by_controller]).to have_key("posts")
    end

    it "extracts HTTP verbs and paths" do
      user_routes = result[:by_controller]["users"]
      expect(user_routes).to include(a_hash_including(verb: "GET", path: "/users"))
    end

    it "returns api_namespaces as an array" do
      expect(result[:api_namespaces]).to be_an(Array)
    end

    it "returns mounted_engines as an array" do
      expect(result[:mounted_engines]).to be_an(Array)
    end
  end

  # `get "/", to: redirect("https://example.com")` is routable and has no
  # controller#action, so no row and no count mentioned it while
  # `bin/rails routes` listed it.
  describe "a booted route with no controller" do
    # Drawn rather than constructed: `Redirect.new`'s arity is Rails' own
    # business and changed in 8.1, while `redirect(...)` in a route set is the
    # way an app writes one in every version.
    let(:route_set) do
      ActionDispatch::Routing::RouteSet.new.tap do |set|
        set.draw do
          get "/", to: redirect("https://example.com")
          get "orders" => "orders#index"
        end
      end
    end

    let(:app_double) { double("app", routes: route_set, routes_reloader: nil, root: Rails.root) }

    it "counts it as a construct the route list does not expand" do
      result = described_class.new(app_double).call

      expect(result[:dynamic_routes]).to eq(1)
      expect(result[:unrouted_mounts]).to eq(0)
      # The routed half still answers, so the redirect is the only thing the
      # count is about.
      expect(result[:by_controller].keys).to eq([ "orders" ])
    end
  end

  # The static tier lists what an app draws into an engine; booted, the
  # engine's own table holds it, read under the mount like `bin/rails routes`.
  describe "a booted app that mounts an engine" do
    # Anonymous, and named only for the example: a named engine class stays
    # in Rails::Engine.subclasses for the rest of the run, and the engines
    # section of every later context then lists it.
    let(:engine) { Class.new(::Rails::Engine) }

    before do
      allow(engine).to receive(:name).and_return("PauShop::Engine")
      engine.routes.draw { resources :products, only: [ :index, :update ] }
    end

    # Railtie#subclasses leaves out abstract railties, so the class is retired
    # even before it is garbage collected.
    after { engine.define_singleton_method(:abstract_railtie?) { true } }

    let(:route_set) do
      mounted = engine
      ActionDispatch::Routing::RouteSet.new.tap do |set|
        set.draw do
          get "orders" => "orders#index"
          scope "/store" do
            mount mounted, at: "/shop", as: "storefront"
          end
          mount mounted, at: "/shop2", as: "storefront2"
        end
      end
    end

    let(:app_double) { double("app", routes: route_set, routes_reloader: nil, root: Rails.root) }

    it "lists the engine's table under its mount and proxy, apart from the app's count" do
      result = described_class.new(app_double).call

      expect(result[:total_routes]).to eq(1)
      expect(result[:engine_routes]).to match([ a_hash_including(
        engine: "PauShop::Engine", mount: "/store/shop", whole_table: true, also_mounted_at: [ "/shop2" ],
        routes: contain_exactly(
          a_hash_including(verb: "GET", path: "/store/shop/products", controller: "products", action: "index",
                           name: "storefront.products"),
          a_hash_including(verb: "PATCH|PUT", path: "/store/shop/products/:id", action: "update")
        )
      ) ])
    end
  end

  # `mount` is `match(path, to: app, via: :all, anchor: false)`, so both forms
  # build the same endpoint. Keeping only Rails::Engine subclasses left every
  # plain Rack app counted in the header and named nowhere.
  describe "a booted route set with Rack apps attached" do
    before do
      stub_const("MetricsApp", Class.new { def self.call(_env) = [ 200, {}, [ "ok" ] ] })
      stub_const("MetricsAdminApp", Class.new { def self.call(_env) = [ 200, {}, [ "ok" ] ] })
    end

    let(:route_set) do
      ActionDispatch::Routing::RouteSet.new.tap do |set|
        set.draw do
          match "/metrics", to: MetricsApp, via: :all, as: :metrics_app
          mount MetricsAdminApp => "/metrics-admin"
          get "orders" => "orders#index"
        end
      end
    end

    let(:app_double) { double("app", routes: route_set, routes_reloader: nil, root: Rails.root) }

    it "names both endpoints and the path each answers on" do
      result = described_class.new(app_double).call

      expect(result[:mounted_engines]).to contain_exactly(
        { engine: "MetricsApp", path: "/metrics" },
        { engine: "MetricsAdminApp", path: "/metrics-admin" }
      )
    end

    # The header count and the list have to describe the same set: the count
    # included a Rack app attached as an instance, and the list held classes
    # only, so one line of output disagreed with the next.
    it "names an endpoint attached as an instance too" do
      server = Class.new { def call(_env) = [ 200, {}, [ "ok" ] ] }
      stub_const("Propshaft::Server", server)
      set = ActionDispatch::Routing::RouteSet.new
      set.draw { mount Propshaft::Server.new => "/assets" }
      result = described_class.new(double("app", routes: set, routes_reloader: nil, root: Rails.root)).call

      expect(result[:mounted_engines].map { |m| m[:path] }).to include("/assets")
      expect(result[:unrouted_mounts]).to eq(result[:mounted_engines].size)
    end

    it "carries the condition config/routes.rb mounts an app under, as the static tier does" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            mount MetricsApp => "/metrics" if Rails.env.development?
            mount MetricsAdminApp => "/metrics-admin"
          end
        RUBY
        set = ActionDispatch::Routing::RouteSet.new
        set.draw do
          mount MetricsApp => "/metrics"
          mount MetricsAdminApp => "/metrics-admin"
        end
        result = described_class.new(double("app", routes: set, routes_reloader: nil, root: Pathname(dir))).call

        expect(result[:mounted_engines]).to contain_exactly(
          { engine: "MetricsApp", path: "/metrics", condition: "if Rails.env.development?" },
          { engine: "MetricsAdminApp", path: "/metrics-admin" }
        )
      end
    end

    # `rails routes` prints a mounted app's inspect, which for a module is its name.
    it "names a module mounted as a Rack app by the module, as the static tier does" do
      stub_const("API", Module.new { def self.call(_env) = [ 200, {}, [ "ok" ] ] })
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), "Rails.application.routes.draw do\n  mount API => \"/api\"\nend\n")
        set = ActionDispatch::Routing::RouteSet.new
        set.draw { mount API => "/api" }

        booted = described_class.new(double("app", routes: set, routes_reloader: nil, root: Pathname(dir))).call[:mounted_engines]
        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:mounted_engines]

        expect(booted).to eq([ { engine: "API", path: "/api" } ])
        expect(static).to eq([ { engine: "API", path: "/api" } ])
      end
    end

    # Booted Rails mounts the Builder the constant holds and names it by its class.
    it "lists a mount of a Rack app a constant the file builds where booted Rails mounts one, named as booted names it" do
      booted, static, = tiers("BUILT_APP = Rack::Builder.new { run ->(_env) { [ 200, {}, [ \"ok\" ] ] } }\nmount BUILT_APP, at: \"/b\"\n")

      expect(booted.slice(:mounted_engines, :dynamic_routes)).to eq(mounted_engines: [ { engine: "Rack::Builder", path: "/b" } ])
      expect(static.slice(:mounted_engines, :dynamic_routes)).to eq(mounted_engines: [ { engine: "Rack::Builder", path: "/b" } ])
    end

    # Booted, the routes section reads the source for mount conditions and the
    # engines section reads it for its mount list: one run walks it once.
    it "walks the route files once for the routes and engines sections of one run" do
      Dir.mktmpdir do |dir|
        routes_rb = File.join(dir, "config", "routes.rb")
        FileUtils.mkdir_p(File.dirname(routes_rb))
        File.write(routes_rb, "Rails.application.routes.draw do\n  mount MetricsApp => \"/metrics\" if Rails.env.development?\nend\n")
        set = ActionDispatch::Routing::RouteSet.new
        set.draw { mount MetricsApp => "/metrics" }
        app = double("app", routes: set, routes_reloader: nil, root: Pathname(dir))
        allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk).and_call_original

        engines = RailsAiContext::RunCache.around do
          described_class.new(app).call
          RailsAiContext::Introspectors::EngineIntrospector.new(app).call[:mounted_engines]
        end

        expect(engines).to eq([ { engine: "MetricsApp", path: "/metrics", condition: "if Rails.env.development?" } ])
        expect(RailsAiContext::Introspectors::SourceIntrospector).to have_received(:walk).with(routes_rb, anything).once
      end
    end

    # Source names a mount by what it wrote (`MetricsApp.new`, a computed
    # path) and the live table by the class and the drawn path, so an exact
    # match missed both and booted printed the mount as unconditional.
    describe "a conditional mount the live table names differently" do
      def booted_mounts(routes_rb, &draw)
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config", "routes.rb"), "Rails.application.routes.draw do\n#{routes_rb}end\n")
          set = ActionDispatch::Routing::RouteSet.new
          set.draw(&draw)
          described_class.new(double("app", routes: set, routes_reloader: nil, root: Pathname(dir))).call[:mounted_engines]
        end
      end

      before do
        stub_const("MetricsInstanceApp", Class.new { def call(_env) = [ 200, {}, [ "ok" ] ] })
        stub_const("FlagsUI", Module.new { def self.app(*) = Rack::Builder.new { run ->(_env) { [ 200, {}, [ "ok" ] ] } } })
      end

      it "takes the condition of the one mount at a computed path" do
        mounts = booted_mounts(%(  mount MetricsApp, at: ENV.fetch("METRICS_PATH", "/metrics") if Rails.env.development?\n)) do
          mount MetricsApp => "/metrics"
        end

        expect(mounts).to eq([ { engine: "MetricsApp", path: "/metrics", condition: "if Rails.env.development?" } ])
      end

      it "takes the condition of the one mount at that path for an instance" do
        mounts = booted_mounts(%(  mount MetricsInstanceApp.new => "/m" if Rails.env.development?\n)) do
          mount MetricsInstanceApp.new => "/m"
        end

        expect(mounts).to eq([ { engine: "MetricsInstanceApp", path: "/m", condition: "if Rails.env.development?" } ])
      end

      it "takes the condition of the one mount at that path for a factory call" do
        mounts = booted_mounts(%(  mount FlagsUI.app(:flags) => "/flags" unless Rails.env.production?\n)) do
          mount FlagsUI.app(:flags) => "/flags"
        end

        expect(mounts).to eq([ { engine: "Rack::Builder", path: "/flags", condition: "unless Rails.env.production?" } ])
      end

      # Static merges the two into one pathless entry with the conditions
      # joined, and neither live mount drew under both.
      it "attaches no condition when one app is mounted at two computed paths" do
        routes_rb = <<~RUBY
          mount MetricsApp, at: ENV.fetch("A_PATH", "/a") if Rails.env.development?
          mount MetricsApp, at: ENV.fetch("B_PATH", "/b"), as: :metrics_two unless Rails.env.production?
        RUBY
        mounts = booted_mounts(routes_rb) do
          mount MetricsApp => "/a"
          mount MetricsApp => "/b", as: :metrics_two
        end

        expect(mounts).to contain_exactly({ engine: "MetricsApp", path: "/a" }, { engine: "MetricsApp", path: "/b" })
      end

      it "attaches no condition when two mounts share the path" do
        routes_rb = <<~RUBY
          if ENV["LIVE"]
            mount FlagsUI.app(:live) => "/live"
          else
            mount FlagsUI.app(:poll) => "/live"
          end
        RUBY
        mounts = booted_mounts(routes_rb) { mount FlagsUI.app(:live) => "/live" }

        expect(mounts).to eq([ { engine: "Rack::Builder", path: "/live" } ])
      end

      it "takes the condition of the mount of that app when two share the path" do
        routes_rb = <<~RUBY
          if ENV["LIVE"]
            mount MetricsInstanceApp.new => "/live"
          else
            mount FlagsUI.app(:poll) => "/live"
          end
        RUBY
        mounts = booted_mounts(routes_rb) { mount MetricsInstanceApp.new => "/live" }

        expect(mounts).to eq([ { engine: "MetricsInstanceApp", path: "/live", condition: 'if ENV["LIVE"]' } ])
      end

      it "keeps an exact match ahead of the path, conditional or not" do
        routes_rb = <<~RUBY
          mount MetricsApp => "/a" if Rails.env.development?
          mount MetricsApp => "/a2", as: :metrics_two
        RUBY
        mounts = booted_mounts(routes_rb) do
          mount MetricsApp => "/a"
          mount MetricsApp => "/a2", as: :metrics_two
        end

        expect(mounts).to contain_exactly(
          { engine: "MetricsApp", path: "/a", condition: "if Rails.env.development?" },
          { engine: "MetricsApp", path: "/a2" }
        )
      end
    end

    it "counts them as the mounts they are, and leaves the controller route alone" do
      result = described_class.new(app_double).call

      expect(result[:unrouted_mounts]).to eq(2)
      expect(result[:by_controller].keys).to eq([ "orders" ])
    end
  end

  # The mount listener names `match "/x", to: SomeApp` as a mounted Rack app,
  # so the routes listener must not also count it as a construct it could not
  # expand: the header said "1 dynamic construct not expanded" about an
  # endpoint named two lines further down.
  describe "a Rack app attached with a verb and a constant to: on the static tier" do
    it "counts it once, as a mount" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            match "/metrics", to: MetricsApp, via: :all
            get "/health", to: Health::App
            mount MetricsAdminApp => "/metrics-admin"
            mount ActionCable.server => "/cable"
            get "/status" => StatusApp
            get "orders" => "orders#index"
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:unrouted_mounts]).to eq(5)
        expect(result[:mounted_engines]).to include({ engine: "ActionCable.server", path: "/cable" }, { engine: "StatusApp", path: "/status" })
        expect(result[:dynamic_routes]).to be_nil
        expect(result[:by_controller].keys).to eq([ "orders" ])
      end
    end
  end

  # Both tiers answer the same question, so they answer it with the same rule.
  describe "api namespaces on both tiers" do
    let(:route_set) do
      ActionDispatch::Routing::RouteSet.new.tap do |set|
        set.draw do
          namespace :api do
            resources :users, only: [ :index ]
          end
          namespace :admin do
            namespace :api do
              namespace :v1 do
                resources :reports, only: [ :index ]
              end
            end
          end
        end
      end
    end

    let(:routes_source) do
      <<~RUBY
        Rails.application.routes.draw do
          namespace :api do
            resources :users, only: [:index]
          end
          namespace :admin do
            namespace :api do
              namespace :v1 do
                resources :reports, only: [:index]
              end
            end
          end
        end
      RUBY
    end

    it "reports the same namespaces booted and static" do
      app_double = double("app", routes: route_set, routes_reloader: nil, root: Rails.root)
      booted = described_class.new(app_double).call

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), routes_source)
        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(booted[:api_namespaces]).to eq([ "/api" ])
        expect(static[:api_namespaces]).to eq(booted[:api_namespaces])
      end
    end
  end

  describe "route constraints on both tiers" do
    let(:routes_source) do
      <<~'RUBY'
        constraints subdomain: "api" do
          get "/status", to: "status#show"
        end
        get "/photos/:id", to: "photos#show", constraints: { id: /[A-Z]\d{5}/ }
        resources :items, only: [:index, :show], constraints: { id: /\d+/ }
        scope defaults: { format: :json } do
          get "/feed", to: "feed#index", constraints: { flavor: "x", protocol: "https" }
        end
        get "/loose", to: "loose#show", constraints: ->(req) { true }
      RUBY
    end

    def constraints_of(result)
      result[:by_controller].transform_values { |rows| rows.map { |r| [ r[:path], r[:constraints] ] } }
    end

    it "lists what bin/rails routes prints beside each route, the same booted and static" do
      booted, static = both_tiers(routes_source)

      expect(booted).to eq(
        "status" => [ [ "/status", '{subdomain: "api"}' ] ],
        "photos" => [ [ "/photos/:id", '{id: /[A-Z]\d{5}/}' ] ],
        "items" => [ [ "/items", nil ], [ "/items/:id", '{id: /\d+/}' ] ],
        "feed" => [ [ "/feed", '{protocol: "https", format: :json}' ] ],
        "loose" => [ [ "/loose", nil ] ]
      )
      expect(static).to eq(booted)
    end

    def both_tiers(source)
      tiers(source).first(2).map { |result| constraints_of(result) }
    end

    it "lists a resource's block routes before its own, in the order Rails matches them, on both tiers" do
      booted, static = tiers("resources :heroes do\n  collection { get :search }\n  member { post :promote }\nend\n")
      rows = ->(result) { result[:by_controller]["heroes"].map { |r| "#{r[:verb]} #{r[:path]}" } }

      expect(rows.(booted)).to eq([
        "GET /heroes/search", "POST /heroes/:id/promote", "GET /heroes", "POST /heroes", "GET /heroes/new",
        "GET /heroes/:id/edit", "GET /heroes/:id", "PATCH /heroes/:id", "PUT /heroes/:id", "DELETE /heroes/:id"
      ])
      expect(rows.(static)).to eq(rows.(booted))
    end

    it "names the root route on both tiers when GET / also answers another verb, or any verb" do
      [ "match \"/\", to: \"pages#home\", via: [:get, :post]\n", "root \"pages#home\", via: :all\n" ].each do |source|
        booted, static = tiers(source)

        expect([ booted[:root_route], static[:root_route] ]).to eq([ "pages#home", "pages#home" ]), source
      end
    end

    it "lists a glob segment among a route's params on both tiers, as Rails requires it" do
      booted, static, set = tiers("get \"docs/*section\", to: \"pages#doc\", as: :doc\n")

      expect(set.routes.first.required_parts).to eq([ :section ])
      expect([ booted, static ].map { |r| r[:by_controller]["pages"].first[:params] }).to eq([ [ "section" ], [ "section" ] ])
    end

    it "gives a nested resource's parent param the parent's own param constraint, as Rails does" do
      booted, static = both_tiers(<<~'RUBY')
        resources :accounts, only: :show, constraints: { id: /-?\d+/ } do
          resources :statuses, only: :show do
            resources :likes, only: :index
          end
          member { get :foo }
        end
        resources :users, only: [], param: :name, name: /[a-z]+/ do
          resources :posts, only: :index
        end
        scope "/p", id: /[a-z]+/ do
          resources :boards, only: :show do
            resources :cards, only: :index
          end
        end
      RUBY

      expect(booted["statuses"]).to eq([ [ "/accounts/:account_id/statuses/:id", '{id: /-?\d+/, account_id: /-?\d+/}' ] ])
      expect(static).to eq(booted)
    end

    it "lists an option Rails does not know as the route's default, as Rails does" do
      booted, static = both_tiers(<<~'RUBY')
        resources :boards, only: :show do
          member do
            get "details/:work_package_id(/:tab)", action: :split_view, defaults: { tab: :overview }, as: :details,
                work_package_split_view: true
          end
        end
        get "x/:wp", to: "x#show", flag: true, constraints: { wp: /\d+/ }, defaults: { tab: :o }
        scope "/s", foo: :bar do
          get "y", to: "y#show", baz: 1, foo: "own"
        end
        resources :things, only: :index, mode: "ro"
        namespace :admin, level: 2 do
          get "z", to: "z#show"
        end
      RUBY

      expect(booted["boards"]).to include([ "/boards/:id/details/:work_package_id(/:tab)", "{tab: :overview, work_package_split_view: true}" ])
      expect(static).to eq(booted)
    end
  end

  describe "#static_call" do
    def multi_path_routes(railties)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), "Rails.application.routes.draw do\n  get \"/a\", \"/b\", to: \"pages#show\"\nend\n")
        File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    railties (#{railties})\n") if railties
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        [ result[:by_controller].fetch("pages", []).map { |r| r[:path] }, result[:dynamic_routes] ]
      end
    end

    it "answers an app with no config/routes.rb as no routes, as the booted tier does, not as an error" do
      booted, static = tiers(nil)

      expect(static).not_to have_key(:error)
      expect(static.slice(*booted.keys)).to eq(booted)
      expect(static[:note]).to start_with("No route file to parse")
    end

    it "draws every path of a multi-path route only when the lockfile pins Rails below 8.1" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      expect(multi_path_routes("8.0.2")).to eq([ [ "/a", "/b" ], nil ])
      expect(multi_path_routes("8.1.0")).to eq([ [], 1 ])
      expect(multi_path_routes(nil)).to eq([ [], 1 ])
    end

    # Mapper#mount names a mount its `as:`, else an engine's railtie_name (the isolated namespace here, wiki_engine for
    # one that isolates none) or a class's name underscored, so a later route asking for that name gets none. Before 8.1
    # `as: nil` falls back to that name too; 8.1 leaves the mount unnamed. A gem engine's file is not here to say.
    it "takes the name Rails gives a mount from the engine's file, the class and the Rails version, and none it cannot read" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      named = lambda do |railties|
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "lib", "blog"))
          FileUtils.mkdir_p(File.join(dir, "lib", "wiki"))
          File.write(File.join(dir, "lib", "blog", "engine.rb"), "module Blog\n  class Engine < ::Rails::Engine\n    isolate_namespace Blog\n  end\nend\n")
          File.write(File.join(dir, "lib", "wiki", "engine.rb"), "module Wiki\n  class Engine < ::Rails::Engine\n  end\nend\n")
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
            Rails.application.routes.draw do
              mount Blog::Engine => "/blog"
              mount Wiki::Engine => "/wiki"
              mount Forum::Engine => "/forum"
              mount HealthCheck, at: "/hc", as: nil
              get "blog", to: "pages#a"
              get "blog_engine", to: "pages#b"
              get "wiki_engine", to: "pages#c"
              get "forum_engine", to: "pages#d"
              get "health_check", to: "pages#e"
            end
          RUBY
          File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    railties (#{railties})\n")
          described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:by_controller]["pages"].to_h { |r| [ r[:action], r[:name] ] }
        end
      end

      expect(named.call("8.1.0")).to eq("a" => nil, "b" => "blog_engine", "c" => nil, "d" => "forum_engine", "e" => "health_check")
      expect(named.call("8.0.2")).to eq("a" => nil, "b" => "blog_engine", "c" => nil, "d" => "forum_engine", "e" => nil)
    end

    # A live RouteSet attaches each app where it draws a route at that path: a resource block's own routes sit in its
    # nested scope, a member's at the record, a collection's and a singular resource's at the resource.
    it "lists a Rack app attached inside a resource at the path Rails attaches it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            resources :posts do
              mount NestedApp, at: "hc"
              member { mount MemberApp => "hc" }
              collection { mount CollectionApp, at: "/hc" }
              match "stats", to: StatsApp, via: :all
            end
            resource :profile do
              mount ProfileApp, at: "hc"
            end
            namespace :admin do
              resources :users, shallow: true do
                resources :posts do
                  mount ShallowApp, at: "hc"
                end
              end
            end
          end
        RUBY

        mounts = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:mounted_engines].to_h { |m| [ m[:engine], m[:path] ] }

        expect(mounts).to eq("NestedApp" => "/posts/:post_id/hc", "MemberApp" => "/posts/:id/hc", "CollectionApp" => "/posts/hc",
                             "StatsApp" => "/posts/:post_id/stats", "ProfileApp" => "/profile/hc", "ShallowApp" => "/admin/posts/:post_id/hc")
      end
    end

    # A live RouteSet attaches both apps at /posts/:post_id/hc, with RES = :posts, where the walk cannot read the
    # resource; an app inside a block the walk does not draw in place may sit anywhere under the resource.
    it "lists no path for a Rack app inside a resource the walk cannot place" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          RES = :posts
          Rails.application.routes.draw do
            resources RES do
              mount UnreadApp, at: "hc"
            end
            resources :posts do
              api_block do
                mount BlockApp, at: "hc"
              end
            end
          end
        RUBY

        mounts = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:mounted_engines].to_h { |m| [ m[:engine], m[:path] ] }

        expect(mounts).to eq("UnreadApp" => nil, "BlockApp" => nil)
      end
    end

    # Inside `module Admin`, Ruby finds UI in Admin's own constants first, and the app keeps Admin::UI in a file of its own.
    it "names a mounted app by the constant Ruby picks where the mount is written" do
      routes = "module Admin\n  Rails.application.routes.draw do\n    mount UI => \"/ui\"\n  end\nend\n"
      ui = "module Admin\n  class UI\n    def self.call(_env) = [ 200, {}, [] ]\n  end\nend\n"

      expect(static_mounts_of(routes, "app/lib/admin/ui.rb" => ui)).to eq([ [ "Admin::UI", "/ui" ] ])
      expect(static_mounts_of(routes)).to eq([ [ "UI", "/ui" ] ])
    end

    def mounted_engines_of(routes, files = {})
      Dir.mktmpdir do |dir|
        { "config/routes.rb" => routes, **files }.each do |path, source|
          FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
          File.write(File.join(dir, path), source)
        end
        described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:mounted_engines]
      end
    end

    # Inside class Admin < Panel, Ruby finds UI in Panel after Admin's own constants, before the top level.
    it "names a mounted app by a constant the enclosing class inherits" do
      routes = "class Panel\nend\n\nclass Admin < Panel\n  Rails.application.routes.draw do\n    mount UI => \"/ui\"\n  end\nend\n"
      ui = "class Panel\n  class UI\n    def self.call(_env) = [ 200, {}, [] ]\n  end\nend\n"

      expect(static_mounts_of(routes, "app/lib/panel/ui.rb" => ui, "app/lib/ui.rb" => "class UI\nend\n")).to eq([ [ "Panel::UI", "/ui" ] ])
    end

    def static_mounts_of(routes, files = {})
      mounted_engines_of(routes, files).map { |m| [ m[:engine], m[:path] ] }
    end

    # A live RouteSet (Rails 7.0.10 and 8.1.4) runs a concern's block at each site that applies it, so each app in it
    # is attached once per site at that site's path. One never applied, or applied only in a file another `draw`
    # reads, has no site this walk sees.
    it "lists a Rack app inside a concern at each site that applies it" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          concern :checked do
            mount TopApp, at: "hc"
            get "hc2", to: RouteApp
          end
          concern :unused do
            mount UnusedApp, at: "u"
          end
          concern :elsewhere do
            mount DrawnApp => "/d"
          end
          concerns :checked
          namespace :admin do
            concerns :checked
          end
          resources :posts, only: [], concerns: :checked
          resources :users, only: [] do
            concerns :checked
          end
          draw :extra
        end
      RUBY

      expect(static_mounts_of(routes, "config/routes/extra.rb" => "concerns :elsewhere\n")).to eq(
        [ [ "UnusedApp", nil ], [ "DrawnApp", nil ],
          [ "TopApp", "/hc" ], [ "RouteApp", "/hc2" ], [ "TopApp", "/admin/hc" ], [ "RouteApp", "/admin/hc2" ],
          [ "TopApp", "/posts/:post_id/hc" ], [ "RouteApp", "/posts/:post_id/hc2" ],
          [ "TopApp", "/users/:user_id/hc" ], [ "RouteApp", "/users/:user_id/hc2" ] ]
      )
    end

    # Live, a routes-file method draws at each call, with arguments or without, a literal list's block once per
    # element and a block given to `resources :aa, :bb` once per name.
    it "lists a Rack app in a method, a loop or a multi-name resource at each place Rails draws it" do
      routes = <<~'RUBY'
        Rails.application.routes.draw do
          def health_routes
            mount MethodApp, at: "hc"
          end
          def arg_routes(x)
            mount ArgsApp, at: "args"
          end
          health_routes
          namespace :admin do
            health_routes
          end
          arg_routes(1)
          %w[a b].each do |v|
            mount LoopApp, at: v, as: "loop_#{v}"
            get "g/#{v}", to: LoopRouteApp
          end
          %i[c d].each do |v|
            namespace v do
              mount ScopedLoopApp, at: "hc"
            end
          end
          %w[e f].each do |v|
            scope path: v, as: v do
              mount PathLoopApp, at: "hc"
            end
          end
          resources :aa, :bb, only: [] do
            mount NamesApp, at: "x", as: "names"
          end
        end
      RUBY

      expect(static_mounts_of(routes)).to eq(
        [ [ "MethodApp", "/hc" ], [ "MethodApp", "/admin/hc" ], [ "ArgsApp", "/args" ],
          [ "LoopApp", "/a" ], [ "LoopRouteApp", "/g/a" ], [ "LoopApp", "/b" ], [ "LoopRouteApp", "/g/b" ],
          [ "ScopedLoopApp", "/c/hc" ], [ "ScopedLoopApp", "/d/hc" ], [ "PathLoopApp", "/e/hc" ], [ "PathLoopApp", "/f/hc" ],
          [ "NamesApp", "/aa/:aa_id/x" ], [ "NamesApp", "/bb/:bb_id/x" ] ]
      )
    end

    # A live RouteSet (7.0.10 and 8.1.4) attaches the mount at /adm/hc: the body runs where it is called.
    it "lists a Rack app a method called with arguments mounts under the caller's namespace" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          def status_mount(name)
            mount StatusApp => "/hc", as: name
          end

          namespace :adm do
            status_mount(:adm_status)
          end
        end
      RUBY

      expect(static_mounts_of(routes)).to eq([ [ "StatusApp", "/adm/hc" ] ])
    end

    # Live, the concern's block keeps the mapper its `tap` handed it, wherever it is applied.
    it "reads a mapper block's parameter in a concern applied outside that block" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          tap { |r| r.concern(:checked) { r.mount TapApp, at: "hc" } }
          concerns :checked
        end
      RUBY

      expect(static_mounts_of(routes)).to eq([ [ "TapApp", "/hc" ] ])
    end

    # The concern's `recorder` is the local beside it, not the `tap` parameter of that name at the site: live draws nothing.
    it "reads a replayed concern's locals in the scopes it was written in" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          recorder = Recorder.new
          concern :checked do
            recorder.mount KeptApp, at: "kept"
          end
          tap do |recorder|
            concerns :checked
          end
        end
      RUBY

      expect(static_mounts_of(routes)).to eq([])
    end

    # Live, each pass names its mount (blog_a, blog_b, c_wiki, d_wiki), which names the engine's route proxy.
    it "names an engine mounted in a loop by the name each pass gives it" do
      routes = <<~'RUBY'
        Blog::Engine.routes.draw do
          get "p", to: "posts#index"
        end
        Wiki::Engine.routes.draw do
          get "w", to: "pages#index"
        end
        Rails.application.routes.draw do
          %w[a b].each do |v|
            mount Blog::Engine, at: v, as: "blog_#{v}"
          end
          %w[c d].each do |v|
            namespace v do
              mount Wiki::Engine, at: "wiki"
            end
          end
        end
      RUBY

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), routes)
        engines = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:engine_routes]
        expect(engines.map { |e| [ e[:engine], e[:mount], e[:also_mounted_at], e[:routes].map { |r| [ r[:path], r[:name] ] } ] }).to eq(
          [ [ "Blog::Engine", "/a", [ "/b" ], [ [ "/a/p", "blog_a.p" ] ] ],
            [ "Wiki::Engine", "/c/wiki", [ "/d/wiki" ], [ [ "/c/wiki/w", "c_wiki.w" ] ] ] ]
        )
      end
    end

    it "marks an app a concern attaches under a condition at the site or in its body" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          concern :checked do
            mount TopApp, at: "hc"
            mount InnerApp, at: "in" if ENV["IN"]
          end
          if ENV["SITE"]
            namespace :admin do
              concerns :checked
            end
          end
        end
      RUBY

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), routes)
        expect(described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:mounted_engines]).to eq(
          [ { engine: "TopApp", path: "/admin/hc", condition: 'if ENV["SITE"]' },
            { engine: "InnerApp", path: "/admin/in", condition: 'if ENV["SITE"] and if ENV["IN"]' } ]
        )
      end
    end

    # Live (Rails 7.0.10 and 8.1.4), the site applies the definition the arm that ran made: with A unset Sidekiq::Web at
    # /b, with A=1 HealthCheck at /a; the same mount in both arms is at /a either way.
    it "lists an app at the site once per arm that defines the concern or method, under that arm's condition" do
      concern = <<~RUBY
        Rails.application.routes.draw do
          if ENV["A"]
            concern :adm do
              mount HealthCheck, at: "a"
            end
          else
            concern :adm do
              mount Sidekiq::Web, at: "b"
            end
          end
          concerns :adm
        end
      RUBY
      method = <<~RUBY
        Rails.application.routes.draw do
          if ENV["A"]
            def admin
              mount HealthCheck, at: "a"
            end
          else
            def admin
              mount Sidekiq::Web, at: "b"
            end
          end
          admin
        end
      RUBY

      both_arms = <<~RUBY
        Rails.application.routes.draw do
          if ENV["A"]
            concern :adm do
              mount HealthCheck, at: "a"
            end
          else
            concern :adm do
              mount HealthCheck, at: "a"
            end
          end
          namespace :n do
            concerns :adm
          end
        end
      RUBY

      expected = [ { engine: "HealthCheck", path: "/a", condition: 'if ENV["A"]' }, { engine: "Sidekiq::Web", path: "/b", condition: 'unless ENV["A"]' } ]
      expect(mounted_engines_of(concern)).to eq(expected)
      expect(mounted_engines_of(method)).to eq(expected)
      expect(mounted_engines_of(both_arms)).to eq([ { engine: "HealthCheck", path: "/n/a" } ])
    end

    # Live, a replaced definition draws nothing (only /b); the walk reads it where it is written, as it does one never applied.
    it "keeps an app in a concern a later definition replaces before any site applies it" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          concern :adm do
            mount HealthCheck, at: "a"
          end
          concern :adm do
            mount Sidekiq::Web, at: "b"
          end
          concerns :adm
        end
      RUBY

      expect(static_mounts_of(routes)).to eq([ [ "HealthCheck", nil ], [ "Sidekiq::Web", "/b" ] ])
    end

    # Live, the app is drawn only when the site's branch ran and the definition's branch had run before it.
    it "marks an app a replay draws with the site's condition, then its definition's, then its own" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          if ENV["A"]
            if ENV["B"]
              concern :adm do
                mount HealthCheck, at: "a" unless ENV["E"]
              end
            end
          end
          unless ENV["C"]
            concerns :adm if ENV["D"]
          end
          unless ENV["F"]
            def admin
              mount Sidekiq::Web, at: "b"
            end
            admin
          end
          if ENV["G"]
            def other
              mount OtherApp, at: "o"
            end
          end
          other if ENV["G"]
        end
      RUBY

      expect(mounted_engines_of(routes)).to eq(
        [ { engine: "HealthCheck", path: "/a", condition: 'unless ENV["C"] and if ENV["D"] and if ENV["A"] and if ENV["B"] and unless ENV["E"]' },
          { engine: "Sidekiq::Web", path: "/b", condition: 'unless ENV["F"]' },
          { engine: "OtherApp", path: "/o", condition: 'if ENV["G"]' } ]
      )
    end

    # Live, /a is drawn only with A=1, /b only with A unset and /x only with F unset (with F=1 the call raises NameError).
    it "marks a route a replay draws with its definition's condition" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          if ENV["A"]
            concern :adm do
              get "a", to: "pages#a"
            end
          else
            concern :adm do
              get "b", to: "pages#b"
            end
          end
          concerns :adm
          unless ENV["F"]
            def extra
              get "x", to: "pages#x"
            end
          end
          extra
        end
      RUBY

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), routes)
        pages = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:by_controller]["pages"]
        expect(pages.map { |r| [ r[:path], r[:condition] ] }).to eq([ [ "/a", 'if ENV["A"]' ], [ "/b", 'unless ENV["A"]' ], [ "/x", 'unless ENV["F"]' ] ])
      end
    end

    # Live (Rails 7.0.10 and 8.1.4), a route in either arm takes its name from those taken before the site: /a or /b
    # n=x, /h n=h, /things n=things either way, and the second /pre is unnamed. /z is unnamed only on the run whose
    # arm mounted the app it takes its name from (A=1), and the walk, which lists both arms, leaves it unnamed.
    it "names each arm's routes of a replayed definition from the names taken before the site" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          get "pre", to: "pages#pre"
          if ENV["A"]
            concern :adm do
              get "a", to: "pages#a", as: :x
              mount HealthCheck, at: "hc", as: :z
            end
            def extra
              get "h", to: "pages#h"
              get "pre", to: "pages#pre2"
              resources :things
            end
          else
            concern :adm do
              get "b", to: "pages#b", as: :x
            end
            def extra
              get "h", to: "pages#h2"
              resources :things, only: :index
            end
          end
          concerns :adm
          extra
          get "z", to: "pages#z"
        end
      RUBY

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), routes)
        by_controller = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:by_controller]
        expect(by_controller["pages"].map { |r| [ r[:action], r[:name] ] }).to eq(
          [ %w[pre pre], %w[a x], %w[b x], %w[h h], [ "pre2", nil ], %w[h2 h], [ "z", nil ] ]
        )
        expect(by_controller["things"].select { |r| r[:action] == "index" }.map { |r| r[:name] }).to eq(%w[things things])
      end
    end

    # Live (Rails 7.0.10 and 8.1.4), a definition a later one under one if/unless replaces is in force only when that
    # branch did not run: /a with A unset and /b with A=1; the first call is before the later def, so /x either way,
    # then /s/x with A=1 and /s/y with A unset; /c only with B unset, as the later def under `if ENV["B"]` replaces it.
    it "marks a definition a later one under one if/unless may replace with the opposite of that branch" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          concern :adm do
            get "a", to: "pages#a"
          end
          if ENV["A"]
            concern :adm do
              get "b", to: "pages#b"
            end
          end
          concerns :adm
          def extra
            get "x", to: "pages#x"
          end
          extra
          unless ENV["A"]
            def extra
              get "y", to: "pages#y"
            end
          end
          scope "s" do
            extra
          end
          unless ENV["A"]
            concern :other do
              get "c", to: "pages#c"
            end
          end
          if ENV["B"]
            concern :other do
              get "d", to: "pages#d"
            end
          end
          concerns :other
        end
      RUBY

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), routes)
        pages = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:by_controller]["pages"]
        expect(pages.map { |r| [ r[:path], r[:condition] ] }).to eq(
          [ [ "/a", 'unless ENV["A"]' ], [ "/b", 'if ENV["A"]' ], [ "/x", nil ], [ "/s/x", 'if ENV["A"]' ], [ "/s/y", 'unless ENV["A"]' ],
            [ "/c", 'unless ENV["A"] and unless ENV["B"]' ], [ "/d", 'if ENV["B"]' ] ]
        )
      end
    end

    # Live, /b with A=1 and /c with A unset: /a is never drawn, as each later branch replaces it on its run.
    it "replaces a definition by a later one under a branch that states the same condition in another block" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          concern :adm do
            get "a", to: "pages#a"
          end
          if ENV["A"]
            concern :adm do
              get "b", to: "pages#b"
            end
          end
          unless ENV["A"]
            concern :adm do
              get "c", to: "pages#c"
            end
          end
          concerns :adm
        end
      RUBY

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), routes)
        pages = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:by_controller]["pages"]
        expect(pages.map { |r| [ r[:path], r[:condition] ] }).to eq([ [ "/b", 'if ENV["A"]' ], [ "/c", 'unless ENV["A"]' ] ])
      end
    end

    # Ruby assigns a constant written in a concern's block once per application; applied once, it holds that value.
    it "reads a constant a replayed concern assigns once as written once" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          concern :checked do
            HELD = HeldApp
            mount HELD, at: "held"
            TARGET = "posts#index"
            get "x", to: TARGET
          end
          concerns :checked
        end
      RUBY

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), routes)
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result[:mounted_engines]).to eq([ { engine: "HeldApp", path: "/held" } ])
        expect(result[:by_controller]["posts"].map { |r| [ r[:path], r[:action] ] }).to eq([ [ "/x", "index" ] ])
      end
    end

    it "marks a mount drawn only under a condition, and not one both arms draw" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            if Rails.env.development?
              mount LetterOpenerWeb::Engine, at: "/letter_opener"
            end
            if ENV["JOBS"]
              mount GoodJob::Engine => "good_job"
            else
              mount GoodJob::Engine => "good_job"
            end
            mount Sidekiq::Web => "/sidekiq" unless Rails.env.test?
            if Rails.env.test?
              mount Flipper::UI.app => "/flipper"
            elsif ENV["FLIPPER"]
              mount Flipper::UI.app => "/flipper"
            end
            unless ENV["A"]
              mount PgHero::Engine => "/pghero"
            else
              mount PgHero::Engine => "/pghero"
            end
            if ENV["B"]
              mount Blazer::Engine => "/blazer"
            elsif ENV["C"]
              mount Blazer::Engine => "/blazer"
            else
              mount Blazer::Engine => "/blazer"
            end
          end
        RUBY
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:mounted_engines]).to contain_exactly(
          { engine: "LetterOpenerWeb::Engine", path: "/letter_opener", condition: "if Rails.env.development?" },
          { engine: "GoodJob::Engine", path: "/good_job" },
          { engine: "Sidekiq::Web", path: "/sidekiq", condition: "unless Rails.env.test?" },
          { engine: "Flipper::UI.app", path: "/flipper",
            condition: "if Rails.env.test? or unless Rails.env.test? and if ENV[\"FLIPPER\"]" },
          { engine: "PgHero::Engine", path: "/pghero" },
          { engine: "Blazer::Engine", path: "/blazer" }
        )
      end
    end

    it "reads the endpoints of a Grape API the routes mount" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "app", "api", "v1"))
        File.write(File.join(dir, "config", "routes.rb"), "Rails.application.routes.draw do\n  mount V1::Users => \"/api\"\nend\n")
        File.write(File.join(dir, "app", "api", "v1", "users.rb"), <<~RUBY)
          module V1
            class Users < Grape::API
              version "v1", using: :path
              resource(:users) { post { {} } }
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:grape_endpoints]).to eq("V1::Users" => [ { verb: "POST", path: "/api/v1/users", params: [], file: "app/api/v1/users.rb" } ])
      end
    end

    # RouteSet evaluates prepend blocks before the draw and append blocks after it.
    it "reads routes an initializer prepends or appends, in the order Rails draws them" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            get "main", to: "posts#index"
          end
        RUBY
        File.write(File.join(dir, "config", "initializers", "more_routes.rb"), <<~RUBY)
          Rails.application.routes.append do
            get "appended", to: "posts#index"
          end
          Rails.application.routes.prepend do
            get "prepended", to: "posts#index"
          end
        RUBY
        File.write(File.join(dir, "config", "initializers", "plain.rb"), "Rails.application.config.x.y = 1\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:by_controller]["posts"].map { |r| [ r[:name], r[:path] ] })
          .to eq([ %w[prepended /prepended], %w[main /main], %w[appended /appended] ])
        expect(result[:total_routes]).to eq(3)
        expect(result[:note]).to include("config/initializers/more_routes.rb")
        expect(result[:note]).not_to include("plain.rb")
      end
    end

    # Rails runs after_initialize (finisher_hook) before it draws the routes
    # (set_routes_reloader_hook), 7.0 to 8.1; another on_load hook may run after the draw.
    it "reads a prepend or append in after_initialize and counts one in another hook as not expanded" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "routes.rb"), "Rails.application.routes.draw do\n  get \"main\", to: \"posts#index\"\nend\n")
        File.write(File.join(dir, "config", "initializers", "late.rb"), <<~RUBY)
          Rails.application.config.after_initialize do
            Rails.application.routes.prepend do
              get "late", to: "posts#index"
            end
          end
          ActiveSupport.on_load(:after_initialize) do
            Rails.application.routes.append { get "later", to: "posts#index" }
          end
          ActiveSupport.on_load(:action_controller) do
            Rails.application.routes.append { get "hooked", to: "posts#index" }
          end
        RUBY
        File.write(File.join(dir, "config", "initializers", "more.rb"), <<~RUBY)
          Rails.application.routes.prepend { get "first", to: "posts#index" }
          Rails.application.routes.append { get "appended", to: "posts#index" }
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:by_controller]["posts"].map { |r| r[:path] }).to eq(%w[/first /late /main /appended /later])
        expect(result[:dynamic_routes]).to eq(1)
      end
    end

    it "skips an initializer that cannot be parsed or links outside the app" do
      Dir.mktmpdir do |dir|
        app = File.join(dir, "app")
        FileUtils.mkdir_p(File.join(app, "config", "initializers"))
        File.write(File.join(app, "config", "routes.rb"), "Rails.application.routes.draw do\n  get \"main\", to: \"posts#index\"\nend\n")
        File.binwrite(File.join(app, "config", "initializers", "broken.rb"), "Rails.application.routes.append do\n  get \"\xff\", to:\n")
        File.write(File.join(dir, "outside.rb"), "Rails.application.routes.append do\n  get \"leak\", to: \"leak#index\"\nend\n")
        File.symlink(File.join(dir, "outside.rb"), File.join(app, "config", "initializers", "outside.rb"))
        File.symlink(File.join(app, "config", "initializers"), File.join(app, "config", "initializers", "loop"))

        result = described_class.new(RailsAiContext::StaticApp.new(app)).static_call

        expect(result[:by_controller].keys).not_to include("leak")
        expect(result[:by_controller]["posts"].first[:path]).to eq("/main")
      end
    end

    # `rails plugin new shop --mountable`: the engine's table is the project's whole route surface.
    it "reads a mountable engine's own table as the routes, from the engine's root" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "lib", "shop"))
        File.write(File.join(dir, "lib", "shop", "engine.rb"), "module Shop\n  class Engine < ::Rails::Engine\n    isolate_namespace Shop\n  end\nend\n")
        File.write(File.join(dir, "config", "routes.rb"), "Shop::Engine.routes.draw do\n  resources :widgets\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:total_routes]).to eq(7)
        expect(result[:by_controller]["shop/widgets"].map { |r| [ r[:verb], r[:path], r[:name] ] }).to include(
          [ "GET", "/widgets", "widgets" ], [ "GET", "/widgets/:id", "widget" ]
        )
        expect(result).not_to have_key(:engine_routes)
      end
    end

    it "reads an engine whose namespace does not underscore back to its path as the project's table" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "lib", "pghero"))
        File.write(File.join(dir, "lib", "pghero", "engine.rb"), "module PgHero\n  class Engine < ::Rails::Engine\n    isolate_namespace PgHero\n  end\nend\n")
        File.write(File.join(dir, "config", "routes.rb"), "PgHero::Engine.routes.draw do\n  resources :queries\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:total_routes]).to eq(7)
        expect(result).not_to have_key(:engine_routes)
      end
    end

    it "keeps the condition a route is drawn under" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            get "dev_only", to: "posts#index" if Rails.env.development?
          end
        RUBY

        posts = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:by_controller]["posts"]

        expect(posts).to eq([ { verb: "GET", path: "/dev_only", action: "index", name: "dev_only", restful: true,
                                condition: "if Rails.env.development?", position: 0 } ])
      end
    end

    it "numbers every route in draw order across controllers" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            get "a", to: "posts#index"
            get "b", to: "pages#show"
            get "c", to: "posts#show"
          end
        RUBY

        table = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:by_controller]

        expect(RailsAiContext::RouteCoverage.table(by_controller: table).map { |r| [ r[:controller], r[:path] ] })
          .to eq([ [ "posts", "/a" ], [ "pages", "/b" ], [ "posts", "/c" ] ])
      end
    end

    it "builds the runtime output shape from config/routes.rb without booting" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            root "welcome#index"
            resources :posts, only: [:index, :show]
            namespace :api do
              namespace :v1 do
                resources :widgets, only: [:index]
              end
            end
            mount Sidekiq::Web, at: "/sidekiq"
            devise_for :users
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:total_routes]).to eq(4)
        expect(result[:by_controller].keys).to contain_exactly("welcome", "posts", "api/v1/widgets")
        post_routes = result[:by_controller]["posts"]
        expect(post_routes).to include(
          a_hash_including(verb: "GET", path: "/posts", action: "index", restful: true)
        )
        expect(result[:api_namespaces]).to eq([ "/api/v1" ])
        expect(result[:mounted_engines]).to eq([ { engine: "Sidekiq::Web", path: "/sidekiq" } ])
        expect(result[:root_route]).to eq("welcome#index")
        expect(result[:confidence]).to eq("[STATIC]")
        expect(result[:dynamic_routes]).to eq(1)
      end
    end

    # An app can list its route files in config.paths["config/routes.rb"]; reading
    # config/routes.rb alone answered 69 routes of ~260 and none of its mounts.
    it "reads the route files config/application.rb registers, in order" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "routes"))
        File.write(File.join(dir, "config", "application.rb"), <<~RUBY)
          module Shop
            class Application < Rails::Application
              config.paths["config/routes.rb"] = %w(
                config/routes/api.rb
                config/routes.rb
                config/routes/admin.rb
              ).map { |relative_path| Rails.root.join(relative_path) }
            end
          end
        RUBY
        File.write(File.join(dir, "config", "routes.rb"), "Rails.application.routes.draw do\n  resources :posts, only: [:index]\nend\n")
        File.write(File.join(dir, "config", "routes", "api.rb"), <<~RUBY)
          Rails.application.routes.draw do
            namespace :api do
              resources :orders, only: [:index]
            end
            mount Rswag::Ui::Engine => "/api-docs"
          end
        RUBY
        File.write(File.join(dir, "config", "routes", "admin.rb"), <<~RUBY)
          Rails.application.routes.draw do
            namespace :admin do
              resources :orders, only: [:index]
            end
          end
        RUBY

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        result = introspector.static_call

        expect(result[:total_routes]).to eq(3)
        expect(result[:by_controller].keys).to contain_exactly("posts", "api/orders", "admin/orders")
        expect(result[:mounted_engines]).to eq([ { engine: "Rswag::Ui::Engine", path: "/api-docs" } ])
        expect(introspector.static_mounts.map { |m| m[:engine] }).to eq([ "Rswag::Ui::Engine" ])
        expect(result[:note]).to include("config/routes/api.rb")
      end
    end

    # An app can mount Sidekiq::Web in both arms of an if/else, inside a
    # `scope path: nil`: one app at one path, with the path known.
    it "names a mount once per app and path, with the path a nil scope leaves" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            scope path: nil, constraints: { format: /.*/ } do
              if Rails.env.development?
                mount Sidekiq::Web => "/sidekiq"
              else
                mount Sidekiq::Web => "/sidekiq", constraints: AdminConstraint.new
              end
            end
            mount Flipper::UI.app(Flipper) => "/flags"
            mount Flipper::UI.app(Flipper), at: "/admin/flags"
          end
        RUBY

        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        result = introspector.static_call

        expect(result[:mounted_engines]).to eq([
          { engine: "Sidekiq::Web", path: "/sidekiq" },
          { engine: "Flipper::UI.app", path: "/flags" },
          { engine: "Flipper::UI.app", path: "/admin/flags" }
        ])
        expect(introspector.static_mounts.size).to eq(3)
      end
    end

    # The booted tier reads Rails.application.routes, which holds a mounted
    # engine's routes only as the mount. The routes an app draws into an
    # engine are listed with the engine, under the path it is mounted at,
    # named through its route proxy, and left out of the app's count.
    it "files routes drawn into an engine under its mount, apart from the app's" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            resources :posts, only: [:index]
            mount Shop::Core::Engine, at: "/shop"
          end

          Shop::Core::Engine.routes.draw do
            namespace :admin do
              resources :orders, only: [:index]
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:total_routes]).to eq(1)
        expect(result[:by_controller].keys).to eq([ "posts" ])
        expect(result[:engine_routes]).to match([ a_hash_including(
          engine: "Shop::Core::Engine", mount: "/shop",
          routes: [ a_hash_including(verb: "GET", path: "/shop/admin/orders", controller: "shop/admin/orders",
                                     action: "index", name: "shop.admin_orders") ]
        ) ])
      end
    end

    # A gem engine draws its own table in the gem, which only boot reads, so
    # the section names it as unread rather than dropping it.
    it "names a mounted engine whose own table it cannot read" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?
            mount PgHero::Engine, at: "/pghero", as: :pghero
            mount Sidekiq::Web, at: "/sidekiq"
          end
        RUBY

        groups = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:engine_routes]

        expect(groups).to contain_exactly(
          { engine: "LetterOpenerWeb::Engine", mount: "/letter_opener", routes: [], unavailable: a_string_including("booted") },
          { engine: "PgHero::Engine", mount: "/pghero", routes: [], unavailable: a_string_including("booted") }
        )
      end
    end

    it "says an engine mounted at a computed path is mounted" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            mount PgHero::Engine, at: ENV.fetch("PGHERO_PATH", "/pghero")
          end
        RUBY

        groups = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:engine_routes]

        expect(groups).to contain_exactly(a_hash_including(engine: "PgHero::Engine", mount_computed: true))
        expect(groups.first).not_to have_key(:mount)
      end
    end

    it "decides from the app's own definition whether a mounted constant is an engine" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "lib", "metrics"))
        FileUtils.mkdir_p(File.join(dir, "lib", "billing"))
        File.write(File.join(dir, "lib", "metrics", "engine.rb"), "module Metrics\n  class Engine\n    def self.call(env) = [200, {}, []]\n  end\nend\n")
        File.write(File.join(dir, "lib", "billing", "engine.rb"), "module Billing\n  class Engine < ::Rails::Engine\n  end\nend\n")
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            mount Metrics::Engine, at: "/metrics"
            mount Billing::Engine, at: "/billing"
          end
        RUBY

        groups = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:engine_routes]

        expect(groups.map { |g| g[:engine] }).to eq([ "Billing::Engine" ])
      end
    end

    # The app's table merges each update's PATCH and PUT, so an engine's
    # count beside it merges them too.
    it "merges an engine route's PATCH and PUT the way the app count does" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            mount Shop::Core::Engine, at: "/"
          end

          Shop::Core::Engine.routes.draw do
            resources :orders, only: [:update]
          end
        RUBY

        routes = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:engine_routes].first[:routes]

        expect(routes.map { |r| [ r[:verb], r[:path] ] }).to eq([ [ "PATCH|PUT", "/orders/:id" ] ])
      end
    end

    it "reads an in-repo engine's routes after another section walked the same route files in the run" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "engines", "shop", "lib", "shop"))
        FileUtils.mkdir_p(File.join(dir, "engines", "shop", "config"))
        FileUtils.mkdir_p(File.join(dir, "engines", "shop", "app", "controllers", "shop"))
        File.write(File.join(dir, "engines", "shop", "shop.gemspec"), "")
        File.write(File.join(dir, "engines", "shop", "lib", "shop", "engine.rb"),
                   "module Shop\n  class Engine < ::Rails::Engine\n    isolate_namespace Shop\n  end\nend\n")
        File.write(File.join(dir, "engines", "shop", "config", "routes.rb"),
                   "Shop::Engine.routes.draw do\n  resources :orders, only: [:index, :show]\nend\n")
        File.write(File.join(dir, "config", "routes.rb"),
                   "Rails.application.routes.draw do\n  mount Shop::Engine, at: \"/shop\"\n  resources :posts, only: :index\nend\n")
        app = RailsAiContext::StaticApp.new(dir)

        groups = RailsAiContext::RunCache.around do
          described_class.new(app).static_mounts
          2.times.map { described_class.new(app).static_call[:engine_routes] }
        end

        groups.each do |engine_routes|
          expect(engine_routes.map { |g| [ g[:engine], g[:routes].map { |r| [ r[:path], r[:name] ] }, g[:unavailable] ] })
            .to eq([ [ "Shop::Engine", [ [ "/shop/orders", "shop.orders" ], [ "/shop/orders/:id", "shop.order" ] ], nil ] ])
        end
      end
    end

    # Rails names an engine's route proxy after the mount's `as:`, else the
    # engine's engine_name; any other name raises NameError when called.
    it "names the route proxy the way Rails names the mount" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "lib", "blog"))
        File.write(File.join(dir, "lib", "blog", "engine.rb"), <<~RUBY)
          module Blog
            class Engine < ::Rails::Engine
              isolate_namespace Blog
            end
          end
        RUBY
        FileUtils.mkdir_p(File.join(dir, "lib", "wiki"))
        File.write(File.join(dir, "lib", "wiki", "engine.rb"), "module Wiki\n  class Engine < ::Rails::Engine\n  end\nend\n")
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            mount ::Shop::Engine, at: "/shop", as: "storefront"
            mount Blog::Engine => "/blog"
            mount Wiki::Engine => "/wiki"
          end

          Shop::Engine.routes.draw { resources :products, only: [:index] }
          Blog::Engine.routes.draw { resources :posts, only: [:index] }
          Wiki::Engine.routes.draw { resources :pages, only: [:index] }
        RUBY

        groups = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:engine_routes]

        expect(groups.flat_map { |g| g[:routes].map { |r| r[:name] } }).to contain_exactly(
          "storefront.products", "blog.posts", "wiki_engine.pages"
        )
      end
    end

    # A devise_for drawn into an engine's table is missing from the engine's
    # count as it would be from the app's, and says so there.
    it "counts what an engine draw could not expand with that engine" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            mount Shop::Core::Engine, at: "/"
          end

          Shop::Core::Engine.routes.draw do
            devise_for :shop_user
            resources :orders, only: [:index]
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:engine_routes].first[:dynamic_routes]).to eq(1)
        expect(result).not_to have_key(:dynamic_routes)
      end
    end

    it "names every path an engine is mounted at" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            mount Blog::Engine, at: "/blog"
            mount Blog::Engine, at: "/blog2", as: "blog2"
          end

          Blog::Engine.routes.draw { resources :posts, only: [:index] }
        RUBY

        group = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:engine_routes].first

        expect(group).to include(mount: "/blog", also_mounted_at: [ "/blog2" ])
      end
    end

    it "says a route file list the app computes was not read" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "application.rb"),
                   "config.paths[\"config/routes.rb\"].concat(tenant_route_files)\n")
        File.write(File.join(dir, "config", "routes.rb"), "Rails.application.routes.draw do\n  resources :posts, only: [:index]\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:total_routes]).to eq(1)
        expect(result[:note]).to include("computes")
      end
    end

    # Rails registers PATCH and PUT separately for one update action, and every
    # surface that lists routes merges them. The static total did not, so the
    # generated files said "8 total" where rails_get_routes said 7 on the same
    # `resources :posts`.
    it "counts an update route once, the way the booted tier does" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            resources :posts
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        merged = result[:by_controller].values.sum do |actions|
          RailsAiContext::RouteCoverage.dedupe_put_patch_routes(actions).size
        end
        expect(result[:total_routes]).to eq(merged)
        expect(result[:total_routes]).to eq(7)
      end
    end

    it "files a concern's routes under the controller that serves them" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            concern :account_resources do
              scope module: :activitypub do
                resources :collections, only: [:show]
              end
            end

            resources :accounts, only: [], concerns: :account_resources
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:by_controller].keys).to eq([ "activitypub/collections" ])
        expect(result[:total_routes]).to eq(1)
        expect(result).not_to have_key(:dynamic_routes)
      end
    end

    # Each routes file is walked by its own listener, so a concern defined in
    # another file has no body to replay and has to stay a disclosed gap.
    it "counts a concern defined in a file it did not walk as unexpanded" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "routes"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            concern :account_resources do
              resources :collections, only: [:show]
            end
            draw(:admin)
          end
        RUBY
        File.write(File.join(dir, "config", "routes", "admin.rb"), <<~RUBY)
          resources :accounts, only: [], concerns: :account_resources
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:total_routes]).to eq(0)
        expect(result[:dynamic_routes]).to eq(1)
      end
    end

    # One app draws its API through `ApiRouteSet::V1.draw(self)`, whose class
    # prefixes each verb route's path and `as:` name.
    it "prefixes routes drawn through an app class with the prefixes the class returns" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "api_route_set.rb"), <<~RUBY)
          class ApiRouteSet
            def self.prefix
              raise ArgumentError, "prefix required"
            end

            def mapper_prefix
              ""
            end

            class V1 < ::ApiRouteSet
              def self.prefix
                "/api/v1"
              end

              def mapper_prefix
                "api_v1_"
              end
            end
          end
        RUBY
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            ApiRouteSet::V1.draw(self) do
              scope(controller: :courses) do
                get "courses", action: :index, as: "courses"
              end
            end
            ApiRouteSet.draw(self, "/api/lti") do
              post "tools/:tool_id/grade", controller: :lti_api, action: :grade, as: "lti_grade"
            end
            ApiRouteSet.draw(self) do
              get "orphans", controller: :orphans, action: :index
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        routes = result[:by_controller].flat_map { |c, entries| entries.map { |r| [ r[:path], "#{c}##{r[:action]}", r[:name] ] } }
        expect(routes).to contain_exactly(
          [ "/api/v1/courses", "courses#index", "api_v1_courses" ],
          [ "/api/lti/tools/:tool_id/grade", "lti_api#grade", "lti_grade" ]
        )
        expect(result[:dynamic_routes]).to eq(1)
      end
    end

    # An app that splits its routing table with `draw` keeps most of it in
    # config/routes/*.rb. Reading config/routes.rb alone answered 94 on a
    # 723-route app, with nothing saying the count was partial.
    describe "an app that draws its routes from other files" do
      def build_app(dir, main:, drawn: {})
        FileUtils.mkdir_p(File.join(dir, "config", "routes"))
        File.write(File.join(dir, "config", "routes.rb"), main)
        drawn.each do |name, source|
          path = File.join(dir, "config", "routes", "#{name}.rb")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, source)
        end
        described_class.new(RailsAiContext::StaticApp.new(dir))
      end

      let(:main) do
        <<~RUBY
          Rails.application.routes.draw do
            root "welcome#index"
            draw(:admin)
            devise_for :users
          end
        RUBY
      end

      let(:drawn) do
        { "admin" => <<~RUBY }
          namespace :admin do
            resources :reports, only: [:index, :show]
          end
        RUBY
      end

      it "counts the routes the drawn file defines" do
        Dir.mktmpdir do |dir|
          expect(build_app(dir, main: main, drawn: drawn).static_call[:total_routes]).to eq(3)
        end
      end

      it "attributes them to their own controller" do
        Dir.mktmpdir do |dir|
          result = build_app(dir, main: main, drawn: drawn).static_call
          expect(result[:by_controller].keys).to contain_exactly("welcome", "admin/reports")
        end
      end

      # The draw was expanded, so it is no longer one of the things missing.
      it "stops counting a draw it followed as unexpanded" do
        Dir.mktmpdir do |dir|
          expect(build_app(dir, main: main, drawn: drawn).static_call[:dynamic_routes]).to eq(1)
        end
      end

      it "names the files it read" do
        Dir.mktmpdir do |dir|
          expect(build_app(dir, main: main, drawn: drawn).static_call[:note])
            .to eq("Parsed statically from config/routes.rb and 1 file it draws (app not booted)")
        end
      end

      it "follows a draw nested inside another drawn file" do
        Dir.mktmpdir do |dir|
          nested = {
            "admin" => "draw(:reports)\n",
            "reports" => "get \"/reports\", to: \"reports#index\"\n"
          }
          expect(build_app(dir, main: main, drawn: nested).static_call[:total_routes]).to eq(2)
        end
      end

      # Rails runs the drawn file inside the mapper as it stands at the draw,
      # so the file's routes take the enclosing scope, and drawing it again
      # under another scope routes it again there, without the names the
      # first draw took (a live RouteSet leaves them nil).
      it "draws a file under each scope that draws it" do
        Dir.mktmpdir do |dir|
          scoped = <<~RUBY
            Rails.application.routes.draw do
              namespace :api, defaults: { format: "json" } do
                scope module: :v1 do
                  draw :api
                end
                scope module: :v0 do
                  draw :api
                end
              end
            end
          RUBY
          api = { "api" => <<~RUBY }
            resources :articles, only: [:show] do
              collection { get :search }
            end
            mount Sidekiq::Web => "sidekiq"
          RUBY
          result = build_app(dir, main: scoped, drawn: api).static_call

          routes = result[:by_controller].flat_map do |controller, entries|
            entries.map { |r| [ controller, r[:path], r[:name] ] }
          end
          expect(routes).to contain_exactly(
            [ "api/v1/articles", "/api/articles/search", "search_api_articles" ],
            [ "api/v1/articles", "/api/articles/:id", "api_article" ],
            [ "api/v0/articles", "/api/articles/search", nil ],
            [ "api/v0/articles", "/api/articles/:id", nil ]
          )
          expect(result[:mounted_engines]).to eq([ { engine: "Sidekiq::Web", path: "/api/sidekiq" } ])
          expect(result).not_to have_key(:dynamic_routes)
          expect(result[:note]).to include("1 file it draws")
        end
      end

      it "keeps counting a draw whose target file is absent" do
        Dir.mktmpdir do |dir|
          result = build_app(dir, main: main).static_call
          expect(result[:total_routes]).to eq(1)
          expect(result[:dynamic_routes]).to eq(2)
        end
      end

      it "keeps counting a draw whose target is not a literal" do
        Dir.mktmpdir do |dir|
          computed = "Rails.application.routes.draw do\n  draw(SECTION)\nend\n"
          expect(build_app(dir, main: computed, drawn: drawn).static_call[:dynamic_routes]).to eq(1)
        end
      end

      # The name reaches the resolver as source text, so it must not be able
      # to name a file outside config/routes/.
      it "refuses a target that climbs out of config/routes" do
        Dir.mktmpdir do |dir|
          escaping = "Rails.application.routes.draw do\n  draw(:\"../secrets\")\nend\n"
          introspector = build_app(dir, main: escaping)
          File.write(File.join(dir, "config", "secrets.rb"), "get \"/leak\", to: \"leak#index\"\n")
          result = introspector.static_call
          expect(result[:total_routes]).to eq(0)
          expect(result[:dynamic_routes]).to eq(1)
        end
      end

      # Coming back to a file already read is not a loss: its routes are in the
      # list. Only devise_for is genuinely unexpanded here.
      it "does not invent a caveat for a draw that closes a cycle" do
        Dir.mktmpdir do |dir|
          cycle = { "admin" => "get \"/a\", to: \"a#index\"\ndraw(:other)\n", "other" => "draw(:admin)\n" }
          result = build_app(dir, main: main, drawn: cycle).static_call
          expect(result[:dynamic_routes]).to eq(1)
        end
      end

      # Two files drawing the same third one is the ordinary shape, not a
      # cycle. The second draw is expanded because the first already read it.
      it "does not invent a caveat when two files draw the same one" do
        Dir.mktmpdir do |dir|
          diamond = "Rails.application.routes.draw do\n  draw(:admin)\n  draw(:api)\nend\n"
          drawn = {
            "admin" => "get \"/admin\", to: \"admin#index\"\ndraw(:shared)\n",
            "api" => "get \"/api\", to: \"api#index\"\ndraw(:shared)\n",
            "shared" => "get \"/shared\", to: \"shared#index\"\n"
          }
          result = build_app(dir, main: diamond, drawn: drawn).static_call
          expect(result[:total_routes]).to eq(3)
          expect(result[:dynamic_routes]).to be_nil
        end
      end

      # The depth cap does lose routes, so the caveat has to stay.
      it "still counts a draw the depth cap stopped" do
        Dir.mktmpdir do |dir|
          chain = (0..8).to_h { |i| [ "l#{i}", "get \"/l#{i}\", to: \"l#{i}#index\"\ndraw(:l#{i + 1})\n" ] }
          deep = "Rails.application.routes.draw do\n  draw(:l0)\nend\n"
          result = build_app(dir, main: deep, drawn: chain).static_call
          expect(result[:total_routes]).to be < chain.size
          expect(result[:dynamic_routes]).to be >= 1
        end
      end

      # config/routes.rb alone could always fail the whole section. Following
      # draws must not hand that power to every file it reads.
      it "keeps the routes it did parse when a drawn file cannot be" do
        Dir.mktmpdir do |dir|
          oversized = "# pad\n" * ((RailsAiContext::AstCache::MAX_PARSE_SIZE / 6) + 1)
          result = build_app(dir, main: main, drawn: { "admin" => oversized }).static_call

          expect(result[:error]).to be_nil
          expect(result[:total_routes]).to eq(1)
          expect(result[:dynamic_routes]).to eq(2)
        end
      end

      it "survives two files that draw each other" do
        Dir.mktmpdir do |dir|
          cycle = { "admin" => "draw(:other)\n", "other" => "draw(:admin)\n" }
          expect { build_app(dir, main: main, drawn: cycle).static_call }.not_to raise_error
        end
      end

      it "counts an in-repo engine's own routes.rb as a file it did not read" do
        Dir.mktmpdir do |dir|
          introspector = build_app(dir, main: "Rails.application.routes.draw do\n  resources :posts\nend\n")
          FileUtils.mkdir_p(File.join(dir, "plugins", "chat", "app", "models"))
          FileUtils.mkdir_p(File.join(dir, "plugins", "chat", "config"))
          FileUtils.touch(File.join(dir, "plugins", "chat", "plugin.rb"))
          File.write(File.join(dir, "plugins", "chat", "config", "routes.rb"),
                     "Chat::Engine.routes.draw do\n  resources :messages\nend\n")

          result = introspector.static_call

          expect(result[:in_repo_route_files]).to eq(1)
          expect(RailsAiContext::RouteCoverage.suffix(result))
            .to eq(", 1 in-repo engine route file not read, routes Rails' engines and gems draw at boot not read without booting")
        end
      end

      it "reads an in-repo routes.rb that appends to the app's own table into it" do
        Dir.mktmpdir do |dir|
          introspector = build_app(dir, main: "Rails.application.routes.draw do\n  resources :posts, only: [:index]\nend\n")
          { "web" => "Shop::Application.routes.append do\n  get \"/templates/:id\", to: \"web/templates#show\"\nend\n",
            "admin" => "Rails.application.routes.prepend do\n  get \"/health\", to: \"health#show\"\nend\n",
            "chat" => "Chat::Engine.routes.draw do\n  resources :messages\nend\n",
            "catalog" => "# Shop::Application.routes.append do\n# end\n" }.each do |name, source|
            FileUtils.mkdir_p(File.join(dir, "engines", name, "app", "models"))
            FileUtils.mkdir_p(File.join(dir, "engines", name, "config"))
            FileUtils.touch(File.join(dir, "engines", name, "#{name}.gemspec"))
            File.write(File.join(dir, "engines", name, "config", "routes.rb"), source)
          end

          result = introspector.static_call

          expect(result[:by_controller].keys).to include("posts", "web/templates", "health")
          expect(result[:total_routes]).to eq(3)
          expect(result[:in_repo_route_files]).to eq(1)
        end
      end

      it "reads a mounted in-repo engine's own routes.rb under its mount" do
        Dir.mktmpdir do |dir|
          introspector = build_app(dir, main: "Rails.application.routes.draw do\n  mount Feed::Engine, at: \"/feed\"\nend\n")
          %w[feed chat].each do |name|
            FileUtils.mkdir_p(File.join(dir, "engines", name, "app", "models"))
            FileUtils.mkdir_p(File.join(dir, "engines", name, "config"))
            FileUtils.mkdir_p(File.join(dir, "engines", name, "lib", name))
            File.write(File.join(dir, "engines", name, "lib", name, "engine.rb"),
                       "module #{name.capitalize}\n  class Engine < ::Rails::Engine\n  end\nend\n")
            File.write(File.join(dir, "engines", name, "config", "routes.rb"),
                       "#{name.capitalize}::Engine.routes.draw do\n  resources :addresses, only: [:show]\nend\n")
          end

          result = introspector.static_call
          group = result[:engine_routes].find { |g| g[:engine] == "Feed::Engine" }

          expect(group).not_to have_key(:unavailable)
          expect(group[:routes].map { |r| r[:path] }).to eq([ "/feed/addresses/:id" ])
          expect(result[:in_repo_route_files]).to eq(1)
        end
      end

      # expand_path folds `..` without following links, so a symlink under
      # config/routes/ was enough to read a file anywhere on disk.
      it "refuses a target that reaches outside through a symlink" do
        Dir.mktmpdir do |dir|
          sneaky = "Rails.application.routes.draw do\n  draw(:sneaky)\nend\n"
          introspector = build_app(dir, main: sneaky)
          File.write(File.join(dir, "outside.rb"), "get \"/leak\", to: \"leak#index\"\n")
          File.symlink(File.join(dir, "outside.rb"), File.join(dir, "config", "routes", "sneaky.rb"))

          result = introspector.static_call
          expect(result[:total_routes]).to eq(0)
          expect(result[:dynamic_routes]).to eq(1)
        end
      end
    end
  end
end
