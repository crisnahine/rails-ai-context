# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::StackSections do
  let(:width) { RailsAiContext::Serializers::Budget::LINE_WIDTH }
  let(:context) do
    serializer_context(
      tests: { framework: "rspec" },
      gems: { notable_gems: (1..40).map { |i| { name: "gem_number_#{i}", category: i.even? ? "auth" : "jobs", version: "1.0", note: "n" } } },
      conventions: { architecture: %w[service_objects api_only], patterns: %w[concerns sti], directory_structure: {} }
    )
  end

  let(:renderer) do
    Class.new(RailsAiContext::Serializers::Base) do
      include RailsAiContext::Serializers::StackOverviewHelper
      include RailsAiContext::Serializers::ToolGuideHelper
    end.new(context)
  end

  %i[summary overview full].each do |density|
    it "renders the gems at #{density} within the width" do
      expect(renderer.gems_lines(density).reject { |line| line.size <= width }).to eq([])
    end

    it "renders the architecture at #{density}" do
      expect(renderer.architecture_lines(density).join("\n")).to match(/Service objects|service_objects/i)
    end
  end

  it "heads a root file and an overview rule with the same version line" do
    root = renderer.header_lines(:root, title: "AI Context")
    overview = renderer.header_lines(:overview, title: "Overview")

    expect(root.join("\n")).to include("Rails 8.0 | Ruby 3.4")
    expect(overview).to eq([ "# TestApp - Overview", "", "Rails 8.0 | Ruby 3.4", "" ])
  end

  describe "the root file" do
    let(:root_file) { RailsAiContext::Serializers::RootFile.new(context).call }

    it "names the test command once" do
      expect(root_file.scan("bundle exec rspec").size).to eq(1)
    end

    # A fact stated twice is the same bytes loaded twice in every session.
    it "states no line twice" do
      lines = root_file.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#", "---", "|") || line.size < 12 }

      expect(lines.tally.select { |_, n| n > 1 }.keys).to eq([])
    end
  end
end
