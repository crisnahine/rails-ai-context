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

    it "is empty when the count is the whole table" do
      expect(described_class.suffix(total_routes: 20)).to eq("")
    end

    it "is empty when the section failed" do
      expect(described_class.suffix(error: "boom")).to eq("")
    end

    it "is empty for a section that is not a hash" do
      expect(described_class.suffix(nil)).to eq("")
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
end
