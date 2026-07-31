# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetEnvironments do
  before { described_class.reset_cache! }

  let(:environments_data) do
    {
      current: "development",
      count: 2,
      environments: [
        {
          name: "development",
          file: "config/environments/development.rb",
          config_keys: %w[cache_store eager_load],
          notable: { "eager_load" => "false", "cache_store" => ":memory_store" }
        },
        {
          name: "production",
          file: "config/environments/production.rb",
          config_keys: %w[force_ssl eager_load log_level],
          notable: { "force_ssl" => "true", "eager_load" => "true", "log_level" => ":info" }
        }
      ]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ environments: environments_data })
  end

  describe ".call" do
    it "renders the current environment and file count" do
      text = described_class.call.content.first[:text]
      expect(text).to include("# Environments")
      expect(text).to include("_Current: **development** - 2 environment file(s)")
    end

    it "renders notable toggles per environment" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## production")
      expect(text).to include("- **force_ssl:** `true`")
      expect(text).to include("- **log_level:** `:info`")
    end

    it "renders config key lists" do
      text = described_class.call.content.first[:text]
      expect(text).to include("**Config keys set (2):** `cache_store`, `eager_load`")
    end

    context "with an environment filter" do
      it "shows only the matching environment" do
        text = described_class.call(environment: "production").content.first[:text]
        expect(text).to include("## production")
        expect(text).not_to include("## development")
      end

      it "returns not-found for an unknown environment" do
        text = described_class.call(environment: "qa").content.first[:text]
        expect(text).to include("Environment 'qa' not found.")
        expect(text).to include("Available: development, production")
      end
    end

    context "when no environment files exist" do
      before do
        allow(described_class).to receive(:cached_context)
          .and_return({ environments: { current: "development", count: 0, environments: [] } })
      end

      it "says so plainly" do
        text = described_class.call.content.first[:text]
        expect(text).to include("_No environment files found._")
      end
    end

    context "when the introspector is not configured" do
      before { allow(described_class).to receive(:cached_context).and_return({}) }

      it "says how to enable it" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Add :environments to introspectors")
      end
    end

    context "when introspection failed" do
      before { allow(described_class).to receive(:cached_context).and_return({ environments: { error: "boom" } }) }

      it "reports the failure honestly" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Environment introspection failed: boom")
      end
    end
  end
end
