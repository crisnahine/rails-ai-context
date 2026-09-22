# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Tools::GetJobPattern do
  before { described_class.reset_cache! }

  describe ".call" do
    it "lists all jobs with default params" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to be_a(String)
      expect(text.length).to be > 0
      expect(text).to include("Background Jobs")
      expect(text).to include("ExampleJob")
    end

    it "lists jobs with queue names for detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("ExampleJob")
      expect(text).to include("default")
    end

    it "lists jobs with retries and dependencies for detail:standard" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("ExampleJob")
    end

    it "shows full detail for all jobs at detail:full" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("ExampleJob")
      expect(text).to include("perform")
    end

    it "shows specific job by class name" do
      result = described_class.call(job: "ExampleJob")
      text = result.content.first[:text]
      expect(text).to include("ExampleJob")
      expect(text).to include("Queue:")
      expect(text).to include("default")
      expect(text).to include("perform(user_id)")
    end

    it "shows specific job by snake_case name" do
      result = described_class.call(job: "example")
      text = result.content.first[:text]
      expect(text).to include("ExampleJob")
    end

    it "returns not-found for unknown job" do
      result = described_class.call(job: "NonexistentJob")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("ExampleJob")
    end

    context "with a rich job fixture" do
      let(:tmpdir) { Dir.mktmpdir }
      let(:jobs_dir) { File.join(tmpdir, "app", "jobs") }

      before do
        FileUtils.mkdir_p(jobs_dir)

        File.write(File.join(jobs_dir, "notify_job.rb"), <<~RUBY)
          class NotifyJob < ApplicationJob
            queue_as :mailers

            retry_on Net::OpenTimeout, attempts: 3, wait: :polynomially_longer
            discard_on ActiveJob::DeserializationError

            def perform(user_id, message:)
              return if User.find_by(id: user_id).nil?

              UserMailer.notification(user_id, message).deliver_later
              Rails.logger.info("Notification sent to user \#{user_id}")
            end
          end
        RUBY

        File.write(File.join(jobs_dir, "cleanup_job.rb"), <<~RUBY)
          class CleanupJob < ApplicationJob
            queue_as :maintenance

            def perform
              Post.where("created_at < ?", 90.days.ago).destroy_all
            end
          end
        RUBY

        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(1_000_000)
        # Files written after boot are not autoloadable, so the booted
        # introspector cannot record them; the static tier's reading is what
        # a real run over this directory would carry.
        static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
        allow(described_class).to receive(:cached_context).and_return(jobs: static)
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "extracts queue name from job" do
        result = described_class.call(job: "NotifyJob")
        text = result.content.first[:text]
        expect(text).to include("mailers")
      end

      it "extracts retry and discard configuration" do
        result = described_class.call(job: "NotifyJob")
        text = result.content.first[:text]
        expect(text).to include("retry_on")
        expect(text).to include("discard_on")
      end

      it "extracts perform signature with keyword args" do
        result = described_class.call(job: "NotifyJob")
        text = result.content.first[:text]
        expect(text).to include("perform(user_id, message:)")
      end

      it "detects side effects like email delivery and logging" do
        result = described_class.call(job: "NotifyJob")
        text = result.content.first[:text]
        expect(text).to include("email delivery")
        expect(text).to include("logging")
      end

      it "shows queue summary when listing all jobs" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]
        expect(text).to include("Queues:")
        expect(text).to include("mailers")
        expect(text).to include("maintenance")
      end
    end

    context "with a job whose retry configuration is parenthesised and spans lines" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        jobs_dir = File.join(tmpdir, "app", "jobs")
        FileUtils.mkdir_p(jobs_dir)
        File.write(File.join(jobs_dir, "sync_job.rb"), <<~RUBY)
          class SyncJob < ApplicationJob
            # retry_on Net::OpenTimeout, attempts: 9 was flaky
            retry_on(
              Net::OpenTimeout, Timeout::Error,
              wait: :polynomially_longer,
              attempts: 3
            )
            discard_on ActiveJob::DeserializationError, ActiveRecord::RecordNotFound
            sidekiq_options retry: 5

            def perform; end
          end
        RUBY

        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
        allow(described_class).to receive(:cached_context).and_return(jobs: static)
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "renders a perform whose parameters span lines on one line, with only its own guards" do
        File.write(File.join(tmpdir, "app", "jobs", "wide_job.rb"), <<~RUBY)
          class WideJob < ApplicationJob
            def perform(user_id,
                        message:, urgent: false)
              return if user_id.nil?
              User.find(user_id)
            end

            def helper
              return unless ready?
            end
          end
        RUBY
        static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
        allow(described_class).to receive(:cached_context).and_return(jobs: static)

        text = described_class.call(job: "WideJob").content.first[:text]

        expect(text).to include("**Perform:** `perform(user_id, message:, urgent: false)`")
        expect(text).to include("- `return if user_id.nil?`")
        expect(text).not_to include("return unless ready?")
      end

      it "reads every retry, discard and sidekiq option as written, and none from a comment" do
        text = described_class.call(job: "SyncJob").content.first[:text]

        expect(text).to include("- retry_on Net::OpenTimeout, Timeout::Error, attempts: 3, wait: :polynomially_longer")
        expect(text).to include("- discard_on ActiveJob::DeserializationError, ActiveRecord::RecordNotFound")
        expect(text).to include("- sidekiq retry: 5")
        expect(text).not_to include("attempts: 9")
      end
    end

    context "with channel data in cached context" do
      let(:channel_payload) do
        {
          jobs: [],
          mailers: [],
          channels: [
            {
              name:           "ChatChannel",
              file:           "app/channels/chat_channel.rb",
              identified_by:  %w[current_user tenant],
              streams:        { stream_from: %w[chat_room_general], stream_for: %w[current_user] },
              periodic:       [
                { method: "ping",            every: "3.seconds" },
                { method: "broadcast_state", every: "-> { current_user.interval }" }
              ],
              actions:        %w[speak],
              stream_methods: %w[subscribed]
            }
          ]
        }
      end

      before do
        allow(described_class).to receive(:cached_context).and_return(jobs: channel_payload)
      end

      it "renders an Action Cable Channels section with all v5.8.0 fields" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Action Cable Channels")
        expect(text).to include("ChatChannel")
        expect(text).to include("app/channels/chat_channel.rb")
        expect(text).to include("current_user")
        expect(text).to include("tenant")
        expect(text).to include("chat_room_general")
        expect(text).to include("ping")
        expect(text).to include("3.seconds")
        expect(text).to include("broadcast_state")
        # Lambda interval must be preserved end-to-end through the render path.
        expect(text).to include("-> { current_user.interval }")
        expect(text).to include("speak")
      end

      it "still works when no jobs exist but channels do" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).not_to include("No jobs found")
        expect(text).to include("ChatChannel")
      end
    end

    context "with no jobs and no channels" do
      before do
        allow(described_class).to receive(:cached_context).and_return(jobs: { jobs: [], mailers: [], channels: [] })
      end

      it "returns the no-async-stuff message" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("No jobs found, and no Action Cable channels detected")
      end
    end

    # The payload decides, not the directory: an app/jobs/ holding only
    # ApplicationJob and no app/jobs/ at all are the same answer.
    context "when the payload records no job" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "jobs"))
        File.write(File.join(tmpdir, "app", "jobs", "application_job.rb"), "class ApplicationJob < ActiveJob::Base\nend\n")

        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
        allow(described_class).to receive(:cached_context).and_return(jobs: static)
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "says no jobs were found" do
        text = described_class.call.content.first[:text]
        expect(text).to include("No jobs found")
        expect(text).to include("not covered by this tool")
      end

      it "gives the same answer for a specific job lookup" do
        text = described_class.call(job: "SendWelcomeEmail").content.first[:text]
        expect(text).to include("No jobs found")
      end
    end

    # An app can run all its async work through Sidekiq workers in app/workers/,
    # which this tool does not read. Saying only that app/jobs/ is empty leaves
    # out the one thing already in hand that says otherwise.
    context "when app/jobs/ is empty but config/sidekiq.yml names queues" do
      let(:sidekiq_config) { { concurrency: 5, queues: %w[default push mailers] } }

      before do
        allow(described_class).to receive(:cached_context)
          .and_return(jobs: { jobs: [], mailers: [], channels: [], sidekiq_config: sidekiq_config })
      end

      it "names the queues it found" do
        text = described_class.call.content.first[:text]
        expect(text).to include("config/sidekiq.yml declares 3 queues: default, push, mailers")
      end

      it "reports the concurrency beside them" do
        text = described_class.call.content.first[:text]
        expect(text).to include("(concurrency: 5)")
      end

      it "keeps saying what it did check" do
        text = described_class.call.content.first[:text]
        expect(text).to include("No jobs found")
      end

      it "says the same on a specific job lookup" do
        text = described_class.call(job: "SendWelcomeEmail").content.first[:text]
        expect(text).to include("config/sidekiq.yml declares 3 queues")
      end

      # A count of what app/jobs/ holds is still a claim about the app's async
      # work, and on an app running most of it through Sidekiq that count is
      # the small half.
      # A job reflection found with no source location still lists: the
      # payload carries its name and queue, and the source adds the rest only
      # when there is one.
      context "and the payload does have a job" do
        before do
          allow(described_class).to receive(:cached_context).and_return(
            jobs: { jobs: [ { name: "PushJob", queue: "push" } ], mailers: [], channels: [], sidekiq_config: sidekiq_config }
          )
        end

        it "names the queues beside the job listing" do
          text = described_class.call.content.first[:text]
          expect(text).to include("# Background Jobs (1)")
          expect(text).to include("**PushJob** [push]")
          expect(text).to include("config/sidekiq.yml declares 3 queues: default, push, mailers")
        end

        it "says the listing does not cover workers the introspector never saw" do
          text = described_class.call.content.first[:text]
          expect(text).to include("Workers the introspector did not see are not covered by this tool.")
        end
      end

      context "when the file has no queues" do
        let(:sidekiq_config) { { concurrency: 5 } }

        it "claims nothing about queues" do
          text = described_class.call.content.first[:text]
          expect(text).not_to include("config/sidekiq.yml")
        end
      end

      context "when there is no sidekiq.yml at all" do
        let(:sidekiq_config) { nil }

        it "claims nothing about queues" do
          text = described_class.call.content.first[:text]
          expect(text).not_to include("config/sidekiq.yml")
        end
      end
    end
  end

  # The job's name does not rebuild its path: a pack job lives where the
  # introspector found it, and the tool reads that file through the payload.
  describe "a job in a pack" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      jobs_dir = File.join(tmpdir, "packs", "billing", "app", "jobs")
      FileUtils.mkdir_p(jobs_dir)
      File.write(File.join(jobs_dir, "invoice_job.rb"), <<~RUBY)
        class InvoiceJob < ApplicationJob
          queue_as :billing

          def perform(invoice_id); end
        end
      RUBY

      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "finds the job by name and reports the file it was read from" do
      text = described_class.call(job: "InvoiceJob").content.first[:text]
      expect(text).to include("# InvoiceJob")
      expect(text).to include("**File:** `packs/billing/app/jobs/invoice_job.rb`")
      expect(text).to include("billing")
    end

    it "names a pack service among the enqueuers" do
      services_dir = File.join(tmpdir, "packs", "billing", "app", "services")
      FileUtils.mkdir_p(services_dir)
      File.write(File.join(services_dir, "send_invoice.rb"), <<~RUBY)
        class SendInvoice
          def call = InvoiceJob.perform_later(1)
        end
      RUBY

      text = described_class.call(job: "InvoiceJob").content.first[:text]
      expect(text).to include("## Enqueued By")
      expect(text).to include("packs/billing/app/services/send_invoice.rb")
    end

    it "finds the job by its snake_case name" do
      text = described_class.call(job: "invoice").content.first[:text]
      expect(text).to include("# InvoiceJob")
    end

    it "lists the recorded jobs when the name matches none" do
      text = described_class.call(job: "Nope").content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("InvoiceJob")
    end
  end

  # The listing reads the same payload the single-job lookup does, so a job
  # in a pack is listed where it was read from.
  describe "the listing over the fixture payload" do
    before do
      allow(Rails.application).to receive(:root).and_return(Pathname.new(IntrospectedFixture::ROOT))
      allow(described_class).to receive(:cached_context).and_return(IntrospectedFixture.context)
    end

    it "lists the pack job with the file it was read from" do
      text = described_class.call(detail: "full").content.first[:text]
      expect(text).to include("## InvoiceJob")
      expect(text).to include("`packs/billing/app/jobs/invoice_job.rb`")
      expect(text).to include("## ExampleJob")
    end

    it "counts the pack job in the summary" do
      text = described_class.call(detail: "summary").content.first[:text]
      expect(text).to include("# Background Jobs (2)")
      expect(text).to include("- InvoiceJob [billing]")
    end
  end

  # An app can run every piece of background work through Sidekiq workers,
  # which are not ActiveJob descendants and do not live in app/jobs.
  describe "an app whose background work is Sidekiq workers" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "workers", "billing", "invoices"))
      File.write(File.join(tmpdir, "app", "workers", "billing", "invoices", "create_worker.rb"), <<~RUBY)
        class Billing::Invoices::CreateWorker
          include Sidekiq::Job
          sidekiq_options queue: :default, retry: 3

          def perform(account_id)
            Billing::Invoices::Create.run(account: Account.find(account_id))
          end
        end
      RUBY
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "lists the worker, its options and its perform signature" do
      text = described_class.call.content.first[:text]

      expect(text).to include("## Sidekiq Workers (1)")
      expect(text).to include("**Billing::Invoices::CreateWorker**")
      expect(text).to include("queue: default")
      expect(text).to include("retry: 3")
      expect(text).to include("perform(account_id)")
    end
  end
end
