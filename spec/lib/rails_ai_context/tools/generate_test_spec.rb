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
        tests: { framework: "minitest", test_helper_setup: [] },
        models: {},
        routes: {
          by_controller: {
            "likes" => [
              { verb: "DELETE", path: "/posts/:post_id/like", action: "destroy", name: nil }
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
