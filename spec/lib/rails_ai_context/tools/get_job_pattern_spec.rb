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

    # The scan boundary bounds a jobs listing exactly as it bounds a worker
    # listing, and OpenProject - 74 jobs, no Sidekiq config - was shown one
    # with no word about what had not been read.
    it "says which directories the listing was read from" do
      text = described_class.call.content.first[:text]
      expect(text).to include(described_class::NOT_COVERED)
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

    context "with Solid Queue workers declared in config/queue.yml" do
      let(:tmpdir) { Dir.mktmpdir }

      def answer(queue_yml, **args)
        FileUtils.mkdir_p(File.join(tmpdir, "app/jobs"))
        FileUtils.mkdir_p(File.join(tmpdir, "config"))
        File.write(File.join(tmpdir, "app/jobs/cleanup_job.rb"), "class CleanupJob < ApplicationJob\n  queue_as :maintenance\nend\n")
        File.write(File.join(tmpdir, "app/jobs/mail_job.rb"), "class MailJob < ApplicationJob\n  queue_as :mailers\nend\n")
        File.write(File.join(tmpdir, "config/queue.yml"), queue_yml)
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
        allow(described_class).to receive(:cached_context).and_return(jobs: static)
        described_class.call(**args).content.first[:text]
      end

      after { FileUtils.remove_entry(tmpdir) }

      let(:queue_yml) do
        "default: &default\n  workers:\n    - queues: [ default, mailers ]\n      threads: 3\ntest:\n  <<: *default\ndevelopment:\n  <<: *default\n"
      end

      it "names the queues the workers poll and the job queues none of them polls" do
        text = answer(queue_yml)

        expect(text).to include("config/queue.yml workers poll 2 queues: default, mailers. No worker polls maintenance (CleanupJob).")
      end

      it "says so on the page of a job whose queue no worker polls" do
        expect(answer(queue_yml, job: "CleanupJob")).to include("**Queue:** `maintenance` (no worker in config/queue.yml polls it)")
        expect(answer(queue_yml, job: "MailJob")).to include("**Queue:** `mailers`\n")
      end

      it "leaves the line out when config/queue.yml is not YAML" do
        text = answer("test:\n  workers: [unclosed\n")

        expect(text).to include("**Queues:**")
        expect(text).not_to include("config/queue.yml")
      end

      it "treats a wildcard and a worker without queues as polling everything" do
        text = answer("test:\n  workers:\n    - threads: 1\n    - queues: \"main*\"\n")

        expect(text).to include("config/queue.yml workers poll 2 queues: *, main*.")
        expect(text).not_to include("No worker polls")
      end
    end

    context "with a job that includes ActiveJob::Continuable" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app/jobs"))
        File.write(File.join(tmpdir, "app/jobs/import_job.rb"), <<~RUBY)
          class ImportJob < ApplicationJob
            include ActiveJob::Continuable
            queue_as :default

            def perform(import_id)
              step :fetch do |step|
                step.advance!
              end
              step :process, isolated: true
              step :finish
            end

            private

            def finish; end
          end
        RUBY
        File.write(File.join(tmpdir, "app/jobs/base_continuable_job.rb"), "class BaseContinuableJob < ApplicationJob\n  include ActiveJob::Continuable\nend\n")
        File.write(File.join(tmpdir, "app/jobs/sync_job.rb"), "class SyncJob < BaseContinuableJob\n  def perform\n    step :pull\n  end\nend\n")
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
        allow(described_class).to receive(:cached_context).and_return(jobs: static)
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "marks it continuable and lists its steps in order" do
        text = described_class.call(job: "ImportJob").content.first[:text]

        expect(text).to include("**Continuable:** yes (ActiveJob::Continuable): a retry resumes at the first unfinished step")
        expect(text).to include("## Steps\n1. `fetch` (block)\n2. `process` (method, isolated: true)\n3. `finish` (method)\n\n")
      end

      it "marks a job continuable through its base" do
        text = described_class.call(job: "SyncJob").content.first[:text]

        expect(text).to include("**Continuable:** yes")
        expect(text).to include("1. `pull` (method)")
      end
    end

    context "with what decides when a job runs and what happens after its last retry" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(tmpdir, "app/jobs"))
        FileUtils.mkdir_p(File.join(tmpdir, "app/sidekiq"))
        File.write(File.join(tmpdir, "app/jobs/report_job.rb"), <<~RUBY)
          class ReportJob < ApplicationJob
            queue_as :reports
            queue_with_priority 10
            self.enqueue_after_transaction_commit = true
            retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3, queue: :low, priority: 1, jitter: 0.1
            after_discard { |job, error| Rails.logger.error(error) }
            before_enqueue :b_enq
            around_perform :timed
            after_perform :done
            def perform(user_id); end
          end
        RUBY
        File.write(File.join(tmpdir, "app/jobs/nightly_job.rb"), <<~RUBY)
          class NightlyJob < ApplicationJob
            limits_concurrency to: 1, key: ->(id) { id }, duration: 5.minutes
            def perform(id); end
          end
        RUBY
        File.write(File.join(tmpdir, "app/sidekiq/hard_worker.rb"), <<~RUBY)
          class HardWorker
            include Sidekiq::Job
            sidekiq_options retry: 5
            sidekiq_retry_in { |count| 10 * count }
            sidekiq_retries_exhausted { |msg, ex| Rails.logger.warn(msg) }
            def perform; end
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
        static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
        allow(described_class).to receive(:cached_context).and_return(jobs: static)
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "shows the priority, the transaction setting, every retry option and the callbacks" do
        text = described_class.call(job: "ReportJob").content.first[:text]

        expect(text).to include("**Priority:** 10")
        expect(text).to include("**Enqueue after transaction commit:** true")
        expect(text).to include("- retry_on ActiveRecord::Deadlocked, attempts: 3, wait: 5.seconds, queue: :low, priority: 1, jitter: 0.1")
        expect(text).to include("## Callbacks\n- `after_discard { |job, error| Rails.logger.error(error) }`\n" \
                                "- `before_enqueue :b_enq`\n- `around_perform :timed`\n- `after_perform :done`")
      end

      it "shows a Solid Queue concurrency limit" do
        expect(described_class.call(job: "NightlyJob").content.first[:text])
          .to include("**Concurrency:** `limits_concurrency to: 1, key: ->(id) { id }, duration: 5.minutes`")
      end

      it "shows a Sidekiq worker's backoff block and exhausted handler under its retries" do
        text = described_class.call(job: "HardWorker").content.first[:text]

        expect(text).to include("- sidekiq_retry_in { |count| 10 * count }")
        expect(text).to include("- sidekiq_retries_exhausted { |msg, ex| Rails.logger.warn(msg) }")
      end
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

      it "answers too-large rather than not-found for a job over the cap" do
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(10)

        text = described_class.call(job: "NotifyJob").content.first[:text]
        expect(text).to include("Job file too large to analyze.")
      end

      it "writes a queue sentence as prose, keeping its own backticks whole" do
        File.write(File.join(jobs_dir, "lambda_job.rb"), "class LambdaJob < ApplicationJob\n  queue_as -> { :x }\nend\n")
        static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
        allow(described_class).to receive(:cached_context).and_return(jobs: static)
        label = "#{RailsAiContext::Introspectors::JobIntrospector::PROC_QUEUE}: `-> { :x }`"

        expect(described_class.call(job: "LambdaJob").content.first[:text]).to include("**Queue:** #{label}\n")
        expect(described_class.call(detail: "full").content.first[:text]).to include("- **Queue:** #{label}\n")
      end

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

      it "describes a job that delegates perform, with no guard clauses, in detail and in the listing" do
        File.write(File.join(tmpdir, "app", "jobs", "relay_job.rb"), <<~RUBY)
          class RelayJob < ApplicationJob
            delegate :perform, to: :service
          end
        RUBY
        static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
        allow(described_class).to receive(:cached_context).and_return(jobs: static)

        detail = described_class.call(job: "RelayJob").content.first[:text]
        listing = described_class.call(detail: "full").content.first[:text]

        expect(detail).to include("RelayJob")
        expect(detail).not_to include("## Guard Clauses")
        expect(listing).to include("## RelayJob")
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

      it "names a block timer and the connection's identifiers" do
        payload = channel_payload.merge(
          connections: [ { name: "ApplicationCable::Connection", file: "app/channels/application_cable/connection.rb",
                           identified_by: %w[current_user] } ]
        )
        payload[:channels].first[:periodic] << { block: true, every: "10.seconds" }
        allow(described_class).to receive(:cached_context).and_return(jobs: payload)

        text = described_class.call.content.first[:text]
        expect(text).to include("  - a block every `10.seconds`")
        expect(text).to include("**Connection:** `ApplicationCable::Connection` identified by `current_user`")
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

      # The empty answer names the base it left out, the way a listing does,
      # and the name it offers then answers.
      it "names the base it left out, and answers for it by name" do
        listing = described_class.call.content.first[:text]
        expect(listing).to include("_Base classes not counted as jobs: ApplicationJob.")

        page = described_class.call(job: "ApplicationJob").content.first[:text]
        expect(page).to include("# ApplicationJob")
        expect(page).to include("not counted as a job of its own")
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
          expect(text).to include(described_class::NOT_COVERED)
        end

        # A caveat that named app/workers alone while the scan also read
        # app/jobs and app/sidekiq told a reader the wrong thing about which
        # confident negative they were holding.
        it "names every directory the scan reads" do
          expect(described_class::NOT_COVERED)
            .to include(*RailsAiContext::Introspectors::JobIntrospector::JOB_DIRS)
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

  describe "schedules" do
    let(:tmpdir) { Dir.mktmpdir }

    def write(relative, content)
      path = File.join(tmpdir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    before do
      %w[CleanupJob RecordsJob NightlyJob].each do |name|
        write("app/jobs/#{name.underscore}.rb", "class #{name} < ApplicationJob\n  def perform; end\nend\n")
      end
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
    end

    after { FileUtils.remove_entry(tmpdir) }

    def text_for(**args)
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
      described_class.call(**args).content.first[:text]
    end

    it "names a single job's queue with the configured prefix" do
      write("config/application.rb", "config.active_job.queue_name_prefix = \"myapp\"\n")
      write("app/jobs/cleanup_job.rb", "class CleanupJob < ApplicationJob\n  queue_as :low\n  def perform; end\nend\n")
      expect(text_for(job: "CleanupJob")).to include("**Queue:** `myapp_low`")
    end

    it "reads an interpolated queue_name_prefix as computed, never as a made-up queue name" do
      write("config/application.rb", "config.active_job.queue_name_prefix = \"myapp_\#{Rails.env}\"\n")
      write("app/jobs/cleanup_job.rb", "class CleanupJob < ApplicationJob\n  queue_as :low\n  def perform; end\nend\n")
      text = text_for(job: "CleanupJob")
      expect(text).to include("**Queue:** `\"myapp_\#{Rails.env}\"`_low (computed)")
      expect(text_for).not_to include("[INFERRED]")
    end

    it "reads a constant queue_name_prefix as its source, not as a literal name" do
      write("config/application.rb", "config.active_job.queue_name_prefix = PREFIX\n")
      write("app/jobs/cleanup_job.rb", "class CleanupJob < ApplicationJob\n  queue_as :low\n  def perform; end\nend\n")
      expect(text_for(job: "CleanupJob")).to include("**Queue:** `PREFIX`_low (computed)")
    end

    it "names the condition a queue_name_prefix is set under" do
      write("config/application.rb", "config.active_job.queue_name_prefix = \"myapp\" if ENV[\"PREFIXED\"]\n")
      write("app/jobs/cleanup_job.rb", "class CleanupJob < ApplicationJob\n  queue_as :low\n  def perform; end\nend\n")
      expect(text_for(job: "CleanupJob")).to include("**Queue:** myapp_low (queue_name_prefix set only when `ENV[\"PREFIXED\"]`)")
    end

    it "walks config/application.rb once for the queue settings and the GoodJob cron" do
      write("config/application.rb", <<~RUBY)
        config.active_job.queue_name_prefix = "myapp"
        config.good_job.cron = { nightly: { cron: "0 3 * * *", class: "NightlyJob" } }
      RUBY
      allow(RailsAiContext::Introspectors::Listeners::ConfigAssignmentListener).to receive(:new).and_call_original
      text_for(detail: "full")
      expect(RailsAiContext::Introspectors::Listeners::ConfigAssignmentListener).to have_received(:new).once
    end

    context "with a Solid Queue recurring.yml" do
      before do
        write("config/recurring.yml", <<~YAML)
          # examples:
          #   periodic_cleanup:
          #     class: CleanSoftDeletedRecordsJob
          #     schedule: every hour

          production:
            clear_solid_queue_finished_jobs:
              command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
              schedule: every hour at minute 12
            nightly_cleanup:
              class: CleanupJob
              schedule: every day at 3am
        YAML
      end

      it "gives the task's schedule and environment" do
        expect(text_for(job: "CleanupJob")).to include("**Schedule:** every day at 3am (production, from config/recurring.yml)")
      end

      it "does not count a name inside a comment as scheduled" do
        expect(text_for(job: "RecordsJob")).not_to include("**Schedule:**")
      end

      it "lists every recurring task, a command task included, in the full listing" do
        text = text_for(detail: "full")
        expect(text).to include("## Recurring Tasks")
        expect(text).to include("- `clear_solid_queue_finished_jobs`: `SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)` " \
                                "every hour at minute 12 (production, from config/recurring.yml)")
        expect(text).to include("- `nightly_cleanup`: `CleanupJob` every day at 3am (production, from config/recurring.yml)")
      end
    end

    it "reads GoodJob cron from config/application.rb" do
      write("config/application.rb", <<~RUBY)
        module App
          class Application < Rails::Application
            config.good_job.enable_cron = true
            config.good_job.cron = {
              nightly: { cron: "0 3 * * *", class: "NightlyJob" }
            }
          end
        end
      RUBY
      expect(text_for(job: "NightlyJob")).to include("**Schedule:** 0 3 * * * (from config/application.rb)")
    end

    it "reads a whenever config/schedule.rb runner" do
      write("config/schedule.rb", <<~RUBY)
        every 1.day, at: "4:30 am" do
          runner "CleanupJob.perform_later"
        end
      RUBY
      expect(text_for(job: "CleanupJob")).to include("**Schedule:** every 1.day at 4:30 am (from config/schedule.rb)")
    end

    it "reads a sidekiq-cron schedule.yml by class, not by substring" do
      write("config/schedule.yml", <<~YAML)
        records_cleanup:
          cron: "*/5 * * * *"
          class: "CleanSoftDeletedRecordsJob"
        nightly:
          cron: "0 3 * * *"
          class: "NightlyJob"
      YAML
      expect(text_for(job: "NightlyJob")).to include("**Schedule:** 0 3 * * * (from config/schedule.yml)")
      expect(text_for(job: "RecordsJob")).not_to include("**Schedule:**")
    end

    it "reads a sidekiq-scheduler entry in config/sidekiq.yml, named for its job when no class is given" do
      write("config/sidekiq.yml", <<~YAML)
        :scheduler:
          :schedule:
            NightlyJob:
              every: "1h"
      YAML
      expect(text_for(job: "NightlyJob")).to include("**Schedule:** 1h (from config/sidekiq.yml)")
    end

    it "reads a computed GoodJob cron schedule as computed, not as a marker" do
      write("config/initializers/good_job.rb", <<~RUBY)
        Rails.application.configure do
          config.good_job.cron = { nightly: { cron: ENV.fetch("NIGHTLY_CRON"), class: "NightlyJob" } }
        end
      RUBY
      text = text_for(job: "NightlyJob")
      expect(text).to include("**Schedule:** computed (from config/initializers/good_job.rb)")
      expect(text).not_to include("[INFERRED]")
    end

    it "reads a GoodJob cron held in a constant as no schedule" do
      write("config/initializers/good_job.rb", "Rails.application.configure { config.good_job.cron = CRON }\n")
      expect(text_for(job: "NightlyJob")).not_to include("**Schedule:**")
    end

    it "reads a malformed schedule file as no schedule" do
      write("config/recurring.yml", "production: [unclosed\n")
      write("config/schedule.yml", "--- just a string\n")
      write("config/schedule.rb", "every do\n")
      expect(text_for(job: "CleanupJob")).not_to include("**Schedule:**")
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

  # A job the introspector could not place is still listed, and the listing
  # has to say so rather than let it read as an ActiveJob job.
  describe "a job whose base class the scan could not resolve" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "jobs"))
      File.write(File.join(tmpdir, "app", "jobs", "archive.rb"), <<~RUBY)
        class Archive
          @queue = :file_serve

          def self.perform(id)
            Upload.find(id).archive!
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "jobs", "send_email_job.rb"), <<~RUBY)
        class SendEmailJob < ActiveJob::Base
          queue_as :default

          def perform(id); end
        end
      RUBY
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "marks it in the listing" do
      text = described_class.call.content.first[:text]

      expect(text).to include("**Archive** [file_serve] [unknown base]")
      expect(text).to include("**SendEmailJob** [default]")
    end

    it "counts it under its own heading in the queue summary" do
      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).to include("- Archive [file_serve] [unknown base]")
      expect(text).to include("**Queues:** file_serve(1), default(1)")
    end

    it "says so on the job's own page" do
      text = described_class.call(job: "Archive").content.first[:text]

      expect(text).to include("no ActiveJob or Sidekiq ancestry")
      expect(text).to include("**Queue:** `file_serve`")
    end
  end

  describe "a Que job" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "jobs"))
      File.write(File.join(tmpdir, "app", "jobs", "mail_job.rb"), <<~RUBY)
        class MailJob < Que::Job
          self.queue = "mail"
          def run(account_id)
            Account.find(account_id)
          end
        end
      RUBY
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "is listed on its queue, and answers by name with its run signature" do
      expect(described_class.call(detail: "full").content.first[:text]).to include("**Queues:** mail(1)", "## MailJob")

      text = described_class.call(job: "MailJob").content.first[:text]
      expect(text).to include("**Queue:** `mail`", "**Perform:** `run(account_id)`")
      expect(text).not_to include("not found")
    end

    it "does not take run as the entry point of an ActiveJob job" do
      File.write(File.join(tmpdir, "app", "jobs", "sync_job.rb"), "class SyncJob < ApplicationJob\n  def run(step)\n    return if step.nil?\n  end\nend\n")
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)

      expect(described_class.call(job: "SyncJob").content.first[:text]).not_to include("run(step)", "Guard")
      expect(described_class.call(job: "MailJob").content.first[:text]).to include("**Perform:** `run(account_id)`")
      expect(described_class.call(detail: "full").content.first[:text]).to include("- **Perform:** `run(account_id)`")
    end
  end

  # The job's own file was skipped by a substring of its underscored name: a
  # job under an acronym folder listed itself, and a helper whose name merely
  # contained the job's was dropped.
  describe "who enqueues a job" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "workers", "activitypub"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "services"))
      File.write(File.join(tmpdir, "app", "workers", "activitypub", "sync_job.rb"), <<~RUBY)
        class ActivityPub::SyncJob
          include Sidekiq::Job

          def perform(id)
            ActivityPub::SyncJob.perform_async(id + 1) if id < 3
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "services", "activity_pub_sync_job_helper.rb"), <<~RUBY)
        class ActivityPubSyncJobHelper
          def self.call(id) = ActivityPub::SyncJob.perform_async(id)
        end
      RUBY
      File.write(File.join(tmpdir, "app", "services", "other_sync.rb"), <<~RUBY)
        class OtherSync
          def self.call(id) = Admin::ActivityPub::SyncJob.perform_async(id)
        end
      RUBY
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
    end

    after { FileUtils.remove_entry(tmpdir) }

    # Read off the call nodes: a call written in a comment enqueues nothing,
    # `Job.set(...)` is the job's own call whatever follows it, and Sidekiq's
    # scheduling calls enqueue too.
    it "counts the calls the code makes, not the words in its comments" do
      File.write(File.join(tmpdir, "app", "services", "commented.rb"), <<~RUBY)
        class Commented
          # ActivityPub::SyncJob.perform_async(id) used to run here
          def self.call(id); end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "services", "delayed.rb"), <<~RUBY)
        class Delayed
          def self.call(id)
            ::ActivityPub::SyncJob.set(queue: :low).perform_async(id)
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "services", "scheduled.rb"), <<~RUBY)
        class Scheduled
          def self.call(id) = ActivityPub::SyncJob.perform_in(5.minutes, id)
        end
      RUBY

      text = described_class.call(job: "ActivityPub::SyncJob").content.first[:text]
      enqueuers = text[/## Enqueued By\n(.*?)(\n\n|\z)/m, 1].to_s

      expect(enqueuers).to include("app/services/delayed.rb")
      expect(enqueuers).to include("app/services/scheduled.rb")
      expect(enqueuers).not_to include("app/services/commented.rb")
    end

    # A worker enqueued from six files had three listed. Sidekiq's bulk push and ActiveJob's perform_all_later of
    # the job's instances are enqueues too.
    it "counts a bulk push and a perform_all_later of the job's instances" do
      File.write(File.join(tmpdir, "app", "services", "bulk.rb"), <<~RUBY)
        class Bulk
          def self.call(ids) = ActivityPub::SyncJob.perform_bulk(ids.map { |id| [ id ] })
        end
      RUBY
      File.write(File.join(tmpdir, "app", "services", "all_later.rb"), <<~RUBY)
        class AllLater
          def self.call(ids) = ActiveJob.perform_all_later(ids.map { |id| ActivityPub::SyncJob.new(id) })
        end
      RUBY

      text = described_class.call(job: "ActivityPub::SyncJob").content.first[:text]
      enqueuers = text[/## Enqueued By\n(.*?)(\n\n|\z)/m, 1].to_s

      expect(enqueuers).to include("app/services/bulk.rb")
      expect(enqueuers).to include("app/services/all_later.rb")
    end

    # A backfill worker enqueued from a rake task read as enqueued by nothing
    # when only .rb files were read. Rake tasks, bin/ and
    # script/ programs and the seeds run the app's Ruby too.
    it "reads the rake tasks, bin/, script/ and seeds the app runs" do
      FileUtils.mkdir_p(File.join(tmpdir, "lib", "tasks", "archived"))
      FileUtils.mkdir_p(File.join(tmpdir, "bin"))
      FileUtils.mkdir_p(File.join(tmpdir, "script"))
      FileUtils.mkdir_p(File.join(tmpdir, "db"))
      File.write(File.join(tmpdir, "lib", "tasks", "archived", "backfill.rake"), <<~RUBY)
        namespace :backfill do
          task sync: :environment do
            ActivityPub::SyncJob.perform_async(1)
          end
        end
      RUBY
      File.write(File.join(tmpdir, "bin", "resync"), "#!/usr/bin/env ruby\nActivityPub::SyncJob.perform_async(2)\n")
      File.write(File.join(tmpdir, "script", "resync_all.rb"), "ActivityPub::SyncJob.perform_async(3)\n")
      File.write(File.join(tmpdir, "db", "seeds.rb"), "ActivityPub::SyncJob.perform_async(4)\n")

      text = described_class.call(job: "ActivityPub::SyncJob").content.first[:text]
      enqueuers = text[/## Enqueued By\n(.*?)(\n\n|\z)/m, 1].to_s

      expect(enqueuers).to include("lib/tasks/archived/backfill.rake", "bin/resync", "script/resync_all.rb", "db/seeds.rb")
    end

    # Migrations enqueue backfills too; db/ was read for the seeds alone.
    it "reads the migrations and anything else under db/" do
      FileUtils.mkdir_p(File.join(tmpdir, "db", "migrate"))
      File.write(File.join(tmpdir, "db", "migrate", "20230322131827_backfill.rb"), <<~RUBY)
        class Backfill < ActiveRecord::Migration[7.0]
          def up = ActivityPub::SyncJob.perform_async
        end
      RUBY

      text = described_class.call(job: "ActivityPub::SyncJob").content.first[:text]

      expect(text[/## Enqueued By\n(.*?)(\n\n|\z)/m, 1].to_s).to include("db/migrate/20230322131827_backfill.rb")
    end

    # The list stopped at twenty with no word that it had.
    it "says how many more callers there are past the ones it names" do
      25.times do |i|
        File.write(File.join(tmpdir, "app", "services", "caller_#{i}.rb"),
                   "class Caller#{i}\n  def self.call = ActivityPub::SyncJob.perform_async(#{i})\nend\n")
      end

      text = described_class.call(job: "ActivityPub::SyncJob").content.first[:text]
      enqueuers = text[/## Enqueued By\n(.*?)(\n\n|\z)/m, 1].to_s

      expect(enqueuers.lines.grep(/\A- /).size).to eq(20)
      expect(enqueuers).to match(/_\.\.\.and \d+ more\._/)
    end

    it "leaves out the job's own file and keeps a caller whose name contains the job's" do
      text = described_class.call(job: "ActivityPub::SyncJob").content.first[:text]
      enqueuers = text[/## Enqueued By\n(.*?)(\n\n|\z)/m, 1].to_s

      expect(enqueuers).to include("app/services/activity_pub_sync_job_helper.rb")
      expect(enqueuers).not_to include("app/workers/activitypub/sync_job.rb")
      expect(enqueuers).not_to include("app/services/other_sync.rb")
    end
  end

  # Ruby resolves a bare constant from the enclosing namespace outward: inside
  # `module Admin`, `SyncJob.perform_later` is Admin::SyncJob where that
  # exists, and is nobody's call to the top-level SyncJob.
  describe "a caller naming a job relative to its namespace" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "jobs", "admin"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "controllers", "admin"))
      File.write(File.join(tmpdir, "app", "jobs", "sync_job.rb"), "class SyncJob < ActiveJob::Base\n  def perform; end\nend\n")
      File.write(File.join(tmpdir, "app", "jobs", "admin", "sync_job.rb"), <<~RUBY)
        module Admin
          class SyncJob < ActiveJob::Base
            def perform; end
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "controllers", "admin", "reports_controller.rb"), <<~RUBY)
        module Admin
          class ReportsController < ApplicationController
            def create = SyncJob.perform_later
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "controllers", "reports_controller.rb"), <<~RUBY)
        class ReportsController < ApplicationController
          def create = SyncJob.perform_later
        end
      RUBY
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
    end

    after { FileUtils.remove_entry(tmpdir) }

    def enqueuers_of(job)
      described_class.call(job: job).content.first[:text][/## Enqueued By\n(.*?)(\n\n|\z)/m, 1].to_s
    end

    it "credits the namespaced job with the call its namespace resolves to" do
      expect(enqueuers_of("Admin::SyncJob")).to include("app/controllers/admin/reports_controller.rb")
      expect(enqueuers_of("Admin::SyncJob")).not_to include("app/controllers/reports_controller.rb")
    end

    # A callback block runs in the class body, and a block does not change
    # Module.nesting: the job it names resolves from the class around it,
    # exactly as in a method.
    it "resolves a call in a class-body callback block from the class around it" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "admin"))
      File.write(File.join(tmpdir, "app", "models", "admin", "report.rb"), <<~RUBY)
        module Admin
          class Report < ApplicationRecord
            after_commit { SyncJob.perform_later }
          end
        end
      RUBY

      expect(enqueuers_of("Admin::SyncJob")).to include("app/models/admin/report.rb")
      expect(enqueuers_of("SyncJob")).not_to include("app/models/admin/report.rb")
    end

    # `class Admin::Exports` puts only Admin::Exports on Module.nesting, not
    # Admin: a bare SyncJob there is the top-level job, where the nested
    # `module Admin; class Exports` form would find Admin::SyncJob.
    it "reads a compact class name's scope the way Ruby does" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "services", "admin"))
      File.write(File.join(tmpdir, "app", "services", "admin", "exports.rb"), <<~RUBY)
        class Admin::Exports
          def self.call = SyncJob.perform_later
        end
      RUBY

      expect(enqueuers_of("SyncJob")).to include("app/services/admin/exports.rb")
      expect(enqueuers_of("Admin::SyncJob")).not_to include("app/services/admin/exports.rb")
    end

    it "does not credit the top-level job with it" do
      expect(enqueuers_of("SyncJob")).to include("app/controllers/reports_controller.rb")
      expect(enqueuers_of("SyncJob")).not_to include("app/controllers/admin/reports_controller.rb")
    end
  end

  # Diaspora's 43 workers each printed their bases' two long sidekiq_options
  # expressions - about 60 repeated lines of the same text. An inherited
  # option is named once with where it comes from, its value only when short;
  # the base's own page carries the whole expression.
  describe "options a worker inherits" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "workers", "mail"))
      File.write(File.join(tmpdir, "app", "workers", "base_worker.rb"), <<~RUBY)
        class BaseWorker
          include Sidekiq::Worker

          sidekiq_options backtrace: (bt = AppConfig.environment.sidekiq.backtrace.get) && bt.to_i,
                          retry:     (rt = AppConfig.environment.sidekiq.retry.get) && rt.to_i
        end
      RUBY
      File.write(File.join(tmpdir, "app", "workers", "mail", "notifier_base_worker.rb"), <<~RUBY)
        module Mail
          class NotifierBaseWorker < ::BaseWorker
            sidekiq_options queue: :low
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "workers", "mail", "liked_worker.rb"), <<~RUBY)
        module Mail
          class LikedWorker < NotifierBaseWorker
            sidekiq_options unique: true

            def perform(id); end
          end
        end
      RUBY
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "names an inherited option once, with its source, and its value only when short" do
      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).to include("- **Mail::LikedWorker** [unique: true; queue: low (from Mail::NotifierBaseWorker); " \
                              "backtrace, retry (from BaseWorker)]")
      expect(text).not_to include("AppConfig.environment.sidekiq.retry.get) && rt.to_i, queue")
    end

    it "keeps the whole expression on the base's own page" do
      text = described_class.call(job: "BaseWorker").content.first[:text]

      expect(text).to include("retry: (rt = AppConfig.environment.sidekiq.retry.get) && rt.to_i")
    end
  end

  # Discourse enqueues through a helper of its own: `Jobs.enqueue(:process_post)`
  # names Jobs::ProcessPost by a symbol, `enqueue_in(delay, name)` puts the
  # delay first, and "chat/foo" spells a namespaced job. None of it names the
  # constant, so no enqueuer was ever listed.
  describe "enqueues through the app's own helper" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "jobs", "regular", "chat"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models"))
      FileUtils.mkdir_p(File.join(tmpdir, "lib"))
      File.write(File.join(tmpdir, "app", "jobs", "base.rb"), <<~RUBY)
        module Jobs
          def self.enqueue(job, opts = {})
            klass = job.instance_of?(Class) ? job : "::Jobs::\#{job.to_s.camelcase}".constantize
            klass.perform_async(opts)
          end

          def self.enqueue_in(secs, job_name, opts = {})
            enqueue(job_name, opts.merge!(delay_for: secs))
          end

          class Base
            include Sidekiq::Worker
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "jobs", "regular", "process_post.rb"), <<~RUBY)
        module Jobs
          class ProcessPost < ::Jobs::Base
            def execute(args); end
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "jobs", "regular", "chat", "notify.rb"), <<~RUBY)
        module Jobs
          module Chat
            class Notify < ::Jobs::Base
              def execute(args); end
            end
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "jobs", "regular", "unused.rb"), <<~RUBY)
        module Jobs
          class Unused < ::Jobs::Base
            def execute(args); end
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "models", "post.rb"), <<~RUBY)
        class Post
          def rebake! = Jobs.enqueue(:process_post, post_id: id)
          def notify = Jobs.enqueue("chat/notify", post_id: id)
        end
      RUBY
      File.write(File.join(tmpdir, "lib", "post_revisor.rb"), <<~RUBY)
        class PostRevisor
          def revise = ::Jobs.enqueue_in(5.seconds, :process_post, post_id: 1)
          def notify = Jobs.enqueue(Jobs::Chat::Notify, post_id: 1)
        end
      RUBY
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
    end

    after { FileUtils.remove_entry(tmpdir) }

    def enqueuers_of(job)
      described_class.call(job: job).content.first[:text][/## Enqueued By\n(.*?)(\n\n|\z)/m, 1].to_s
    end

    it "lists a caller that names the job by the helper's symbol, before or after a delay" do
      enqueuers = enqueuers_of("Jobs::ProcessPost")

      expect(enqueuers).to include("app/models/post.rb")
      expect(enqueuers).to include("lib/post_revisor.rb")
    end

    it "resolves a namespaced spelling and a class argument" do
      enqueuers = enqueuers_of("Jobs::Chat::Notify")

      expect(enqueuers).to include("app/models/post.rb")
      expect(enqueuers).to include("lib/post_revisor.rb")
    end

    # An absent section read as "nothing enqueues it" whether or not anything
    # had been looked for.
    it "says so when it finds no enqueue call" do
      text = described_class.call(job: "Jobs::Unused").content.first[:text]

      expect(text).to include("## Enqueued By")
      expect(text).to include("_No enqueue calls found in app/, lib/ (rake tasks included), bin/, script/ or db/ (migrations and seeds)")
    end
  end

  # Discourse's 236 jobs implement `execute`; `perform` is on Jobs::Base and
  # runs it. Reading only `perform` left every one of them with no signature
  # and no guard clauses.
  describe "a worker whose entry point is execute" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "jobs", "regular"))
      File.write(File.join(tmpdir, "app", "jobs", "base.rb"), <<~RUBY)
        module Jobs
          class Base
            include Sidekiq::Worker

            def perform(*args); end
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "jobs", "regular", "anonymize_user.rb"), <<~RUBY)
        module Jobs
          class AnonymizeUser < ::Jobs::Base
            sidekiq_options queue: "low"

            def execute(args)
              return if args[:user_id].nil?

              UserAnonymizer.new(args[:user_id]).make_anonymous
            end
          end
        end
      RUBY
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "reads the signature off execute in the listing" do
      text = described_class.call.content.first[:text]

      expect(text).to include("**Jobs::AnonymizeUser** [queue: low]")
      expect(text).to include("execute(args)")
    end

    it "reads its guards and its calls on its own page" do
      text = described_class.call(job: "Jobs::AnonymizeUser").content.first[:text]

      expect(text).to include("execute(args)")
      expect(text).to include("return if args[:user_id].nil?")
      expect(text).to include("UserAnonymizer.new")
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
          sidekiq_throttle(concurrency: { limit: 1 }, threshold: { limit: 10, period: 1.minute })

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

    # The bracket reads as the worker's run constraints, and a throttle is
    # the constraint that decides how fast it actually runs.
    it "names the throttle the worker declares" do
      text = described_class.call.content.first[:text]

      expect(text).to include("throttle: concurrency { limit: 1 }, threshold { limit: 10, period: 1.minute }")
    end

    # The app names its Sidekiq config config/sidekiq_production.yml, which
    # is what a multi-environment app tends to do, so there is no
    # config/sidekiq.yml to hang the caveat on.
    it "says the listing does not cover workers it never saw, with no config/sidekiq.yml" do
      text = described_class.call.content.first[:text]

      expect(text).to include(described_class::NOT_COVERED)
    end

    it "answers the worker name the listing just printed" do
      text = described_class.call(job: "Billing::Invoices::CreateWorker").content.first[:text]

      expect(text).to include("# Billing::Invoices::CreateWorker")
      expect(text).to include("app/workers/billing/invoices/create_worker.rb")
      expect(text).not_to include("No jobs found")
    end

    # The listing shows the queue and the throttle; asking about the same
    # worker by name showed less than the list it was copied from.
    it "carries the worker's queue and throttle into its own page" do
      text = described_class.call(job: "Billing::Invoices::CreateWorker").content.first[:text]

      expect(text).to include("**Queue:** `default`")
      expect(text).to include("**Throttle:** concurrency { limit: 1 }, threshold { limit: 10, period: 1.minute }")
    end

    # A Sidekiq class listed as a worker rather than a job showed less about
    # itself than the job listing had: no size, no retries, and nothing about
    # what it calls.
    it "shows the worker's size, retries and calls, as the job listing did" do
      text = described_class.call.content.first[:text]

      expect(text).to include("(9 lines)")
      expect(text).to include("→ Account.find")
    end

    # An ActiveInteraction service is invoked with .run / .run!, and the verb
    # list had neither, so a worker whose whole body is one service call
    # showed nothing under calls.
    it "names a service the worker runs" do
      text = described_class.call.content.first[:text]

      expect(text).to include("Billing::Invoices::Create.run")
    end

    # The record carried the first source line of the macro, so a retry_on
    # written across lines printed as "ActiveRecord::Deadlocked," - a dangling
    # comma, no macro name and none of its options.
    it "prints a multi-line retry the way the single job page does" do
      File.write(File.join(tmpdir, "app", "workers", "billing", "invoices", "slow_worker.rb"), <<~RUBY)
        class Billing::Invoices::SlowWorker
          include Sidekiq::Job

          retry_on ActiveRecord::Deadlocked,
                   wait: 5.seconds,
                   attempts: 3

          def perform(id); end
        end
      RUBY
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)

      text = described_class.call.content.first[:text]

      expect(text).to include("**Billing::Invoices::SlowWorker** (9 lines) - retry_on ActiveRecord::Deadlocked, attempts: 3, wait: 5.seconds")
    end

    # The jobs listing dropped the bases with no word, while the service and
    # mailer listings named theirs.
    it "names the base classes it left out, in the words the other listings use" do
      File.write(File.join(tmpdir, "app", "workers", "billing", "invoices", "base_worker.rb"), <<~RUBY)
        class Billing::Invoices::BaseWorker
          include Sidekiq::Job
        end
      RUBY
      File.write(File.join(tmpdir, "app", "workers", "billing", "invoices", "retry_worker.rb"), <<~RUBY)
        class Billing::Invoices::RetryWorker < Billing::Invoices::BaseWorker
          def perform(id); end
        end
      RUBY
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)

      text = described_class.call.content.first[:text]

      expect(text).to include("_Base classes not counted as jobs: Billing::Invoices::BaseWorker. " \
                              "Ask for one by name for what it defines._")
      expect(text).not_to include("**Billing::Invoices::BaseWorker**")
    end

    # The listing says a base can be asked for by name, the way the service
    # listing does, and asking answered "not found" with an unrelated
    # suggestion.
    it "answers a base class asked for by name" do
      File.write(File.join(tmpdir, "app", "workers", "billing", "invoices", "base_worker.rb"), <<~RUBY)
        class Billing::Invoices::BaseWorker
          include Sidekiq::Job
          sidekiq_options queue: :default

          def perform(id)
            raise NotImplementedError
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "workers", "billing", "invoices", "retry_worker.rb"), <<~RUBY)
        class Billing::Invoices::RetryWorker < Billing::Invoices::BaseWorker
          def perform(id); end
        end
      RUBY
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)

      text = described_class.call(job: "Billing::Invoices::BaseWorker").content.first[:text]

      expect(text).to include("# Billing::Invoices::BaseWorker")
      expect(text).to include("app/workers/billing/invoices/base_worker.rb")
      expect(text).to include("other jobs inherit from it")
      expect(text).not_to include("not found")
    end

    # A base worker that throttles every worker below it with a mixin and a
    # sidekiq_throttle had a page naming neither, nor who inherits it.
    it "shows a base's mixins, throttle and heirs" do
      File.write(File.join(tmpdir, "app", "workers", "billing", "invoices", "base_worker.rb"), <<~RUBY)
        class Billing::Invoices::BaseWorker
          include Sidekiq::Worker
          include Sidekiq::Throttled::Worker

          sidekiq_throttle(
            concurrency: { limit: 1 }
          )
        end
      RUBY
      File.write(File.join(tmpdir, "app", "workers", "billing", "invoices", "archive_worker.rb"), <<~RUBY)
        class Billing::Invoices::ArchiveWorker < Billing::Invoices::BaseWorker
          def perform(id); end
        end
      RUBY
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)

      text = described_class.call(job: "Billing::Invoices::BaseWorker").content.first[:text]

      expect(text).to include("- `include Sidekiq::Throttled::Worker`")
      expect(text).to include("- `sidekiq_throttle(concurrency: { limit: 1 })`")
      expect(text).to include("**Inherited by (1):** Billing::Invoices::ArchiveWorker")
    end

    # Mastodon's Fasp::BaseWorker declares the queue every Fasp worker runs on,
    # and its own page left it out: the file, "not counted as a job", nothing
    # it declares.
    it "shows what a base declares for the jobs that inherit it" do
      File.write(File.join(tmpdir, "app", "workers", "billing", "invoices", "base_worker.rb"), <<~RUBY)
        class Billing::Invoices::BaseWorker
          include Sidekiq::Worker

          sidekiq_options queue: 'fasp', retry: 3
          retry_on Net::OpenTimeout, attempts: 2

          private

          def with_provider(provider); end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "workers", "billing", "invoices", "retry_worker.rb"), <<~RUBY)
        class Billing::Invoices::RetryWorker < Billing::Invoices::BaseWorker
          def perform(id); end
        end
      RUBY
      static = RailsAiContext::Introspectors::JobIntrospector.new(RailsAiContext::StaticApp.new(tmpdir)).static_call
      allow(described_class).to receive(:cached_context).and_return(jobs: static)

      text = described_class.call(job: "Billing::Invoices::BaseWorker").content.first[:text]

      expect(text).to include("**Queue:** `fasp`")
      expect(text).to include("**Options:** queue: fasp, retry: 3")
      expect(text).to include("- retry_on Net::OpenTimeout, attempts: 2")
      expect(text).to include("- sidekiq retry: 3")
    end

    # 346 files re-read on Discourse to print what the walk had already parsed.
    it "prints them from the record, without reading the file again" do
      FileUtils.rm_rf(File.join(tmpdir, "app", "workers"))

      text = described_class.call.content.first[:text]

      expect(text).to include("(9 lines)")
      expect(text).to include("→ Account.find")
    end

    it "leaves them out at summary detail" do
      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).not_to include("(9 lines)")
    end

    # A worker record with no file cannot be read from disk, and joining nil
    # onto the root raises rather than answering.
    it "answers with what it holds when the worker record carries no file" do
      allow(described_class).to receive(:cached_context).and_return(
        jobs: { jobs: [], workers: [ { name: "Billing::Invoices::CreateWorker", options: { "queue" => "default" } } ] }
      )

      text = described_class.call(job: "Billing::Invoices::CreateWorker").content.first[:text]

      expect(text).to include("Billing::Invoices::CreateWorker")
      expect(text).to include("queue: default")
    end

    it "lists the worker among the known names when the query matches nothing" do
      text = described_class.call(job: "NoSuchThing").content.first[:text]

      expect(text).to include("not found")
      expect(text).to include("Billing::Invoices::CreateWorker")
    end
  end

  # A scheduled enqueue and the app's own helper enqueue as surely as
  # perform_later does, and a comment naming one does not.
  describe "the job enqueue side effect" do
    before do
      allow(described_class).to receive(:cached_context)
        .and_return(jobs: { enqueue_helpers: [ { owner: "Jobs", method: "enqueue", job_arg: 0 } ] })
    end

    it "is read off the enqueue calls" do
      expect(described_class.send(:extract_side_effects, "RefreshWorker.perform_in(5.minutes)")).to include("job enqueue")
      expect(described_class.send(:extract_side_effects, "Jobs.enqueue(:process_post)")).to include("job enqueue")
      expect(described_class.send(:extract_side_effects, "# SyncJob.perform_later\nx = 1")).not_to include("job enqueue")
    end
  end
end
