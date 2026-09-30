# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::RouteIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

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

  describe "#static_call" do
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

    # OFN lists its route files in config.paths["config/routes.rb"]; reading
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

    # Discourse mounts Sidekiq::Web in both arms of an if/else, inside a
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
            mount Spree::Core::Engine, at: "/shop"
          end

          Spree::Core::Engine.routes.draw do
            namespace :admin do
              resources :orders, only: [:index]
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:total_routes]).to eq(1)
        expect(result[:by_controller].keys).to eq([ "posts" ])
        expect(result[:engine_routes]).to match([ a_hash_including(
          engine: "Spree::Core::Engine", mount: "/shop",
          routes: [ a_hash_including(verb: "GET", path: "/shop/admin/orders", controller: "spree/admin/orders",
                                     action: "index", name: "spree.admin_orders") ]
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
            mount Spree::Core::Engine, at: "/"
          end

          Spree::Core::Engine.routes.draw do
            resources :orders, only: [:update]
          end
        RUBY

        routes = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:engine_routes].first[:routes]

        expect(routes.map { |r| [ r[:verb], r[:path] ] }).to eq([ [ "PATCH|PUT", "/orders/:id" ] ])
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

    # A devise_for drawn into Spree's table is missing from the engine's
    # count as it would be from the app's, and says so there.
    it "counts what an engine draw could not expand with that engine" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            mount Spree::Core::Engine, at: "/"
          end

          Spree::Core::Engine.routes.draw do
            devise_for :spree_user
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

    # Canvas draws its API through `ApiRouteSet::V1.draw(self)`, whose class
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

    it "reports a missing routes.rb honestly" do
      Dir.mktmpdir do |dir|
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result[:error]).to include("config/routes.rb")
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
            .to eq(", 1 in-repo engine route file not read")
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
          introspector = build_app(dir, main: "Rails.application.routes.draw do\n  mount Dfc::Engine, at: \"/dfc\"\nend\n")
          %w[dfc chat].each do |name|
            FileUtils.mkdir_p(File.join(dir, "engines", name, "app", "models"))
            FileUtils.mkdir_p(File.join(dir, "engines", name, "config"))
            FileUtils.mkdir_p(File.join(dir, "engines", name, "lib", name))
            File.write(File.join(dir, "engines", name, "lib", name, "engine.rb"),
                       "module #{name.capitalize}\n  class Engine < ::Rails::Engine\n  end\nend\n")
            File.write(File.join(dir, "engines", name, "config", "routes.rb"),
                       "#{name.capitalize}::Engine.routes.draw do\n  resources :addresses, only: [:show]\nend\n")
          end

          result = introspector.static_call
          group = result[:engine_routes].find { |g| g[:engine] == "Dfc::Engine" }

          expect(group).not_to have_key(:unavailable)
          expect(group[:routes].map { |r| r[:path] }).to eq([ "/dfc/addresses/:id" ])
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
