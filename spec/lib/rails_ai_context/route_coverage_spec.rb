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
end
