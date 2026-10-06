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

  describe "what one mailer declares, renders and previews" do
    let(:tmpdir) { Dir.mktmpdir }

    def write(path, body)
      FileUtils.mkdir_p(File.dirname(File.join(tmpdir, path)))
      File.write(File.join(tmpdir, path), body)
    end

    before do
      write("app/mailers/application_mailer.rb", "class ApplicationMailer < ActionMailer::Base\n  layout \"mailer\"\nend\n")
      write("app/mailers/user_mailer.rb", <<~RUBY)
        class UserMailer < ApplicationMailer
          default from: "users@example.com", reply_to: "help@example.com"
          layout "user_mail"
          before_action :set_user
          after_deliver :log_delivery
          def welcome = mail(to: @user.email)
          def reset = mail(to: @user.email) { |format| format.text }
          private
          def set_user = (@user = params[:user])
          def log_delivery; end
        end
      RUBY
      %w[welcome.html.erb welcome.text.erb reset.text.erb].each { |f| write("app/views/user_mailer/#{f}", "hi") }
      write("test/mailers/previews/user_mailer_preview.rb", "class UserMailerPreview < ActionMailer::Preview\n  def welcome = UserMailer.welcome\nend\n")
      write("lib/mailer_previews/admin_mailer_preview.rb", "class AdminMailerPreview < ActionMailer::Preview\n  def digest; end\nend\n")
      write("config/application.rb", <<~RUBY)
        module App
          class Application < Rails::Application
            config.active_job.queue_name_prefix = "myapp"
            config.action_mailer.preview_paths << "\#{root}/lib/mailer_previews"
            config.action_mailer.interceptors = %w[SandboxInterceptor]
          end
        end
      RUBY
      write("config/initializers/mail.rb", "ActionMailer::Base.register_observer(DeliveryLogObserver)\n")
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "shows the mailer's own declarations, the template formats per action and its preview" do
      text = described_class.call(mailer: "UserMailer").content.first[:text]

      expect(text).to include("- **Declares:** `default from: \"users@example.com\", reply_to: \"help@example.com\"`, " \
                              "`layout \"user_mail\"`, `before_action :set_user`, `after_deliver :log_delivery`")
      expect(text).to include("- **Templates:** reset (text), welcome (html, text)")
      expect(text).to include("- **Preview:** UserMailerPreview (`test/mailers/previews/user_mailer_preview.rb`): welcome")
    end

    it "shows the deliver_later queue, the interceptors, the observers and the preview paths" do
      text = described_class.call.content.first[:text]

      expect(text).to include("**deliver_later queue:** `myapp_mailers`")
      expect(text).to include("**Interceptors:** SandboxInterceptor (`config/application.rb`)")
      expect(text).to include("**Observers:** DeliveryLogObserver (`config/initializers/mail.rb`)")
      expect(text).to include("**Preview paths:** `test/mailers/previews`, `lib/mailer_previews`")
    end

    it "walks each config file once for both the preview paths and the mailer settings" do
      walks = []
      allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk).and_wrap_original { |m, path, *rest| walks << File.read(path) if path.to_s.include?("/config/"); m.call(path, *rest) }
      allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk_source).and_wrap_original { |m, source, *rest| walks << source; m.call(source, *rest) }
      RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call

      expect(walks.count { |source| source.include?("preview_paths <<") }).to eq(1)
    end

    it "never reads a preview linked from outside the app, and survives one it cannot parse" do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "secret_preview.rb"), "class UserMailerPreview < ActionMailer::Preview\n  def leaked; end\nend\n")
        FileUtils.rm(File.join(tmpdir, "test/mailers/previews/user_mailer_preview.rb"))
        File.symlink(File.join(outside, "secret_preview.rb"), File.join(tmpdir, "test/mailers/previews/user_mailer_preview.rb"))
        write("lib/mailer_previews/broken_preview.rb", "class BrokenPreview < ActionMailer::Preview\n  def x(\n")
        static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
        allow(described_class).to receive(:cached_context).and_return(jobs: static)

        text = described_class.call(mailer: "UserMailer").content.first[:text]
        expect(text).not_to include("leaked")
        expect(text).to include("- **Templates:** reset (text), welcome (html, text)")
      end
    end

    def static_text(**args)
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
      described_class.call(**args).content.first[:text]
    end

    it "reads the format after a template's locale, and no format from a locale alone" do
      %w[alert.html.erb alert.es.text.erb notice.es.erb digest.text+phone.erb].each { |f| write("app/views/user_mailer/#{f}", "hi") }
      expect(static_text(mailer: "UserMailer")).to include("alert (html, text)", "notice (any format)", "digest (text)")
    end

    it "names the class an interceptor is built from, and says when the argument is not read" do
      write("config/initializers/mail.rb", <<~RUBY)
        interceptor = RecipientInterceptor.new(ENV["TO"])
        Mail.register_interceptor(interceptor)
        Mail.register_interceptor(StagingInterceptor.new)
        ActionMailer::Base.register_observer(DeliveryLogObserver)
      RUBY
      text = static_text
      expect(text).to include("**Interceptors:** SandboxInterceptor (`config/application.rb`), " \
                              "`interceptor`, not read (`config/initializers/mail.rb`), StagingInterceptor (`config/initializers/mail.rb`)")
      expect(text).to include("**Observers:** DeliveryLogObserver (`config/initializers/mail.rb`)")
    end

    it "names the class ActionMailer camelizes from a symbol or string, and leaves a computed one unread" do
      write("config/application.rb", <<~RUBY)
        module App
          class Application < Rails::Application
            config.action_mailer.interceptors = [:sandbox_interceptor, "staging_interceptor", interceptor_for(env)]
          end
        end
      RUBY
      write("config/initializers/mail.rb", <<~RUBY)
        name = "audit_interceptor"
        ActionMailer::Base.register_interceptor(:audit_interceptor)
        ActionMailer::Base.register_interceptor(name)
        ActionMailer::Base.register_observer("delivery_log_observer")
      RUBY
      text = static_text
      expect(text).to include("SandboxInterceptor (`config/application.rb`), StagingInterceptor (`config/application.rb`)")
      expect(text).to include("AuditInterceptor (`config/initializers/mail.rb`), `name`, not read (`config/initializers/mail.rb`)")
      expect(text).to include("**Observers:** DeliveryLogObserver (`config/initializers/mail.rb`)")
    end

    it "gives no deliver_later queue to an app with no mailers" do
      FileUtils.rm_rf(File.join(tmpdir, "app/mailers"))
      expect(static_text).not_to include("deliver_later queue")
    end

    # load_defaults 6.1 sets deliver_later_queue_name to nil, so mail goes to ActiveJob's default queue.
    it "names ActiveJob's default queue under load_defaults 6.1 or later" do
      write("config/application.rb", "module App\n  class Application < Rails::Application\n    config.load_defaults 7.1\n  end\nend\n")
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)

      expect(described_class.call.content.first[:text]).to include("**deliver_later queue:** `default`")
    end
  end

  describe "Action Mailbox mailboxes" do
    let(:mailbox_data) do
      {
        mailboxes: [ { name: "SupportMailbox", file: "app/mailboxes/support_mailbox.rb", routed_from: [ "/^support@/i" ],
                       callbacks: [ { type: "before_processing", method: "require_user" } ] } ],
        routes: [
          { pattern: "/^support@/i", mailbox: "SupportMailbox", file: "app/mailboxes/application_mailbox.rb" },
          { pattern: ":all", mailbox: "CatchallMailbox", file: "app/mailboxes/application_mailbox.rb" }
        ]
      }
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({ jobs: jobs_data, action_mailbox: mailbox_data })
    end

    it "lists the routing in order and each mailbox with its callbacks" do
      text = described_class.call.content.first[:text]

      expect(text).to include("## Mailboxes (Action Mailbox)")
      expect(text).to include("Routing, first match wins (`app/mailboxes/application_mailbox.rb`):")
      expect(text).to include("1. `/^support@/i` -> SupportMailbox")
      expect(text).to include("2. `:all` -> CatchallMailbox (not defined in app/mailboxes)")
      expect(text).to include("- **SupportMailbox** (`app/mailboxes/support_mailbox.rb`): before_processing :require_user")
    end

    it "leaves mailboxes out of a single mailer's answer" do
      expect(described_class.call(mailer: "UserMailer").content.first[:text]).not_to include("Mailboxes")
    end
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
