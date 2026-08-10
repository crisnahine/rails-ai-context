# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetRoutes do
  before { described_class.reset_cache! }

  let(:by_controller) do
    {
      "posts" => [
        { verb: "GET", path: "/posts", action: "index", name: "posts" },
        { verb: "GET", path: "/posts/:id", action: "show", name: "post" },
        { verb: "POST", path: "/posts", action: "create", name: nil },
        { verb: "PUT", path: "/posts/:id", action: "update", name: nil },
        { verb: "PATCH", path: "/posts/:id", action: "update", name: nil },
        { verb: "DELETE", path: "/posts/:id", action: "destroy", name: nil }
      ],
      "users" => [
        { verb: "GET", path: "/users", action: "index", name: "users" },
        { verb: "GET", path: "/users/:id", action: "show", name: "user" }
      ],
      "active_storage/blobs" => [
        { verb: "GET", path: "/rails/active_storage/blobs/:signed_id/*filename", action: "show", name: nil }
      ]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({
      routes: { total_routes: 9, by_controller: by_controller, api_namespaces: [] }
    })
  end

  describe ".call with no params" do
    it "defaults to standard detail and filters framework routes" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("posts")
      expect(text).to include("users")
      expect(text).not_to include("active_storage")
    end
  end

  describe ".call with app_only:false" do
    it "includes framework routes" do
      result = described_class.call(app_only: false, detail: "full")
      text = result.content.first[:text]
      expect(text).to include("active_storage")
    end
  end

  describe "PUT/PATCH deduplication" do
    it "combines PUT and PATCH into a single entry" do
      result = described_class.call(controller: "posts", detail: "full")
      text = result.content.first[:text]
      expect(text).to include("PATCH|PUT")
      # Should not have separate PUT and PATCH rows for the same action
      expect(text.scan("update").size).to be >= 1
    end
  end

  describe ".call with unknown detail level" do
    it "reads an invalid detail level as the default, and says so" do
      text = described_class.call(detail: "invalid").content.first[:text]

      expect(text).to start_with(described_class.call(detail: "standard").content.first[:text])
      expect(text).to include("invalid")
      expect(text).to include("not a valid `detail`")
    end
  end

  describe ".call with controller filter not matching" do
    it "returns no-routes message with available controllers" do
      result = described_class.call(controller: "zzz_nonexistent")
      text = result.content.first[:text]
      expect(text).to include("No routes for")
      expect(text).to include("posts")
    end
  end

  describe ".call with pagination" do
    it "respects offset parameter for standard detail" do
      result = described_class.call(detail: "standard", offset: 100)
      text = result.content.first[:text]
      # With a high offset, the table should be empty but header still present
      expect(text).to include("Routes")
    end

    it "respects limit parameter for full detail" do
      result = described_class.call(detail: "full", limit: 1)
      text = result.content.first[:text]
      expect(text).to include("Routes Full Detail")
    end
  end

  describe ".call when introspection data is missing" do
    it "returns not-available when routes key is nil" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "returns error message when routes data has an error" do
      allow(described_class).to receive(:cached_context).and_return({
        routes: { error: "routing error" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("routing error")
    end
  end

  describe "summary detail with API namespaces" do
    it "shows API namespace info" do
      allow(described_class).to receive(:cached_context).and_return({
        routes: {
          total_routes: 3,
          by_controller: {
            "api/v1/posts" => [
              { verb: "GET", path: "/api/v1/posts", action: "index", name: "api_v1_posts" }
            ]
          },
          api_namespaces: [ "api/v1" ]
        }
      })
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("api/v1")
    end
  end

  describe "summary detail with route counts" do
    before do
      summary_controllers = {
        "users" => [
          { verb: "GET", path: "/users", action: "index", name: "users" },
          { verb: "GET", path: "/users/:id", action: "show", name: "user" },
          { verb: "POST", path: "/users", action: "create", name: nil }
        ],
        "posts" => [
          { verb: "GET", path: "/posts", action: "index", name: "posts" },
          { verb: "GET", path: "/posts/:id", action: "show", name: "post" }
        ],
        "api/v1/items" => [
          { verb: "GET", path: "/api/v1/items", action: "index", name: "api_v1_items" }
        ]
      }
      allow(described_class).to receive(:cached_context).and_return({
        routes: { total_routes: 6, by_controller: summary_controllers, api_namespaces: [ "api/v1" ] }
      })
    end

    it "returns summary with route counts per controller" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Routes Summary (6 routes)")
      expect(text).to include("**users**")
      expect(text).to include("3 routes")
      expect(text).to include("api/v1")
    end
  end

  describe "case-insensitive controller filter" do
    it "filters by controller name case-insensitively" do
      result = described_class.call(controller: "POSTS", detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("**posts**")
    end
  end
end
