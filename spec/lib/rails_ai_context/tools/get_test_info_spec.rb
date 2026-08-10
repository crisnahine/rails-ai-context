# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetTestInfo do
  before { described_class.reset_cache! }

  let(:test_data) do
    {
      framework: "RSpec",
      factories: { location: "spec/factories", count: 5 },
      factory_names: { "users.rb" => %w[user admin_user], "posts.rb" => %w[post published_post] },
      factory_traits: %w[user:admin user:with_posts post:published],
      fixtures: nil,
      fixture_names: nil,
      system_tests: { location: "spec/system" },
      test_helpers: %w[spec/support/auth_helpers.rb spec/support/api_helpers.rb],
      test_helper_setup: %w[FactoryBot::Syntax::Methods],
      test_files: {
        "models" => { location: "spec/models", count: 8 },
        "controllers" => { location: "spec/controllers", count: 4 },
        "requests" => { location: "spec/requests", count: 6 }
      },
      test_count_by_category: { "models" => 42, "requests" => 18, "system" => 5 },
      ci_config: %w[github_actions],
      coverage: "simplecov"
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ tests: test_data })
  end

  describe ".call with no params" do
    it "defaults to standard detail level" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Test Infrastructure")
      expect(text).to include("RSpec")
      expect(text).to include("spec/factories")
    end

    it "shows test file categories" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("models: 8 files")
      expect(text).to include("requests: 6 files")
    end

    it "shows CI config" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("github_actions")
    end

    it "shows coverage tool" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("simplecov")
    end
  end

  describe ".call with detail:summary" do
    it "returns compact summary with counts" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Test Infrastructure")
      expect(text).to include("RSpec")
      expect(text).to include("5 files")
    end

    it "shows total test file count" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("18 across 3 categories")
    end
  end

  describe ".call with detail:full" do
    it "shows factory names when available" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("Factories")
    end

    it "shows test helper setup" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("Test Helper Setup")
      expect(text).to include("FactoryBot::Syntax::Methods")
    end

    it "shows test counts by category" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("Test Counts by Category")
      expect(text).to include("models: 42")
    end

    it "shows test helper files" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("spec/support/auth_helpers.rb")
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

  describe ".call with model filter" do
    it "searches for model test file" do
      result = described_class.call(model: "User")
      text = result.content.first[:text]
      # Should either find a test file or report not found with searched paths
      expect(text).to match(/user_spec\.rb|user_test\.rb|No test file found/)
    end

    it "handles model filter with controller-style name" do
      result = described_class.call(model: "Nonexistent")
      text = result.content.first[:text]
      expect(text).to include("No test file found")
      expect(text).to include("Searched:")
    end
  end

  describe ".call with controller filter" do
    it "searches for controller test file" do
      result = described_class.call(controller: "Posts")
      text = result.content.first[:text]
      expect(text).to match(/posts_controller_spec\.rb|posts_spec\.rb|posts_controller_test\.rb|No test file found/)
    end

    it "returns not found with nearby files hint for missing controller test" do
      result = described_class.call(controller: "Nonexistent")
      text = result.content.first[:text]
      expect(text).to include("No test file found")
    end
  end

  describe ".call when introspection data is missing" do
    it "returns not-available when tests key is nil" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "returns error message when test data has an error" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { error: "test dir not found" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("test dir not found")
    end
  end

  describe ".call with minitest framework data" do
    before do
      minitest_data = test_data.merge(
        framework: "Minitest",
        factories: nil,
        factory_names: nil,
        fixtures: { location: "test/fixtures", count: 3 },
        fixture_names: { "users" => %w[one two], "posts" => %w[first_post] }
      )
      allow(described_class).to receive(:cached_context).and_return({ tests: minitest_data })
    end

    it "shows fixture info for minitest apps" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("test/fixtures")
      expect(text).to include("3 files")
    end
  end

  describe "full detail with minitest fixtures and helpers" do
    before do
      minitest_full_data = {
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
      allow(described_class).to receive(:cached_context).and_return({ tests: minitest_full_data })
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
end
