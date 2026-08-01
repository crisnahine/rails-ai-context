# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetMailers do
  before { described_class.reset_cache! }

  let(:jobs_data) do
    {
      mailers: [
        { name: "AdminMailer", actions: %w[weekly_digest], delivery_method: "smtp" },
        { name: "UserMailer", actions: %w[reset_password welcome], delivery_method: "test" }
      ]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ jobs: jobs_data })
  end

  describe ".call" do
    it "lists all mailers with actions and delivery methods" do
      text = described_class.call.content.first[:text]
      expect(text).to include("# Mailers")
      expect(text).to include("## UserMailer")
      expect(text).to include("- **Delivery method:** test")
      expect(text).to include("- **Actions:** reset_password, welcome")
      expect(text).to include("## AdminMailer")
    end

    context "with a mailer filter" do
      it "shows only the matching mailer" do
        text = described_class.call(mailer: "UserMailer").content.first[:text]
        expect(text).to include("## UserMailer")
        expect(text).not_to include("## AdminMailer")
      end

      it "fuzzy-matches an underscored name" do
        text = described_class.call(mailer: "user_mailer").content.first[:text]
        expect(text).to include("## UserMailer")
      end

      it "returns not-found for an unknown mailer" do
        text = described_class.call(mailer: "GhostMailer").content.first[:text]
        expect(text).to include("Mailer 'GhostMailer' not found.")
        expect(text).to include("UserMailer")
      end
    end

    context "when the app has no mailers" do
      before { allow(described_class).to receive(:cached_context).and_return({ jobs: { mailers: [] } }) }

      it "says so plainly" do
        text = described_class.call.content.first[:text]
        expect(text).to include("_No mailers found._")
      end
    end

    context "when introspection failed" do
      before { allow(described_class).to receive(:cached_context).and_return({ jobs: { error: "boom" } }) }

      it "reports the failure honestly" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Mailer introspection failed: boom")
      end
    end

    context "when the jobs introspector is not configured" do
      before { allow(described_class).to receive(:cached_context).and_return({}) }

      it "says how to enable it" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Add :jobs to introspectors")
      end
    end

    context "when running in the static tier" do
      before do
        allow(described_class).to receive(:cached_context)
          .and_return({ jobs: { unavailable: "requires a booted Rails app" } })
      end

      it "renders the unavailable note" do
        text = described_class.call.content.first[:text]
        expect(text).to include("[UNAVAILABLE: requires a booted Rails app]")
      end
    end
  end
end
