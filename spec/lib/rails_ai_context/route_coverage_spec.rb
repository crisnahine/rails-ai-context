# frozen_string_literal: true

require "spec_helper"

# Nine surfaces print a route count. The static tier records what it could not
# expand and nothing read it, which is how a 94-route answer on a 723-route app
# read as complete everywhere.
RSpec.describe RailsAiContext::RouteCoverage do
  describe ".suffix" do
    it "is interpolatable straight into a count" do
      expect("Routes: 94#{described_class.suffix(dynamic_routes: 23)}")
        .to eq("Routes: 94, 23 dynamic constructs not expanded")
    end

    it "counts one construct in the singular" do
      expect(described_class.suffix(dynamic_routes: 1))
        .to eq(", 1 dynamic construct not expanded")
    end

    it "names the routes drawn into engines, which the count leaves out" do
      routes = { dynamic_routes: 2, engine_routes: [ { engine: "Spree::Core::Engine", routes: [ {}, {} ] },
                                                     { engine: "Blog::Engine", routes: [ {} ] } ] }
      expect(described_class.suffix(routes)).to eq(", 2 dynamic constructs not expanded, 3 more in engine tables")
    end

    it "says a table read from source leaves out the routes gems draw at boot" do
      routes = { total_routes: 2, confidence: RailsAiContext::Confidence::STATIC }
      expect(described_class.suffix(routes)).to eq(", routes gems draw at boot not read without booting")
      expect(described_class.suffix(routes, false)).to eq("")
    end

    it "is empty when the count is the whole table" do
      expect(described_class.suffix(total_routes: 20)).to eq("")
    end

    it "is empty when the section failed" do
      expect(described_class.suffix(error: "boom")).to eq("")
    end

    it "is empty for a section that is not a hash" do
      expect(described_class.suffix(nil)).to eq("")
    end

    it "names in-repo engine route files the walk never opens" do
      expect(described_class.suffix(total_routes: 94, in_repo_route_files: 25))
        .to eq(", 25 in-repo engine route files not read")
    end

    it "names both when the walk misses both" do
      expect(described_class.suffix(dynamic_routes: 2, in_repo_route_files: 1))
        .to eq(", 2 dynamic constructs not expanded, 1 in-repo engine route file not read")
    end

    # A booted app expands everything, so the key is absent and every surface
    # reads exactly as it did before.
    it "is empty for a runtime context" do
      expect(described_class.suffix(total_routes: 723, by_controller: {})).to eq("")
    end
  end

  describe "the app-route population" do
    let(:routes) do
      {
        total_routes: 5,
        by_controller: {
          "posts" => [
            { verb: "GET", path: "/posts", action: "index" },
            { verb: "PUT", path: "/posts/:id", action: "update" },
            { verb: "PATCH", path: "/posts/:id", action: "update" }
          ],
          "rails/conductor/inbound_emails" => [
            { verb: "GET", path: "/conductor", action: "index" },
            { verb: "PUT", path: "/conductor/:id", action: "update" },
            { verb: "PATCH", path: "/conductor/:id", action: "update" }
          ]
        }
      }
    end

    it "drops framework-engine controllers and merges PUT/PATCH pairs" do
      app = described_class.app_controllers(routes)
      expect(app.keys).to eq(%w[posts])
      expect(app["posts"].map { |r| r[:verb] }).to eq([ "GET", "PATCH|PUT" ])
    end

    it "counts the app and framework shares from the same population" do
      expect(described_class.app_route_count(routes)).to eq(2)
      expect(described_class.framework_route_count(routes)).to eq(2)
    end

    it "answers the framework predicate from the config" do
      expect(described_class.framework_controller?("rails/conductor/inbound_emails")).to be(true)
      expect(described_class.framework_controller?("posts")).to be(false)
    end

    it "is empty for a failed or missing section" do
      expect(described_class.app_controllers(nil)).to eq({})
      expect(described_class.app_route_count({ error: "boom" })).to eq(0)
    end
  end

  describe ".dedupe_put_patch_routes" do
    it "merges the PUT/PATCH pair Rails generates for one update action" do
      routes = [
        { verb: "PATCH", path: "/posts/:id", action: "update", controller: "posts" },
        { verb: "PUT",   path: "/posts/:id", action: "update", controller: "posts" }
      ]

      merged = described_class.dedupe_put_patch_routes(routes)

      expect(merged.size).to eq(1)
      expect(merged.first[:verb]).to eq("PATCH|PUT")
    end

    # Forem mounts api/v0/listings and api/v1/listings on the same path. Without
    # the controller in the match the second version's PATCH found the first
    # version's already-merged entry, declined to merge into "PATCH|PUT" and was
    # appended twice - so the flat count said 769 where the per-controller sum
    # said 768.
    it "keeps two controllers that share a path and an action apart" do
      routes = [
        { verb: "PATCH", path: "/api/listings/:id", action: "update", controller: "api/v1/listings" },
        { verb: "PUT",   path: "/api/listings/:id", action: "update", controller: "api/v1/listings" },
        { verb: "PATCH", path: "/api/listings/:id", action: "update", controller: "api/v0/listings" },
        { verb: "PUT",   path: "/api/listings/:id", action: "update", controller: "api/v0/listings" }
      ]

      merged = described_class.dedupe_put_patch_routes(routes)

      expect(merged.map { |r| [ r[:controller], r[:verb] ] })
        .to eq([ [ "api/v1/listings", "PATCH|PUT" ], [ "api/v0/listings", "PATCH|PUT" ] ])
    end

    # The grouped entries carry no :controller - it is the group key - so the
    # same call over one controller's actions behaves as it always did.
    it "merges grouped entries that carry no controller key" do
      routes = [
        { verb: "PATCH", path: "/posts/:id", action: "update" },
        { verb: "PUT",   path: "/posts/:id", action: "update" }
      ]

      expect(described_class.dedupe_put_patch_routes(routes).size).to eq(1)
    end
  end
end
