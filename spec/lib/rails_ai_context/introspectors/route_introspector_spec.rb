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

    it "reports a missing routes.rb honestly" do
      Dir.mktmpdir do |dir|
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result[:error]).to include("config/routes.rb")
      end
    end
  end
end
