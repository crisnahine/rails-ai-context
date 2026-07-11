# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::RoutesDslListener do
  def routes_for(source)
    listener = described_class.new
    dispatcher = Prism::Dispatcher.new
    dispatcher.register(listener, :on_call_node_enter, :on_call_node_leave)
    dispatcher.dispatch(Prism.parse(source).value)
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
end
