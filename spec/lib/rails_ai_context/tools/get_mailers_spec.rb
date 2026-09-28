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
    # A page past the end is not an empty app. "No mailers found." above
    # "No items at offset 9999. Total: 2." contradicts itself, and the first
    # line is the one that reads as the answer.
    it "says only that the page is past the end, not that the app has no mailers" do
      text = described_class.call(offset: 9999).content.first[:text]

      expect(text).to include("_No items at offset 9999. Total: 2._")
      expect(text).not_to include("No mailers found")
    end

    it "still says so when the app really has no mailers" do
      allow(described_class).to receive(:cached_context).and_return({ jobs: { mailers: [] } })

      expect(described_class.call.content.first[:text]).to include("_No mailers found._")
    end

    it "lists all mailers with actions and delivery methods" do
      text = described_class.call.content.first[:text]
      expect(text).to include("# Mailers")
      expect(text).to include("## UserMailer")
      expect(text).to include("- **Delivery method:** test")
      expect(text).to include("- **Actions:** reset_password, welcome")
      expect(text).to include("## AdminMailer")
    end

    # A base is left out of the listing, so the answer says which ones and why
    # rather than leaving a reader to wonder where ApplicationMailer went.
    it "names the base classes the listing leaves out" do
      allow(described_class).to receive(:cached_context).and_return(
        { jobs: jobs_data.merge(mailer_bases: [ { name: "ApplicationMailer" } ]) }
      )

      text = described_class.call.content.first[:text]

      expect(text).to include("Base classes not counted as mailers: ApplicationMailer")
      expect(text).to include("## UserMailer")
    end

    # Every blog has an ApplicationMailer and no mailer. The answer says both,
    # the way the service and job listings do, so "no mailers" never reads as
    # an app with nothing under app/mailers.
    it "names the base beside an empty listing" do
      allow(described_class).to receive(:cached_context).and_return(
        { jobs: { mailers: [], mailer_bases: [ { name: "ApplicationMailer" } ] } }
      )

      text = described_class.call.content.first[:text]

      expect(text).to include("_No mailers found._")
      expect(text).to include("_Base classes not counted as mailers: ApplicationMailer.")
    end

    # A base is asked for to learn what every mailer inherits from it.
    it "answers a base with what it declares and who inherits it" do
      allow(described_class).to receive(:cached_context).and_return(
        { jobs: { mailers: [], mailer_bases: [ {
          name: "ApplicationMailer", file: "app/mailers/application_mailer.rb",
          declares: [ "layout 'mailer'", "after_action :set_autoreply_headers!" ],
          methods: %w[locale_for_account], inherited_by: %w[AdminMailer UserMailer]
        } ] } }
      )

      text = described_class.call(mailer: "ApplicationMailer").content.first[:text]

      expect(text).to include("**File:** `app/mailers/application_mailer.rb`")
      expect(text).to include("- `layout 'mailer'`")
      expect(text).to include("- `after_action :set_autoreply_headers!`")
      expect(text).to include("**Defines:** locale_for_account")
      expect(text).to include("**Inherited by (2):** AdminMailer, UserMailer")
    end

    # The note offers a base by name, so the name answers.
    it "answers for a base asked for by name" do
      allow(described_class).to receive(:cached_context).and_return(
        { jobs: { mailers: [], mailer_bases: [ { name: "ApplicationMailer" } ] } }
      )

      text = described_class.call(mailer: "ApplicationMailer").content.first[:text]

      expect(text).to include("# ApplicationMailer")
      expect(text).to include("other mailers inherit from it")
      expect(text).not_to include("not found")
    end

    it "leaves the note out of a single mailer's answer" do
      allow(described_class).to receive(:cached_context).and_return(
        { jobs: jobs_data.merge(mailer_bases: [ { name: "ApplicationMailer" } ]) }
      )

      text = described_class.call(mailer: "UserMailer").content.first[:text]

      expect(text).not_to include("Base classes not counted")
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

      # `DeviseMailer` contains `Mailer`, and the substring fallback answered
      # with Mailer's actions under the asked-for name.
      it "does not answer a substring of a real name" do
        text = described_class.call(mailer: "SuperAdminMailer").content.first[:text]
        expect(text).to include("Mailer 'SuperAdminMailer' not found.")
        expect(text).to include("Available: AdminMailer, UserMailer")
        expect(text).not_to include("weekly_digest")
      end

      # Two namespaces can hold the same mailer name, and answering with
      # whichever sorted first gave one namespace's actions under a name that
      # names both.
      it "asks which one when a short name matches two namespaces" do
        allow(described_class).to receive(:cached_context).and_return(
          { jobs: { mailers: [ { name: "Admin::ReportMailer", actions: %w[weekly] },
                               { name: "Staff::ReportMailer", actions: %w[daily] } ] } }
        )

        text = described_class.call(mailer: "ReportMailer").content.first[:text]

        expect(text).to include("Mailer 'ReportMailer' not found.")
        expect(text).to include("Admin::ReportMailer")
        expect(text).to include("Staff::ReportMailer")
        expect(text).not_to include("weekly")
      end

      it "still answers a full name that a namespaced sibling shares" do
        allow(described_class).to receive(:cached_context).and_return(
          { jobs: { mailers: [ { name: "Dashboard::Mailer", actions: %w[forward] },
                               { name: "Mailer", actions: %w[newsletter] } ] } }
        )

        text = described_class.call(mailer: "Mailer").content.first[:text]

        expect(text).to include("## Mailer")
        expect(text).to include("newsletter")
        expect(text).not_to include("Dashboard::Mailer")
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
  # The static tier has no boot, so no delivery method. Rendering the label
  # with nothing after it reads as a mailer configured to deliver nowhere.
  describe "without a delivery method" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        { jobs: { mailers: [ { name: "PostMailer", actions: %w[notify] } ] } }
      )
    end

    it "omits the label rather than printing an empty value" do
      text = described_class.call.content.first[:text]
      expect(text).to include("PostMailer")
      expect(text).not_to include("Delivery method:")
    end
  end

  # An empty action list under a mailer's name reads as a mailer that sends
  # nothing. Both of these send plenty.
  describe "a mailer with no action of its own" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        { jobs: { mailers: [
          { name: "DeviseMailer", actions: [], parent_class: "Devise::Mailer" },
          { name: "MultiNotifications", actions: [], class_actions: %w[deadline_passed] }
        ] } }
      )
    end

    it "says where the actions are instead of printing an empty list" do
      text = described_class.call.content.first[:text]
      expect(text).to include("[UNAVAILABLE: none declared here; inherited from `Devise::Mailer`]")
      expect(text).to include("- **Class methods:** deadline_passed")
    end

    # Diaspora's DiasporaDeviseMailer overrides `self.mailer_name` and nothing
    # else. The parent is the answer to where its emails are; the override is
    # not an interface anybody calls.
    it "names the parent of a mailer that also carries class methods" do
      allow(described_class).to receive(:cached_context).and_return(
        { jobs: { mailers: [ { name: "DiasporaDeviseMailer", actions: [], class_actions: %w[mailer_name],
                               parent_class: "Devise::Mailer" } ] } }
      )

      text = described_class.call.content.first[:text]

      expect(text).to include("inherited from `Devise::Mailer`")
    end
  end
end
