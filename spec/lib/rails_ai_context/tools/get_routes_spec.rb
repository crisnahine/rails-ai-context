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

  # A controller nested under another controller's name has its own class and
  # its own filter chain, and a substring filter swept it in with the parent.
  describe "a fully qualified controller whose name prefixes another" do
    let(:nested_controllers) do
      {
        "api/v1/admin/orders" => [
          { verb: "POST", path: "/api/v1/admin/orders/edit", action: "edit", name: "api_v1_admin_orders_edit" }
        ],
        "api/v1/admin/orders/ai_data" => [
          { verb: "GET", path: "/api/v1/admin/orders/ai_data/availability", action: "availability", name: nil },
          { verb: "GET", path: "/api/v1/admin/orders/ai_data/download", action: "download", name: nil }
        ],
        "api/v1/gift_cards" => [
          { verb: "POST", path: "/api/v1/gift-cards/redeem", action: "redeem", name: nil }
        ]
      }
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({
        routes: { total_routes: 4, by_controller: nested_controllers, api_namespaces: [] }
      })
    end

    it "answers the exact key with its own routes only" do
      text = described_class.call(controller: "api/v1/admin/orders").content.first[:text]

      expect(text).to include("# Routes (1 route)")
      expect(text).not_to include("ai_data")
    end

    it "still answers a short name with every controller that carries it" do
      text = described_class.call(controller: "orders").content.first[:text]

      expect(text).to include("# Routes (3 routes)")
      expect(text).to include("api/v1/admin/orders/ai_data")
    end
  end

  # A Rack app attached in the routes file is counted and then dropped from
  # the body, so the one place it could be found by path named it nowhere.
  describe "an app with mounted Rack endpoints" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        routes: {
          total_routes: 1,
          by_controller: { "posts" => [ { verb: "GET", path: "/posts", action: "index", name: "posts" } ] },
          api_namespaces: [],
          unrouted_mounts: 2,
          mounted_engines: [
            { engine: "MetricsApp", path: "/metrics" },
            { engine: "MetricsAdminApp", path: "/metrics-admin" }
          ]
        }
      })
    end

    it "names each mounted app and the path it answers on" do
      text = described_class.call.content.first[:text]

      expect(text).to include("## Mounted Rack apps (2)")
      expect(text).to include("- **MetricsApp** at `/metrics`")
      expect(text).to include("- **MetricsAdminApp** at `/metrics-admin`")
    end

    it "counts them in the header without calling them engines" do
      text = described_class.call.content.first[:text]

      expect(text).to include("2 mounted Rack apps")
      expect(text).not_to include("engine mount")
    end

    it "leaves them out of a filtered answer" do
      text = described_class.call(controller: "posts").content.first[:text]

      expect(text).not_to include("Mounted Rack apps")
    end
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

    # Only `full` was covered here, and only `full` listed from the unfiltered
    # set. The default `standard` render re-split the routes and listed the app
    # ones alone, so the header counted 50 above a body of 24.
    it "includes framework routes at the default detail level" do
      result = described_class.call(app_only: false)
      text = result.content.first[:text]
      expect(text).to include("active_storage")
    end

    it "lists as many routes as the header counts" do
      result = described_class.call(app_only: false, limit: 1000)
      text = result.content.first[:text]
      header_count = text[/\A# Routes \((\d+) routes?/, 1].to_i
      listed = text.scan(/^- `/).size
      expect(listed).to eq(header_count)
    end

    # Sorted plainly, action_mailbox/ and active_storage/ lead the alphabet.
    # On an app with more framework routes than the page limit, the app's own
    # would paginate out of sight and a caller reading page one would conclude
    # the app defines no routes.
    it "lists the app's own routes before framework routes" do
      result = described_class.call(app_only: false, limit: 1)
      text = result.content.first[:text]
      first_controller = text[/^## (.+)$/, 1]
      expect(RailsAiContext::Tools::GetRoutes.framework_controller?(first_controller)).to be(false)
    end
  end

  describe ".call with app_only:true" do
    it "says how to see the routes it hid" do
      result = described_class.call(app_only: true)
      text = result.content.first[:text]
      expect(text).to match(/app_only/)
    end

    it "lists as many routes as the header counts" do
      result = described_class.call(app_only: true, limit: 1000)
      text = result.content.first[:text]
      header_count = text[/\A# Routes \((\d+) routes?/, 1].to_i
      listed = text.scan(/^- `/).size
      expect(listed).to eq(header_count)
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

  # The static tier records the constructs it could not expand. The renderer
  # dropped that number, so a partial list read as the whole routing table -
  # and the generic [STATIC] footer says the opposite, since these are route
  # definitions the parser did not follow, not runtime-only data.
  describe "routes the static tier could not expand" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        routes: {
          total_routes: 9, by_controller: by_controller, api_namespaces: [],
          dynamic_routes: 23
        }
      })
    end

    it "says how many are missing, in every detail level" do
      %w[summary standard full].each do |detail|
        text = described_class.call(detail: detail).content.first[:text]
        expect(text).to include("23 dynamic constructs not expanded"), "missing at detail:#{detail}"
      end
    end

    it "adds to the header rather than replacing what it said" do
      expect(described_class.call.content.first[:text])
        .to start_with("# Routes (7 routes, excluding 1 framework route, 23 dynamic constructs not expanded)")
    end

    it "says nothing when everything was expanded" do
      allow(described_class).to receive(:cached_context).and_return({
        routes: { total_routes: 9, by_controller: by_controller, api_namespaces: [] }
      })
      expect(described_class.call.content.first[:text]).not_to include("not expanded")
    end

    # The caveat is about the whole table, and a filtered answer is not that.
    it "stays out of a single-controller answer" do
      text = described_class.call(controller: "posts").content.first[:text]
      expect(text).not_to include("not expanded")
    end
  end

  # The header read the payload straight, so it named a filter the controller
  # skips, and it cut at three with nothing said about the rest.
  describe "the per-controller filter hint" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        routes: { total_routes: 6, by_controller: { "posts" => by_controller["posts"] }, api_namespaces: [] },
        controllers: { controllers: {
          "PostsController" => {
            parent_class: "ApplicationController",
            filters: [
              { kind: "before", name: "authenticate!" },
              { kind: "before", name: "set_locale", skipped: true },
              { kind: "after", name: "audit" },
              { kind: "before", name: "set_post", only: %w[show edit update destroy] },
              { kind: "before", name: "track" }
            ]
          }
        } }
      })
    end

    it "leaves out a filter the controller skips" do
      text = described_class.call.content.first[:text]

      expect(text).to include("filters: authenticate!, audit, set_post")
      expect(text).not_to include("set_locale")
    end

    it "says how many it did not show" do
      expect(described_class.call.content.first[:text]).to include("+1 more")
    end
  end

  # Every read of the shared cache is a deep copy of the whole payload, so a
  # listing that reads it once per controller heading pays for the app twice
  # over.
  describe "shared context reads in the route listing" do
    def context_with(count)
      routes = (1..count).to_h do |i|
        [ "group#{i}", [ { verb: "GET", path: "/group#{i}", action: "index", name: "group#{i}" } ] ]
      end
      controllers = (1..count).to_h do |i|
        [ "Group#{i}Controller", { actions: %w[index], filters: [ { kind: "before", name: "authenticate!" } ] } ]
      end
      {
        routes: { total_routes: count, by_controller: routes, api_namespaces: [] },
        controllers: { controllers: controllers }
      }
    end

    def reads_for(count)
      described_class.reset_cache!
      reads = 0
      ctx = context_with(count)
      allow(described_class).to receive(:cached_context) do
        reads += 1
        ctx
      end
      described_class.call(detail: "standard", limit: 400)
      reads
    end

    it "reads the shared context the same number of times for 3 controllers as for 40" do
      expect(reads_for(40)).to eq(reads_for(3))
    end
  end
end
