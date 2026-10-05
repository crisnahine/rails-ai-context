# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::RoutesDslListener do
  def routes_for(source)
    listener = described_class.new
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(Prism.parse(source).value)
    listener.results
  end

  def route_records(source)
    routes_for(source).select { |r| r[:type] == :route }
  end

  it "expands plural resources into the seven RESTful actions plus PUT" do
    records = route_records('Rails.application.routes.draw do
      resources :posts
    end')
    expect(records.map { |r| [ r[:verb], r[:path], r[:action] ] }).to contain_exactly(
      [ "GET", "/posts", "index" ],
      [ "POST", "/posts", "create" ],
      [ "GET", "/posts/new", "new" ],
      [ "GET", "/posts/:id/edit", "edit" ],
      [ "GET", "/posts/:id", "show" ],
      [ "PATCH", "/posts/:id", "update" ],
      [ "PUT", "/posts/:id", "update" ],
      [ "DELETE", "/posts/:id", "destroy" ]
    )
    expect(records).to all(include(controller: "posts", restful: true))
  end

  # Ruby reads `api_v1_gift-cards_redeem_path` as a subtraction, and Rails
  # names that route `api_v1_gift_cards_redeem`.
  it "writes a path-derived name the way Rails does" do
    records = route_records(<<~RUBY)
      Rails.application.routes.draw do
        namespace :api do
          namespace :v1 do
            post 'gift-cards/redeem' => 'gift_cards#redeem'
          end
        end
      end
    RUBY

    expect(records.map { |r| r[:name] }).to eq([ "api_v1_gift_cards_redeem" ])
  end

  # A path with a character outside [\w\-/] contributes nothing to the name,
  # so a top-level one gets no name at all.
  it "leaves a dotted path out of the name" do
    records = route_records(<<~RUBY)
      Rails.application.routes.draw do
        get '/.well-known/oauth-authorization-server' => 'oauth#authorization_server'
        namespace :api do
          get '.well-known/jwks' => 'keys#jwks'
        end
      end
    RUBY

    expect(records.map { |r| r[:name] }).to eq([ nil, "api" ])
  end

  it "drops a generated name another route already took" do
    records = route_records(<<~RUBY)
      Rails.application.routes.draw do
        get 'health' => 'health#show'
        post 'health' => 'health#create'
      end
    RUBY

    expect(records.map { |r| r[:name] }).to eq([ "health", nil ])
  end

  it "honors only: and except:" do
    records = route_records('resources :posts, only: [:index, :show]')
    expect(records.map { |r| r[:action] }).to contain_exactly("index", "show")

    records = route_records('resources :posts, except: [:destroy]')
    expect(records.map { |r| r[:action] }).not_to include("destroy")
  end

  it "expands a singular resource without :id segments" do
    records = route_records('resource :profile, only: [:show, :update]')
    expect(records.map { |r| [ r[:verb], r[:path] ] }).to contain_exactly(
      [ "GET", "/profile" ], [ "PATCH", "/profile" ], [ "PUT", "/profile" ]
    )
    expect(records.first[:controller]).to eq("profiles")
  end

  it "applies namespace path, module, and name prefixes" do
    records = route_records('namespace :admin do
      resources :posts, only: [:index]
    end')
    expect(records.first).to include(
      path: "/admin/posts", controller: "admin/posts", action: "index", name: "admin_posts"
    )
  end

  # Rails' add_controller_module (actionpack mapper.rb, same in 7.0 and 8.1):
  # a controller starting with "/" drops the slash and takes no module prefix.
  # OpenProject writes 44 of these and every one read as a doubled namespace.
  it "treats a controller with a leading slash as absolute" do
    records = route_records('namespace :admin do
      namespace :settings do
        resource :work_packages_general, controller: "/admin/settings/work_packages_general", only: [:show]
      end
    end')

    expect(records.first[:controller]).to eq("admin/settings/work_packages_general")
    expect(records.first[:path]).to eq("/admin/settings/work_packages_general")
  end

  it "keeps prefixing a controller written without the leading slash" do
    records = route_records('namespace :admin do
      resource :profile, controller: "profiles", only: [:show]
    end')

    expect(records.first[:controller]).to eq("admin/profiles")
  end

  it "treats an absolute to: target as absolute too" do
    records = route_records('namespace :admin do
      get "ping", to: "/health#show"
    end')

    expect(records.first[:controller]).to eq("health")
  end

  it "nests resources under the parent param" do
    records = route_records('resources :posts do
      resources :comments, only: [:index, :create]
    end')
    nested = records.select { |r| r[:controller] == "comments" }
    expect(nested.map { |r| r[:path] }.uniq).to eq([ "/posts/:post_id/comments" ])
    expect(nested.first[:params]).to eq([ "post_id" ])
  end

  it "handles member and collection blocks" do
    records = route_records('resources :posts do
      member { get :preview }
      collection { get :archived }
    end')
    preview = records.find { |r| r[:action] == "preview" }
    archived = records.find { |r| r[:action] == "archived" }
    expect(preview).to include(verb: "GET", path: "/posts/:id/preview", controller: "posts")
    expect(archived).to include(verb: "GET", path: "/posts/archived", controller: "posts")
  end

  # OpenProject: `get :delete, action: :deletion_dialog` inside a member block.
  it "routes to the action an action: option names" do
    records = route_records('Rails.application.routes.draw do
      resources :items do
        member do
          get :delete, action: :deletion_dialog
          post :new_child, action: "create"
        end
      end
    end')
    expect(records.select { |r| r[:path].end_with?("delete", "new_child") }.map { |r| [ r[:path], r[:action] ] })
      .to contain_exactly([ "/items/:id/delete", "deletion_dialog" ], [ "/items/:id/new_child", "create" ])
  end

  it "handles on: :member and on: :collection keywords" do
    records = route_records('resources :posts do
      get :preview, on: :member
      get :archived, on: :collection
    end')
    expect(records.find { |r| r[:action] == "preview" }[:path]).to eq("/posts/:id/preview")
    expect(records.find { |r| r[:action] == "archived" }[:path]).to eq("/posts/archived")
  end

  it "parses bare verb routes with to:" do
    records = route_records('get "login", to: "sessions#new", as: :login')
    expect(records.first).to include(
      verb: "GET", path: "/login", controller: "sessions", action: "new", name: "login"
    )
  end

  it "parses hash-rocket verb routes (the Rails default health check)" do
    records = route_records('get "up" => "rails/health#show", as: :rails_health_check')
    expect(records.first).to include(
      verb: "GET", path: "/up", controller: "rails/health", action: "show", name: "rails_health_check"
    )
  end

  it "prefixes to: targets with the enclosing module" do
    records = route_records('namespace :api do
      get "status", to: "health#show"
    end')
    expect(records.first).to include(path: "/api/status", controller: "api/health")
  end

  it "parses root" do
    records = route_records('root "welcome#index"')
    expect(records.first).to include(verb: "GET", path: "/", controller: "welcome", action: "index", name: "root")

    records = route_records('root to: "welcome#index"')
    expect(records.first).to include(path: "/", controller: "welcome")
  end

  it "records a non-literal to: target as dynamic instead of guessing" do
    results = routes_for('resources :posts do
      get "legacy", to: redirect("/elsewhere")
    end')
    expect(results.none? { |r| r[:type] == :route && r[:action] == "legacy" }).to be(true)
    expect(results.select { |r| r[:type] == :dynamic }.map { |r| r[:macro] }).to include(:get)
  end

  it "records a slashed segment with non-literal to: as dynamic" do
    results = routes_for('get "admin/up", to: redirect("/status")')
    expect(results.none? { |r| r[:type] == :route }).to be(true)
    expect(results.first).to include(type: :dynamic, macro: :get)
  end

  it "applies scope path and module independently" do
    records = route_records('scope "/v2", module: :v2 do
      resources :posts, only: [:index]
    end')
    expect(records.first).to include(path: "/v2/posts", controller: "v2/posts")
  end

  it "suppresses routes inside concern definitions" do
    records = route_records('concern :commentable do
      resources :comments
    end
    resources :posts, only: [:index]')
    expect(records.map { |r| r[:controller] }.uniq).to eq([ "posts" ])
  end

  it "suppresses routes inside a namespace whose name isn't a literal, when it has a block" do
    results = routes_for('namespace Api::VERSION do
      resources :posts
    end')
    expect(results.none? { |r| r[:type] == :route }).to be(true)
    dynamic = results.select { |r| r[:type] == :dynamic }
    expect(dynamic.size).to eq(1)
    expect(dynamic.first[:macro]).to eq(:namespace)
  end

  it "suppresses routes inside resources whose name isn't a literal, when it has a block" do
    results = routes_for('resources Api::NAMES do
      member { get :extra }
    end')
    expect(results.none? { |r| r[:type] == :route }).to be(true)
    dynamic = results.select { |r| r[:type] == :dynamic }
    expect(dynamic.size).to eq(1)
    expect(dynamic.first[:macro]).to eq(:resources)
  end

  it "records dynamic constructs instead of guessing" do
    results = routes_for('devise_for :users
    resources Api::NAMES')
    dynamic = results.select { |r| r[:type] == :dynamic }
    expect(dynamic.map { |r| r[:macro] }).to include(:devise_for)
    expect(results.none? { |r| r[:type] == :route }).to be(true)
  end

  it "honors path: and controller: overrides on resources" do
    records = route_records('resources :posts, path: "articles", controller: "articles", only: [:index]')
    expect(records.first).to include(path: "/articles", controller: "articles")
  end

  it "ignores calls with an explicit receiver" do
    expect(routes_for('router.resources :posts')).to be_empty
  end

  it "replays a concern body where concerns: applies it" do
    records = route_records('Rails.application.routes.draw do
      concern :account_resources do
        scope module: :activitypub do
          resources :collections, only: [:show], as: :actor_collections
        end
      end

      resources :accounts, path: "users", only: [:show], param: :username, concerns: :account_resources
    end')
    expect(records.map { |r| [ r[:verb], r[:path], r[:controller], r[:action], r[:name] ] }).to include(
      [ "GET", "/users/:account_username/collections/:id", "activitypub/collections", "show", "account_actor_collection" ]
    )
  end

  it "replays a concern once per application site, under that site's prefix" do
    records = route_records('concern :commentable do
      resources :comments, only: [:index]
    end
    resources :posts, only: [], concerns: :commentable
    resources :photos, only: [], concerns: :commentable')
    expect(records.map { |r| r[:path] }).to contain_exactly(
      "/posts/:post_id/comments", "/photos/:photo_id/comments"
    )
  end

  it "replays a concern named by the bare concerns macro" do
    records = route_records('concern :commentable do
      resources :comments, only: [:index]
    end
    resources :posts, only: [] do
      concerns :commentable
    end')
    expect(records.map { |r| r[:path] }).to eq([ "/posts/:post_id/comments" ])
  end

  it "records a concern whose body this file cannot see as dynamic" do
    results = routes_for("resources :posts, only: [], concerns: :commentable")
    expect(results.none? { |r| r[:type] == :route }).to be(true)
    expect(results.map { |r| r[:macro] }).to eq([ :concerns ])
  end

  it "stops a concern that applies itself instead of recursing" do
    results = routes_for('concern :loop do
      concerns :loop
      resources :comments, only: [:index]
    end
    resources :posts, only: [], concerns: :loop')
    expect(results.select { |r| r[:type] == :route }.map { |r| r[:path] }).to eq([ "/posts/:post_id/comments" ])
    expect(results.count { |r| r[:type] == :dynamic }).to eq(1)
  end

  it "leaves no concern on the recursion guard when a replay raises" do
    listener = described_class.new
    raise_next_replay = true
    allow_any_instance_of(Prism::Dispatcher).to receive(:dispatch).and_wrap_original do |original, *args|
      if raise_next_replay && caller.any? { |line| line.include?("replay_concerns") }
        raise_next_replay = false
        raise "replay failed"
      end
      original.call(*args)
    end

    first = Prism.parse('concern :commentable do
      resources :comments, only: [:index]
    end
    resources :posts, only: [], concerns: :commentable').value
    expect {
      RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(first)
    }.to raise_error("replay failed")

    second = Prism.parse("resources :photos, only: [], concerns: :commentable").value
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(second)

    expect(listener.results.map { |r| r[:type] }).to eq([ :route ])
    expect(listener.results.first[:path]).to end_with("/photos/:photo_id/comments")
  end

  it "merges with_options defaults under each route's own options" do
    records = route_records('with_options to: "accounts#show" do
      get "/@:username", as: :short_account
      get "/@:username/featured"
      get "/@:username/about", to: "about#show"
    end')
    expect(records.map { |r| [ r[:path], r[:controller], r[:action] ] }).to contain_exactly(
      [ "/@:username", "accounts", "show" ],
      [ "/@:username/featured", "accounts", "show" ],
      [ "/@:username/about", "about", "show" ]
    )
  end

  it "merges with_options defaults into the resources inside it" do
    records = route_records('concern :batch do
      post :batch, on: :collection
    end
    with_options only: [:index], concerns: :batch do
      resources :links
    end')
    expect(records.map { |r| [ r[:verb], r[:path], r[:action] ] }).to contain_exactly(
      [ "GET", "/links", "index" ],
      [ "POST", "/links/batch", "batch" ]
    )
  end

  it "lets a with_options module: default override the namespace it wraps" do
    records = route_records('with_options module: :api do
      namespace :v1 do
        resources :posts, only: [:index]
      end
      scope :beta do
        resources :widgets, only: [:index]
      end
    end')
    expect(records.map { |r| [ r[:path], r[:controller] ] }).to contain_exactly(
      [ "/v1/posts", "api/api/posts" ],
      [ "/beta/widgets", "api/api/widgets" ]
    )
  end

  it "keeps an unreadable with_options target from inventing a controller" do
    results = routes_for('with_options to: redirect("/elsewhere") do
      get "/admin/settings"
    end')
    expect(results.none? { |r| r[:type] == :route }).to be(true)
  end

  it "records a with_options block that takes the merger as a parameter as dynamic" do
    results = routes_for('with_options(to: "accounts#show") do |m|
      m.get "/@:username"
    end')
    expect(results.none? { |r| r[:type] == :route }).to be(true)
    expect(results.map { |r| r[:macro] }).to eq([ :with_options ])
  end

  it "prefixes the controller with module: on a resource, and passes it to nested children" do
    records = route_records('namespace :admin do
      resources :announcements, only: [] do
        resource :distribution, only: [:create], module: :announcements
        resources :moderation_notes, only: [:index], module: :instances do
          resources :attachments, only: [:index]
        end
      end
    end')
    expect(records.map { |r| [ r[:path], r[:controller] ] }).to contain_exactly(
      [ "/admin/announcements/:announcement_id/distribution", "admin/announcements/distributions" ],
      [ "/admin/announcements/:announcement_id/moderation_notes", "admin/instances/moderation_notes" ],
      [ "/admin/announcements/:announcement_id/moderation_notes/:moderation_note_id/attachments",
        "admin/instances/attachments" ]
    )
  end

  it "renames route helpers with as: without moving the path or the controller" do
    records = route_records('resources :accounts, only: [] do
      resources :collections, only: [:show], as: :actor_collections
    end')
    expect(records.first).to include(
      path: "/accounts/:account_id/collections/:id",
      controller: "collections",
      name: "account_actor_collection"
    )
  end

  # Rails builds the collection helper from `as || name` as written, and
  # appends _index when that name is already singular.
  it "appends _index to a singular as: for the collection helper" do
    records = route_records('resources :photos, as: :image, only: [:index, :show]')
    expect(records.map { |r| [ r[:action], r[:name] ] }).to contain_exactly(
      [ "index", "image_index" ],
      [ "show", "image" ]
    )
  end

  it "keeps a plural as: as the collection helper" do
    records = route_records('resources :albums, as: :images, only: [:index, :show]')
    expect(records.map { |r| [ r[:action], r[:name] ] }).to contain_exactly(
      [ "index", "images" ],
      [ "show", "image" ]
    )
  end

  # Mastodon draws `resources :following, only: [:index]`, and Rails names its
  # index following_index.
  it "appends _index to a singular resource name" do
    records = route_records('resources :following, only: [:index], controller: :following_accounts')
    expect(records.map { |r| [ r[:action], r[:name] ] }).to contain_exactly(
      [ "index", "following_index" ]
    )
  end

  # collection_name appends _index when the name is already singular.
  it "names the collection helper of an uncountable resource with _index" do
    records = route_records('resources :sheep, only: [:index, :show]')
    expect(records.map { |r| [ r[:action], r[:name] ] }).to contain_exactly(
      [ "index", "sheep_index" ],
      [ "show", "sheep" ]
    )
  end

  # SingletonResource aliases collection_name to the singular, so a collection
  # route under a singular resource does not pluralize.
  it "keeps a singular resource's collection route singular" do
    records = route_records('resource :confirmation, only: [:create] do
      collection do
        post :resend
      end
    end')
    expect(records.map { |r| r[:name] }).to include("resend_confirmation")
  end

  it "uses param: for the member segment and the nested prefix" do
    records = route_records('resources :accounts, path: "users", only: [:show, :edit], param: :username do
      resources :statuses, only: [:index]
    end')
    expect(records.map { |r| r[:path] }).to contain_exactly(
      "/users/:username/edit",
      "/users/:username",
      "/users/:account_username/statuses"
    )
  end

  # Routes an app adds to an engine's table (`Spree::Core::Engine.routes.draw`)
  # reach the engine's controllers, Spree::Admin::OrdersController, not the
  # app's Admin::OrdersController.
  it "puts routes drawn into an engine under the engine's namespace" do
    results = routes_for(<<~RUBY)
      Shop::Application.routes.draw do
        namespace :admin do
          resources :orders, only: [:index]
        end
      end

      Spree::Core::Engine.routes.draw do
        namespace :admin do
          resources :orders, only: [:index]
        end
      end
    RUBY

    routes = results.select { |r| r[:type] == :route }
    expect(routes.map { |r| r[:controller] }).to contain_exactly("admin/orders", "spree/admin/orders")
    expect(routes.find { |r| r[:controller] == "spree/admin/orders" }[:engine]).to eq("Spree::Core::Engine")
    expect(routes.find { |r| r[:controller] == "admin/orders" }).not_to have_key(:engine)
  end

  # Rails draws one route per `match`, answering every verb in `via:` (the
  # booted tier reads it as "GET|POST"), and `via: :all` answers any verb.
  it "reads a match route with the verbs its via names" do
    results = routes_for(<<~RUBY)
      Rails.application.routes.draw do
        namespace :oauth do
          match "userinfo", via: [:get, :post], to: "userinfo#show"
        end
        match "/", via: [:post, :put, :patch, :delete], to: "application#raise_not_found"
        match "*unmatched_route", via: :all, to: "application#raise_not_found"
        match "computed", via: verbs_for_this, to: "pages#show"
      end
    RUBY

    routes = results.select { |r| r[:type] == :route }.map { |r| [ r[:verb], r[:path], "#{r[:controller]}##{r[:action]}" ] }
    expect(routes).to contain_exactly(
      [ "GET|POST", "/oauth/userinfo", "oauth/userinfo#show" ],
      [ "POST|PUT|PATCH|DELETE", "/", "application#raise_not_found" ],
      [ "ANY", "/*unmatched_route", "application#raise_not_found" ]
    )
    expect(results.count { |r| r[:type] == :dynamic && r[:macro] == :match }).to eq(1)
  end

  # Rails moves the slash in front of an optional segment inside it, so the
  # booted table reads "(/locale/:locale)/admin/posts", and a path made of
  # optional segments alone keeps its leading slash.
  it "writes a path under an optional scope the way Rails normalizes it" do
    records = route_records(<<~RUBY)
      Rails.application.routes.draw do
        scope "(/locale/:locale)" do
          namespace :admin do
            resources :posts, only: [:index]
          end
        end
        scope "(:locale)" do
          root "pages#home"
          get "about", to: "pages#about"
        end
      end
    RUBY

    expect(records.map { |r| r[:path] }).to contain_exactly(
      "(/locale/:locale)/admin/posts", "/(:locale)", "(/:locale)/about"
    )
  end

  # What a live RouteSet draws from the same block.
  it "routes to the controller a scope names, as Rails does" do
    records = route_records(<<~RUBY)
      Rails.application.routes.draw do
        scope(controller: :courses) do
          get "courses", action: :index, as: "courses"
          get "courses/:course_id/users", action: :users
          get "courses/:course_id/files", controller: :files, action: :api_index
          get "search"
          get "admin/reports"
          get "x/y", to: "a#b", action: :c
          get "courses/:course_id/unnamed"
        end
        namespace :admin do
          scope(controller: :things) do
            get "list", action: :list
          end
          namespace :settings do
            get "plugin/:id", action: :show_plugin, as: :show_plugin
          end
        end
        resources :posts, only: [] do
          scope(controller: :other) { get "preview", on: :member }
        end
      end
    RUBY

    expect(records.map { |r| [ r[:path], "#{r[:controller]}##{r[:action]}", r[:name] ] }).to contain_exactly(
      [ "/courses", "courses#index", "courses" ],
      [ "/courses/:course_id/users", "courses#users", nil ],
      [ "/courses/:course_id/files", "files#api_index", nil ],
      [ "/search", "courses#search", "search" ],
      [ "/admin/reports", "admin#reports", "admin_reports" ],
      [ "/x/y", "a#b", "x_y" ],
      [ "/admin/list", "admin/things#list", "admin_list" ],
      [ "/admin/settings/plugin/:id", "admin/settings#show_plugin", "admin_settings_show_plugin" ],
      [ "/posts/:id/preview", "other#preview", "preview_post" ]
    )
  end

  # `ApiRouteSet::V1.draw(self) do` hands the block to the app's own class,
  # which prefixes the path of each verb route and the name of each `as:`.
  describe "a route set the app draws through its own class" do
    def route_set_records(source, prefixes)
      listener = described_class.new(route_set: ->(name) { prefixes[name] })
      RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(Prism.parse(source).value)
      listener.results
    end

    let(:source) do
      <<~RUBY
        Rails.application.routes.draw do
          ApiRouteSet::V1.draw(self) do
            scope(controller: :courses) do
              get "courses", action: :index, as: "courses"
              put "courses/:id", action: :update
            end
            resources :groups, except: :index
            match "/api/v1/files/:id/create_success", via: [:options], controller: :files, action: :cors
          end
          ApiRouteSet.draw(self, "/api/lti") do
            post "/tools/:tool_id/grade", controller: :lti_api, action: :grade, as: "lti_grade"
          end
          Unknown::Set.draw(self) do
            get "things", controller: :things, action: :index
          end
        end
      RUBY
    end

    it "prefixes the path and name the class gives, and counts what it cannot place" do
      results = route_set_records(source, { "ApiRouteSet::V1" => { prefix: "/api/v1", name_prefix: "api_v1_" },
                                            "ApiRouteSet" => { name_prefix: "" } })

      routes = results.select { |r| r[:type] == :route }.map { |r| [ r[:verb], r[:path], "#{r[:controller]}##{r[:action]}", r[:name] ] }
      expect(routes).to contain_exactly(
        [ "GET", "/api/v1/courses", "courses#index", "api_v1_courses" ],
        [ "PUT", "/api/v1/courses/:id", "courses#update", nil ],
        [ "OPTIONS", "/api/v1/files/:id/create_success", "files#cors", nil ],
        [ "POST", "/api/lti/tools/:tool_id/grade", "lti_api#grade", "lti_grade" ]
      )
      # The class's own `resources` and a class whose prefix is unread.
      expect(results.select { |r| r[:type] == :dynamic }.map { |r| r[:macro] }).to contain_exactly(:resources, :route_set)
    end
  end

  it "takes a match route's verbs from an enclosing scope's via" do
    records = route_records(<<~RUBY)
      Rails.application.routes.draw do
        scope via: :all do
          match "/400", to: "admin/errors#bad_request"
          match "/404", to: "admin/errors#not_found", via: :get
        end
      end
    RUBY

    expect(records.map { |r| [ r[:verb], r[:path], r[:action] ] }).to contain_exactly(
      [ "ANY", "/400", "bad_request" ], [ "GET", "/404", "not_found" ]
    )
  end

  # Names checked against a live RouteSet: a singular resource draws create
  # last, so show keeps the name, and a member route takes the singular name
  # when show is not drawn.
  it "names resource routes in the order Rails draws them" do
    records = route_records(<<~RUBY)
      Rails.application.routes.draw do
        resource :profile
        resources :entries, only: [:index, :update]
        resource :status, only: [:create, :update]
      end
    RUBY

    expect(records.map { |r| [ r[:verb], r[:path], r[:action], r[:name] ] }).to eq([
      [ "GET", "/profile/new", "new", "new_profile" ],
      [ "GET", "/profile/edit", "edit", "edit_profile" ],
      [ "GET", "/profile", "show", "profile" ],
      [ "PATCH", "/profile", "update", nil ],
      [ "PUT", "/profile", "update", nil ],
      [ "DELETE", "/profile", "destroy", nil ],
      [ "POST", "/profile", "create", nil ],
      [ "GET", "/entries", "index", "entries" ],
      [ "PATCH", "/entries/:id", "update", "entry" ],
      [ "PUT", "/entries/:id", "update", nil ],
      [ "PATCH", "/status", "update", "status" ],
      [ "PUT", "/status", "update", nil ],
      [ "POST", "/status", "create", nil ]
    ])
  end

  it "names a root by its as:, under the enclosing names" do
    records = route_records(<<~RUBY)
      Rails.application.routes.draw do
        namespace :admin do
          scope :republishing do
            root to: "republishing#index", as: :republishing_index
          end
        end
        root to: "home#index"
      end
    RUBY

    expect(records.map { |r| r[:name] }).to eq(%w[admin_republishing_index root])
  end

  describe "shallow nesting, path_names, a new block, options in a variable and several paths" do
    def rows(source)
      route_records(source).map { |r| [ r[:verb], r[:path], "#{r[:controller]}##{r[:action]}", r[:name] ] }
    end

    it "draws a shallow child's member routes outside the parent, as Rails does" do
      drawn = rows(<<~RUBY)
        Rails.application.routes.draw do
          resources :articles, shallow: true do
            resources :comments
          end
        end
      RUBY

      expect(drawn).to include(
        [ "GET", "/articles/:article_id/comments", "comments#index", "article_comments" ],
        [ "GET", "/articles/:article_id/comments/new", "comments#new", "new_article_comment" ],
        [ "GET", "/comments/:id/edit", "comments#edit", "edit_comment" ],
        [ "GET", "/comments/:id", "comments#show", "comment" ],
        [ "DELETE", "/comments/:id", "comments#destroy", nil ]
      )
      expect(drawn.map { |r| r[1] }).not_to include("/articles/:article_id/comments/:id")
    end

    it "keeps a namespace's path and name on shallow routes, and nests the grandchild under its parent alone" do
      drawn = rows(<<~RUBY)
        Rails.application.routes.draw do
          namespace :admin do
            resources :posts, shallow: true do
              resources :notes do
                resources :tags, only: [:index, :show]
                member { get :pin }
              end
            end
          end
        end
      RUBY

      expect(drawn).to include(
        [ "GET", "/admin/posts/:post_id/notes", "admin/notes#index", "admin_post_notes" ],
        [ "GET", "/admin/notes/:id", "admin/notes#show", "admin_note" ],
        [ "GET", "/admin/notes/:id/pin", "admin/notes#pin", "pin_admin_note" ],
        [ "GET", "/admin/notes/:note_id/tags", "admin/tags#index", "admin_note_tags" ],
        [ "GET", "/admin/tags/:id", "admin/tags#show", "admin_tag" ]
      )
    end

    it "reads the shallow block form under a scope's path and as:" do
      drawn = rows(<<~RUBY)
        Rails.application.routes.draw do
          scope "/v1", as: "v1" do
            shallow do
              resources :books, only: [:index] do
                resources :pages, only: [:show, :index]
              end
            end
          end
        end
      RUBY

      expect(drawn).to contain_exactly(
        [ "GET", "/v1/books", "books#index", "v1_books" ],
        [ "GET", "/v1/books/:book_id/pages", "pages#index", "v1_book_pages" ],
        [ "GET", "/v1/pages/:id", "pages#show", "v1_page" ]
      )
    end

    it "adds nothing for a shallow_path the source computes" do
      drawn = rows(<<~RUBY)
        Rails.application.routes.draw do
          scope Config.prefix, shallow_path: Config.prefix do
            resources :posts, only: [] do
              resources :remarks, only: [:show], shallow: true
            end
          end
        end
      RUBY

      expect(drawn).to eq([ [ "GET", "/remarks/:id", "remarks#show", "remark" ] ])
    end

    it "takes the new and edit segments from path_names, on the resource or a scope" do
      drawn = rows(<<~RUBY)
        Rails.application.routes.draw do
          resources :photos, path_names: { new: "make", edit: "change" }
          scope path_names: { new: "neu" } do
            resources :cars, only: [:new]
          end
        end
      RUBY

      expect(drawn).to include(
        [ "GET", "/photos/make", "photos#new", "new_photo" ],
        [ "GET", "/photos/:id/change", "photos#edit", "edit_photo" ],
        [ "GET", "/cars/neu", "cars#new", "new_car" ]
      )
    end

    it "scopes a new block to the new path" do
      drawn = rows(<<~RUBY)
        Rails.application.routes.draw do
          resources :users, only: [:index, :show], param: :slug do
            new do
              get :preview
            end
          end
        end
      RUBY

      expect(drawn).to include([ "GET", "/users/new/preview", "users#preview", "preview_new_user" ])
    end

    it "counts a resource whose options are a variable as a construct it did not expand" do
      records = routes_for(<<~RUBY)
        Rails.application.routes.draw do
          opts = { only: [:index] }
          resources :hashargs, opts
          resources :splatted, **opts
        end
      RUBY

      expect(records.select { |r| r[:type] == :route }).to be_empty
      expect(records.count { |r| r[:type] == :dynamic }).to eq(2)
    end

    it "draws every path of a multi-path route" do
      drawn = rows(<<~RUBY)
        Rails.application.routes.draw do
          get "/one", "/two", to: "pages#two"
        end
      RUBY

      expect(drawn).to eq([ [ "GET", "/one", "pages#two", "one" ], [ "GET", "/two", "pages#two", "two" ] ])
    end
  end

  describe "calls the walk does not know" do
    def dynamic_macros(source)
      routes_for(source).select { |r| r[:type] == :dynamic }.map { |r| r[:macro] }
    end

    it "counts a bare call or a call handed the mapper as a construct it did not expand" do
      results = routes_for(<<~RUBY)
        Rails.application.routes.draw do
          get "/home", to: "home#show"
          load Rails.root.join("config/routes/extra.rb")
          use_doorkeeper
          ActiveAdmin.routes(self)
        end
      RUBY

      expect(results.select { |r| r[:type] == :route }.map { |r| r[:path] }).to eq([ "/home" ])
      expect(results.select { |r| r[:type] == :dynamic }.map { |r| r[:macro] }).to eq(%i[load use_doorkeeper routes])
    end

    it "counts a gem macro configured by a block once, and reads through a block that holds routes" do
      results = routes_for(<<~RUBY)
        Rails.application.routes.draw do
          use_doorkeeper do
            skip_controllers :applications
            controllers tokens: "oauth/tokens"
          end
          devise_scope :user do
            get "/enter", to: "registrations#new"
          end
          constraints lambda { |request| request.subdomain.present? } do
            # nothing here yet
          end
        end
      RUBY

      expect(results.select { |r| r[:type] == :route }.map { |r| r[:path] }).to eq([ "/enter" ])
      expect(results.select { |r| r[:type] == :dynamic }.map { |r| r[:macro] }).to eq([ :use_doorkeeper ])
    end

    it "counts a gem macro inside a block that draws routes, and a block of blocks once" do
      results = routes_for(<<~RUBY)
        Rails.application.routes.draw do
          constraints(subdomain: "api") do
            get "/in", to: "pages#in"
            use_doorkeeper
            health_check_routes
          end
          authenticate :user do
            get "/mine", to: "pages#mine"
            use_doorkeeper
          end
          outer_macro do
            inner_config do
              setting :x
            end
          end
          constraints(subdomain: "admin") do
            inner_macro do
              setting :y
            end
            get "/admin", to: "pages#admin"
          end
        end
      RUBY

      expect(results.select { |r| r[:type] == :route }.map { |r| r[:path] }).to eq(%w[/in /mine /admin])
      expect(results.select { |r| r[:type] == :dynamic }.map { |r| r[:macro] })
        .to eq(%i[use_doorkeeper health_check_routes use_doorkeeper outer_macro inner_macro])
    end

    it "reads controller blocks and options routes, draws nothing for direct and resolve, and counts a lambda mount" do
      results = routes_for(<<~RUBY)
        Rails.application.routes.draw do
          controller :pages do
            get "terms", action: :terms, as: :terms
          end
          direct(:homepage) { "https://example.com" }
          resolve("Profile") { [:profile] }
          mount ->(env) { [200, {}, ["ok"]] }, at: "/ping", as: :ping
          options "opts", to: "pages#opts"
          namespace :admin do
            controller :reports do
              get "summary", action: :summary
            end
          end
        end
      RUBY

      expect(results.select { |r| r[:type] == :route }.map { |r| [ r[:name], r[:verb], r[:path], "#{r[:controller]}##{r[:action]}" ] })
        .to eq([ [ "terms", "GET", "/terms", "pages#terms" ], [ "opts", "OPTIONS", "/opts", "pages#opts" ],
                 [ "admin_summary", "GET", "/admin/summary", "admin/reports#summary" ] ])
      expect(results.select { |r| r[:type] == :dynamic }.map { |r| r[:macro] }).to eq([ :mount ])
    end

    it "does not count Ruby that draws no route" do
      expect(dynamic_macros(<<~RUBY)).to be_empty
        require "sidekiq/web"
        Rails.application.routes.draw do
          default_url_options host: "example.com"
          resources_path_names new: "neu"
          get "legacy", to: "pages#legacy", constraints: lambda { |req| admin?(req) }
          constraints ->(req) { admin?(req) } do
            mount Sidekiq::Web => "/sidekiq"
          end
        end
      RUBY
    end

    it "takes the new segment from resources_path_names" do
      records = route_records(<<~RUBY)
        Rails.application.routes.draw do
          resources_path_names new: "neu"
          resources :cars, only: [:new]
        end
      RUBY

      expect(records.map { |r| r[:path] }).to eq([ "/cars/neu" ])
    end
  end

  describe "methods and conditions in a route file" do
    it "draws a method's routes where it is called, not where it is defined" do
      records = route_records(<<~RUBY)
        Rails.application.routes.draw do
          def admin_routes
            resources :reports, only: :index
          end
          namespace :admin do
            admin_routes
          end
          scope "/v1", module: "api" do
            admin_routes
          end
        end
      RUBY

      expect(records.map { |r| [ r[:name], r[:path], "#{r[:controller]}##{r[:action]}" ] }).to eq([
        [ "admin_reports", "/admin/reports", "admin/reports#index" ],
        [ "reports", "/v1/reports", "api/reports#index" ]
      ])
    end

    it "counts a call to a method that takes arguments, or that calls itself, as not expanded" do
      results = routes_for(<<~RUBY)
        Rails.application.routes.draw do
          def versioned(v)
            get "v\#{v}/ping", to: "ping#show"
          end
          def loop_routes
            loop_routes
          end
          versioned 1
          loop_routes
        end
      RUBY

      expect(results.select { |r| r[:type] == :route }).to be_empty
      expect(results.select { |r| r[:type] == :dynamic }.map { |r| r[:macro] }).to eq(%i[versioned loop_routes])
    end

    it "says which condition a route is drawn under" do
      records = route_records(<<~RUBY)
        Rails.application.routes.draw do
          if Rails.env.development?
            get "dev_only", to: "posts#index"
          else
            get "prod_only", to: "posts#index"
          end
          unless ENV["ENABLE_BETA"]
            get "stable", to: "posts#index"
          end
          get "beta", to: "posts#index" if ENV["ENABLE_BETA"]
          get "always", to: "posts#index"
        end
      RUBY

      expect(records.to_h { |r| [ r[:path], r[:condition] ] }).to eq(
        "/dev_only" => "if Rails.env.development?",
        "/prod_only" => "unless Rails.env.development?",
        "/stable" => 'unless ENV["ENABLE_BETA"]',
        "/beta" => 'if ENV["ENABLE_BETA"]',
        "/always" => nil
      )
    end

    it "says which case branch a route is drawn under" do
      records = route_records(<<~RUBY)
        Rails.application.routes.draw do
          case Rails.env
          when "development", "test"
            get "dev", to: "posts#index"
          when "staging" then get "stage", to: "posts#index"
          else
            get "prod", to: "posts#index"
          end
          case
          when ENV["BETA"]
            get "beta", to: "posts#index"
          end
          get "always", to: "posts#index"
        end
      RUBY

      expect(records.to_h { |r| [ r[:path], r[:condition] ] }).to eq(
        "/dev" => 'when Rails.env is "development", "test"',
        "/stage" => 'when Rails.env is "staging"',
        "/prod" => 'when Rails.env is none of "development", "test", "staging"',
        "/beta" => 'if ENV["BETA"]',
        "/always" => nil
      )
    end
  end

  it "reads a constraint it cannot evaluate as written, and skips one that is not a hash" do
    records = route_records(<<~'RUBY')
      Rails.application.routes.draw do
        get "/a/:id", to: "a#show", constraints: { id: /[/ }
        get "/b/:id", to: "b#show", constraints: { id: ID_FORMAT, subdomain: SUB }
        get "/c", to: "c#show", constraints: nil
        constraints AdminConstraint.new do
          get "/d", to: "d#show"
        end
        constraints "x" do
          get "/e", to: "e#show"
        end
      end
    RUBY

    expect(records.to_h { |r| [ r[:path], r[:constraints] ] }).to eq(
      "/a/:id" => "{id: /[/}", "/b/:id" => "{id: ID_FORMAT}", "/c" => nil, "/d" => nil, "/e" => nil
    )
  end
end
