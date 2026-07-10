# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetGems do
  before { described_class.reset_cache! }

  let(:gems_data) do
    {
      notable_gems: [
        { name: "devise", version: "4.9.3", category: "auth", note: "Authentication framework" },
        { name: "pundit", version: "2.3.1", category: "auth", note: "Authorization framework" },
        { name: "sidekiq", version: "7.2.0", category: "jobs", note: "Background job processing" },
        { name: "pg", version: "1.5.4", category: "database", note: "PostgreSQL adapter" },
        { name: "redis", version: "5.1.0", category: "database", note: "Redis client" },
        { name: "tailwindcss-rails", version: "3.0.0", category: "frontend", note: "Tailwind CSS integration" },
        { name: "rspec-rails", version: "6.1.0", category: "testing", note: "RSpec testing framework" },
        { name: "kamal", version: "2.0.0", category: "deploy", note: "Container deployment" },
        { name: "aws-sdk-s3", version: "1.140.0", category: "files", note: "AWS S3 storage" },
        { name: "graphql", version: "2.2.0", category: "api", note: "GraphQL API framework" }
      ]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ gems: gems_data })
  end

  describe ".call" do
    context "with default params (all categories)" do
      it "returns notable gems heading" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Notable Gems")
      end

      it "groups gems by category" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("## Auth")
        expect(text).to include("## Jobs")
        expect(text).to include("## Database")
        expect(text).to include("## Frontend")
        expect(text).to include("## Testing")
        expect(text).to include("## Deploy")
      end

      it "shows gem names with versions and notes" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("**devise** `4.9.3`")
        expect(text).to include("Authentication framework")
      end

      it "includes config hints for known gems" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("config/initializers/devise.rb")
        expect(text).to include("config/sidekiq.yml")
        expect(text).to include("config/storage.yml")
      end
    end

    context "filtering by category" do
      it "shows only auth gems when category is auth" do
        result = described_class.call(category: "auth")
        text = result.content.first[:text]
        expect(text).to include("devise")
        expect(text).to include("pundit")
        expect(text).not_to include("sidekiq")
        expect(text).not_to include("## Database")
      end

      it "shows only database gems when category is database" do
        result = described_class.call(category: "database")
        text = result.content.first[:text]
        expect(text).to include("pg")
        expect(text).to include("redis")
        expect(text).not_to include("devise")
      end

      it "shows only testing gems when category is testing" do
        result = described_class.call(category: "testing")
        text = result.content.first[:text]
        expect(text).to include("rspec-rails")
        expect(text).not_to include("devise")
      end

      it "shows only deploy gems when category is deploy" do
        result = described_class.call(category: "deploy")
        text = result.content.first[:text]
        expect(text).to include("kamal")
        expect(text).not_to include("pg")
      end

      it "returns helpful message for empty category" do
        result = described_class.call(category: "jobs")
        text = result.content.first[:text]
        expect(text).to include("sidekiq")
      end
    end

    context "with no matching gems in filtered category" do
      it "returns not-found message with available categories" do
        gems_data[:notable_gems] = gems_data[:notable_gems].reject { |g| g[:category] == "jobs" }
        result = described_class.call(category: "jobs")
        text = result.content.first[:text]
        expect(text).to include("No notable gems found")
        expect(text).to include("Available categories:")
      end
    end
  end

  describe "edge cases" do
    it "handles missing gems data" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "handles gems introspection error" do
      allow(described_class).to receive(:cached_context).and_return({
        gems: { error: "Gemfile.lock not found" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("failed")
      expect(text).to include("Gemfile.lock not found")
    end

    it "handles empty notable_gems list" do
      gems_data[:notable_gems] = []
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("No notable gems found")
    end

    it "handles gems without version" do
      gems_data[:notable_gems] = [
        { name: "custom_gem", version: nil, category: "api", note: "Custom API gem" }
      ]
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("**custom_gem**")
      expect(text).to include("Custom API gem")
    end

    it "sorts gems by category then name" do
      result = described_class.call
      text = result.content.first[:text]
      # "api" comes before "auth" alphabetically
      api_pos = text.index("## Api")
      auth_pos = text.index("## Auth")
      expect(api_pos).to be < auth_pos
    end
  end

  describe "solid_queue config hint" do
    let(:root) { Rails.application.root }

    before do
      gems_data[:notable_gems] = [
        { name: "solid_queue", version: "1.0.0", category: "jobs", note: "Background jobs via SolidQueue" }
      ]
      allow(File).to receive(:exist?).and_call_original
    end

    it "shows no config hint when neither queue.yml nor recurring.yml exist" do
      allow(File).to receive(:exist?).with(File.join(root, "config/queue.yml")).and_return(false)
      allow(File).to receive(:exist?).with(File.join(root, "config/recurring.yml")).and_return(false)

      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("**solid_queue**")
      expect(text).not_to include("config/solid_queue.yml")
      expect(text).not_to include("(config:")
    end

    it "shows only the config files that actually exist" do
      allow(File).to receive(:exist?).with(File.join(root, "config/queue.yml")).and_return(true)
      allow(File).to receive(:exist?).with(File.join(root, "config/recurring.yml")).and_return(false)

      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("(config: config/queue.yml)")
      expect(text).not_to include("config/recurring.yml")
      expect(text).not_to include("config/solid_queue.yml")
    end

    it "shows both config files when both exist" do
      allow(File).to receive(:exist?).with(File.join(root, "config/queue.yml")).and_return(true)
      allow(File).to receive(:exist?).with(File.join(root, "config/recurring.yml")).and_return(true)

      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("(config: config/queue.yml, config/recurring.yml)")
    end
  end
end
