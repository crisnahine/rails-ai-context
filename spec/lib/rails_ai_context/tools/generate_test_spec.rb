# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GenerateTest do
  before { described_class.reset_cache! }

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call(model: "NonExistent")
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "requires at least one parameter" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Provide at least one")
    end

    it "returns not-found for unknown model" do
      result = described_class.call(model: "ZzzNonexistentModel")
      text = result.content.first[:text]
      expect(text).to include("not found")
    end

    it "generates rspec-style output when framework is rspec" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factories: { count: 1 }, factory_names: {} },
        models: {
          "User" => {
            associations: [ { type: "has_many", name: "posts" } ],
            validations: [ { kind: "presence", attributes: %w[ email ] } ],
            scopes: [ { name: "active", body: "where(active: true)" } ],
            enums: {},
            callbacks: {}
          }
        }
      })

      result = described_class.call(model: "User")
      text = result.content.first[:text]
      expect(text).to include("RSpec.describe User")
      expect(text).to include("associations")
      expect(text).to include("validations")
      expect(text).to include("validate_presence_of(:email)")
      expect(text).to include("have_many(:posts)")
      expect(text).to include(".active")
    end

    it "generates minitest-style output when framework is minitest" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest" },
        models: {
          "Post" => {
            associations: [ { type: "belongs_to", name: "user" } ],
            validations: [ { kind: "presence", attributes: %w[ title ] } ],
            scopes: [],
            enums: {},
            callbacks: {}
          }
        }
      })

      result = described_class.call(model: "Post")
      text = result.content.first[:text]
      expect(text).to include("class PostTest < ActiveSupport::TestCase")
      expect(text).to include("validates presence of title")
    end

    it "generates request spec for controller" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", test_helper_setup: [] },
        models: {},
        routes: {
          by_controller: {
            "posts" => [
              { verb: "GET", path: "/posts", action: "index", name: "posts" },
              { verb: "POST", path: "/posts", action: "create", name: "posts" }
            ]
          }
        }
      })

      result = described_class.call(controller: "PostsController")
      text = result.content.first[:text]
      expect(text).to include("type: :request")
      expect(text).to include("GET /posts")
      expect(text).to include("POST /posts")
    end

    it "generates minitest controller test with quoted paths and defined params for nested routes" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "likes" => [ "one" ], "posts" => [ "one" ] }
        },
        models: { "Like" => { table_name: "likes" } },
        routes: {
          by_controller: {
            "likes" => [
              { verb: "DELETE", path: "/posts/:post_id/like", action: "destroy", name: nil, params: [ "post_id" ] }
            ]
          }
        }
      })

      result = described_class.call(controller: "LikesController")
      text = result.content.first[:text]
      # Path must be a quoted string, not a regex literal
      expect(text).to include('delete "/posts/')
      expect(text).not_to match(/delete\s+\/posts/)
      # post_id variable must be defined
      expect(text).to include("post_id = posts(:one).id")
      # Destroy targets a fresh record so fixture foreign keys stay intact
      expect(text).to include('like = Like.create!(@like.attributes.except("id", "created_at", "updated_at"))')
      expect(text).to include('assert_difference("Like.count", -1)')
    end

    it "generates a scaffold-style minitest controller test from routes, fixtures, and strong params" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "articles" => [ "one", "two" ] }
        },
        models: { "Article" => { table_name: "articles" } },
        controllers: {
          controllers: {
            "ArticlesController" => {
              api_controller: false,
              respond_to_formats: [ "html", "json" ],
              strong_params: [ { name: "article_params", requires: "article", permits: [ "title", "body" ] } ]
            }
          }
        },
        routes: {
          by_controller: {
            "articles" => [
              { verb: "GET", path: "/articles", action: "index", name: "articles" },
              { verb: "POST", path: "/articles", action: "create" },
              { verb: "GET", path: "/articles/:id", action: "show", name: "article", params: [ "id" ] },
              { verb: "PATCH", path: "/articles/:id", action: "update", params: [ "id" ] },
              { verb: "PUT", path: "/articles/:id", action: "update", params: [ "id" ] },
              { verb: "DELETE", path: "/articles/:id", action: "destroy", params: [ "id" ] }
            ]
          }
        }
      })

      result = described_class.call(controller: "ArticlesController")
      text = result.content.first[:text]
      expect(text).to include("@article = articles(:one)")
      # Unnamed POST/PATCH/DELETE routes borrow the helper of the named sibling path
      expect(text).to include("post articles_url, params: { article: { body: @article.body, title: @article.title } }")
      expect(text).to include("patch article_url(@article), params: { article: { body: @article.body, title: @article.title } }")
      # Writes assert redirects, not :success, and update is tested once (PATCH wins over PUT)
      expect(text).to include("assert_response :redirect")
      expect(text.scan("should update article").size).to eq(1)
      expect(text).to include('assert_difference("Article.count")')
    end

    it "generates JSON requests with as: :json for API controllers" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "orders" => [ "one" ] }
        },
        models: { "Order" => { table_name: "orders" } },
        controllers: {
          controllers: {
            "OrdersController" => {
              api_controller: true,
              strong_params: [ { name: "order_params", requires: "order", permits: [ "number" ] } ]
            }
          }
        },
        routes: {
          by_controller: {
            "orders" => [
              { verb: "GET", path: "/orders", action: "index", name: "orders" },
              { verb: "POST", path: "/orders", action: "create" }
            ]
          }
        }
      })

      result = described_class.call(controller: "OrdersController")
      text = result.content.first[:text]
      expect(text).to include("get orders_url, as: :json")
      expect(text).to include("post orders_url, params: { order: { number: @order.number } }, as: :json")
      # API responses render, not redirect; 201/204 sit inside the :success range
      expect(text).not_to include("assert_response :redirect")
      expect(text).to include("assert_response :success")
    end

    it "emits explicit skip TODOs when fixtures or permitted attributes are missing" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", test_helper_setup: [], fixture_names: {} },
        models: { "Widget" => { table_name: "widgets" } },
        routes: {
          by_controller: {
            "widgets" => [
              { verb: "GET", path: "/widgets/:id", action: "show", name: "widget", params: [ "id" ] },
              { verb: "POST", path: "/widgets", action: "create" }
            ]
          }
        }
      })

      result = described_class.call(controller: "WidgetsController")
      text = result.content.first[:text]
      expect(text).to include('skip "TODO:')
      expect(text).not_to include("post widgets_url")
    end

    it "falls back to schema content columns when no strong params are detected" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "articles" => [ "one" ] }
        },
        models: { "Article" => { table_name: "articles" } },
        schema: {
          tables: {
            "articles" => {
              columns: [
                { name: "id", type: "integer" },
                { name: "title", type: "string" },
                { name: "created_at", type: "datetime" },
                { name: "updated_at", type: "datetime" }
              ]
            }
          }
        },
        routes: {
          by_controller: {
            "articles" => [
              { verb: "POST", path: "/articles", action: "create", name: "articles" }
            ]
          }
        }
      })

      result = described_class.call(controller: "ArticlesController")
      text = result.content.first[:text]
      expect(text).to include("params: { article: { title: @article.title } }")
    end

    it "detects file type from path" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec" },
        models: {
          "Post" => {
            associations: [],
            validations: [],
            scopes: [],
            enums: {},
            callbacks: {}
          }
        }
      })

      result = described_class.call(file: "app/models/post.rb")
      text = result.content.first[:text]
      expect(text).to include("RSpec.describe Post")
    end
  end
end
