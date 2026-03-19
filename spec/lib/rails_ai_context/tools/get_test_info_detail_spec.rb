# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetTestInfo do
  before { described_class.reset_cache! }

  let(:test_data) do
    {
      framework: "minitest",
      factories: nil,
      factory_names: nil,
      fixtures: { location: "test/fixtures", count: 3 },
      fixture_names: { "users" => %w[one two], "posts" => %w[first_post] },
      system_tests: nil,
      test_helpers: %w[test/helpers/auth_helper.rb],
      test_helper_setup: %w[Devise::Test::IntegrationHelpers],
      test_files: { "models" => { location: "test/models", count: 5 }, "controllers" => { location: "test/controllers", count: 3 } },
      vcr_cassettes: nil,
      ci_config: %w[github_actions],
      coverage: "simplecov"
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ tests: test_data })
  end

  describe "detail levels" do
    it "returns compact info for detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("minitest")
      expect(text).to include("3 files")
      expect(text).not_to include("users:")
    end

    it "returns standard info with test file counts" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("minitest")
      expect(text).to include("test/fixtures")
      expect(text).to include("models: 5 files")
      expect(text).to include("github_actions")
    end

    it "returns full info with fixture names and helper setup" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("**users:** one, two")
      expect(text).to include("**posts:** first_post")
      expect(text).to include("Devise::Test::IntegrationHelpers")
      expect(text).to include("simplecov")
    end
  end

  describe "model filter" do
    it "returns not found for missing test file" do
      result = described_class.call(model: "Nonexistent")
      text = result.content.first[:text]
      expect(text).to include("No test file found")
    end
  end

  describe "controller filter" do
    it "returns not found for missing test file" do
      result = described_class.call(controller: "Nonexistent")
      text = result.content.first[:text]
      expect(text).to include("No test file found")
    end
  end

  describe "missing data" do
    it "handles missing test data gracefully" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end
  end
end
