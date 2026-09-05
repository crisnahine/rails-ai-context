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
end
