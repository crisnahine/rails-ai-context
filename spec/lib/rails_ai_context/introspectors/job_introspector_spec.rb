# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::JobIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns jobs array" do
      expect(result[:jobs]).to be_an(Array)
    end

    it "returns mailers array" do
      expect(result[:mailers]).to be_an(Array)
    end

    it "returns channels array" do
      expect(result[:channels]).to be_an(Array)
    end
  end

  describe "source parsing fallback" do
    let(:fixture_job) { File.join(Rails.root, "app/jobs/cleanup_job.rb") }

    before do
      File.write(fixture_job, <<~RUBY)
        class CleanupJob < ApplicationJob
          queue_as :low_priority

          retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3
          discard_on ActiveJob::DeserializationError

          def perform(user_id, options = {})
            # cleanup logic
          end
        end
      RUBY
    end

    after { FileUtils.rm_f(fixture_job) }

    it "extracts job details from source files" do
      jobs = introspector.send(:extract_jobs_from_source)
      cleanup = jobs.find { |j| j[:name] == "CleanupJob" }
      expect(cleanup).not_to be_nil
      expect(cleanup[:queue]).to eq("low_priority")
    end

    it "extracts retry_on declarations from source" do
      jobs = introspector.send(:extract_jobs_from_source)
      cleanup = jobs.find { |j| j[:name] == "CleanupJob" }
      expect(cleanup[:retry_on]).to be_an(Array)
      expect(cleanup[:retry_on].first).to include("ActiveRecord::Deadlocked")
    end

    it "extracts discard_on declarations from source" do
      jobs = introspector.send(:extract_jobs_from_source)
      cleanup = jobs.find { |j| j[:name] == "CleanupJob" }
      expect(cleanup[:discard_on]).to be_an(Array)
      expect(cleanup[:discard_on].first).to include("ActiveJob::DeserializationError")
    end

    it "extracts perform method signature from source" do
      jobs = introspector.send(:extract_jobs_from_source)
      cleanup = jobs.find { |j| j[:name] == "CleanupJob" }
      expect(cleanup[:perform_signature]).to eq("user_id, options = {}")
    end

    it "skips ApplicationJob in source parsing" do
      jobs = introspector.send(:extract_jobs_from_source)
      names = jobs.map { |j| j[:name] }
      expect(names).not_to include("ApplicationJob")
    end
  end

  describe "channel source parsers" do
    let(:source) do
      <<~RUBY
        class ChatChannel < ApplicationCable::Channel
          identified_by :current_user, :tenant

          periodically :ping, every: 3.seconds
          periodically :sync_state, every: 30.seconds

          def subscribed
            stream_from "chat_room_general"
            stream_for current_user
          end

          def speak(data)
            ActionCable.server.broadcast("chat", data)
          end

          def stream_audio
          end
        end
      RUBY
    end

    it "extracts identified_by attributes" do
      expect(introspector.send(:extract_identified_by, source)).to contain_exactly("current_user", "tenant")
    end

    it "extracts stream_from and stream_for targets" do
      streams = introspector.send(:extract_channel_streams, source)
      expect(streams[:stream_from]).to include("chat_room_general")
      expect(streams[:stream_for]).to include("current_user")
    end

    it "extracts periodically timers with intervals" do
      timers = introspector.send(:extract_channel_periodic, source)
      expect(timers).to be_an(Array)
      expect(timers).to include(a_hash_including(method: "ping",       every: "3.seconds"))
      expect(timers).to include(a_hash_including(method: "sync_state", every: "30.seconds"))
    end

    it "preserves complex intervals like lambdas without truncating them" do
      complex = <<~RUBY
        class TickerChannel < ApplicationCable::Channel
          periodically :broadcast, every: -> { current_user.interval }
        end
      RUBY
      timers = introspector.send(:extract_channel_periodic, complex)
      expect(timers).to be_an(Array)
      entry = timers.find { |t| t[:method] == "broadcast" }
      expect(entry).not_to be_nil
      expect(entry[:every]).to include("->")
      expect(entry[:every]).to include("current_user.interval")
    end

    it "reads macros split across lines" do
      wrapped = <<~RUBY
        class WrappedChannel < ApplicationCable::Channel
          identified_by :current_user,
                        :tenant

          def subscribed
            stream_from "notifications:" \\
                        "global"
          end
        end
      RUBY

      expect(introspector.send(:extract_identified_by, wrapped)).to contain_exactly("current_user", "tenant")
      expect(introspector.send(:extract_channel_streams, wrapped)[:stream_from]).to eq([ "notifications:global" ])
    end

    it "returns nil when source has no identified_by" do
      expect(introspector.send(:extract_identified_by, "class Foo; end")).to be_nil
    end

    it "returns nil when source has no streams" do
      expect(introspector.send(:extract_channel_streams, "class Foo; end")).to be_nil
    end

    it "returns nil when source has no periodic timers" do
      expect(introspector.send(:extract_channel_periodic, "class Foo; end")).to be_nil
    end
  end

  describe "#extract_channel_actions" do
    let(:channel_class) do
      Class.new do
        def self.instance_methods(include_super = true)
          %i[subscribed unsubscribed speak ping stream_audio stream_video]
        end
      end
    end

    let(:lifecycle_only_class) do
      Class.new do
        def self.instance_methods(include_super = true)
          %i[subscribed unsubscribed]
        end
      end
    end

    it "returns RPC action methods, excluding lifecycle hooks and stream_* helpers" do
      actions = introspector.send(:extract_channel_actions, channel_class)
      expect(actions).to contain_exactly("ping", "speak")
    end

    it "returns nil when only lifecycle hooks are present" do
      expect(introspector.send(:extract_channel_actions, lifecycle_only_class)).to be_nil
    end
  end

  # Mailers and channels were read only through ActionMailer::Base.descendants
  # and ActionCable::Channel::Base.descendants. With no booted Rails those
  # constants are undefined, so the static tier answered "no mailers found" for
  # an app with mailers - a false negative served as ground truth.
  describe "#static_call" do
    def static_result(&build)
      Dir.mktmpdir do |dir|
        build.call(dir)
        return described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
      end
    end

    it "finds mailers and their actions from source" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "application_mailer.rb"), <<~RUBY)
          class ApplicationMailer < ActionMailer::Base
            default from: "from@example.com"
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "post_mailer.rb"), <<~RUBY)
          class PostMailer < ApplicationMailer
            def notify
              mail(to: "a@b.c")
            end

            private

            def helper; end
          end
        RUBY
      end

      mailer = result[:mailers].find { |m| m[:name] == "PostMailer" }
      expect(mailer).not_to be_nil
      expect(mailer[:actions]).to eq(%w[notify])
      expect(result[:mailers].map { |m| m[:name] }).not_to include("ApplicationMailer")
    end

    # ActionMailer interceptors are modules, and app/mailers is where they
    # live. Reporting one as a mailer offers `delivering_email` - an interceptor
    # hook - as an email an agent can send.
    it "does not report a module in app/mailers as a mailer" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers", "interceptors"))
        File.write(File.join(dir, "app", "mailers", "user_mailer.rb"), <<~RUBY)
          class UserMailer < ApplicationMailer
            def welcome
              mail(to: "a@b.c")
            end
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "interceptors", "default_headers.rb"), <<~RUBY)
          module Interceptors
            module DefaultHeaders
              module_function

              def delivering_email(mail); end

              def default_headers; end
            end
          end
        RUBY
      end

      expect(result[:mailers].map { |m| m[:name] }).to contain_exactly("UserMailer")
    end

    # An interceptor is as often a class as a module, and a mailer always
    # inherits something. A bare class under app/mailers is neither.
    it "does not report a parentless class in app/mailers as a mailer" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers", "interceptors"))
        File.write(File.join(dir, "app", "mailers", "user_mailer.rb"), <<~RUBY)
          class UserMailer < ApplicationMailer
            def welcome
              mail(to: "a@b.c")
            end
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "interceptors", "default_headers.rb"), <<~RUBY)
          module Interceptors
            class DefaultHeaders
              def self.delivering_email(mail); end

              def default_headers; end
            end
          end
        RUBY
      end

      expect(result[:mailers].map { |m| m[:name] }).to contain_exactly("UserMailer")
    end

    it "names a namespaced mailer by the constant its source declares" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers", "oauth"))
        File.write(File.join(dir, "app", "mailers", "oauth", "token_mailer.rb"), <<~RUBY)
          module OAuth
            class TokenMailer < ApplicationMailer
              def issued
                mail(to: "a@b.c")
              end
            end
          end
        RUBY
      end

      expect(result[:mailers].map { |m| m[:name] }).to contain_exactly("OAuth::TokenMailer")
    end

    it "finds channels from source" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "channels", "application_cable"))
        File.write(File.join(dir, "app", "channels", "application_cable", "channel.rb"), <<~RUBY)
          module ApplicationCable
            class Channel < ActionCable::Channel::Base; end
          end
        RUBY
        File.write(File.join(dir, "app", "channels", "chat_channel.rb"), <<~RUBY)
          class ChatChannel < ApplicationCable::Channel
            def subscribed
              stream_from "chat"
            end
          end
        RUBY
      end

      channel = result[:channels].find { |c| c[:name] == "ChatChannel" }
      expect(channel).not_to be_nil
      expect(channel[:stream_methods]).to include("subscribed")
      # Asserting only that the base class is absent passed while the names
      # were unqualified: "Channel" and "Connection" were both counted.
      expect(result[:channels].map { |c| c[:name] }).to eq(%w[ChatChannel])
    end

    it "names namespaced classes the way the booted app does" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers", "admin"))
        File.write(File.join(dir, "app", "mailers", "admin", "report_mailer.rb"), <<~RUBY)
          module Admin
            class ReportMailer < ApplicationMailer
              def weekly; end
            end
          end
        RUBY
      end

      expect(result[:mailers].map { |m| m[:name] }).to eq(%w[Admin::ReportMailer])
    end

    # app/*/concerns is its own Zeitwerk root, so what lives there is a mixin.
    # Naming it from the path also invented a `Concerns::` namespace that no
    # booted app would ever report.
    it "ignores app/mailers/concerns and app/channels/concerns" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers", "concerns"))
        FileUtils.mkdir_p(File.join(dir, "app", "channels", "concerns"))
        File.write(File.join(dir, "app", "mailers", "concerns", "attachable.rb"), <<~RUBY)
          module Attachable
            def attach_logo; end
          end
        RUBY
        File.write(File.join(dir, "app", "channels", "concerns", "traceable.rb"), <<~RUBY)
          module Traceable
            def subscribed; end
          end
        RUBY
      end

      expect(result[:mailers]).to eq([])
      expect(result[:channels]).to eq([])
    end

    it "returns empty collections when the directories are missing" do
      result = static_result { |_dir| nil }
      expect(result[:mailers]).to eq([])
      expect(result[:channels]).to eq([])
      expect(result[:jobs]).to eq([])
    end
  end
  # ActiveJob::Base.descendants is every job in the process, gems included. The
  # framework name prefixes only cover Rails' own, so a job from any other gem
  # counted as the app's: an app with 118 Sidekiq workers and no ActiveJob of
  # its own reported "1 job", and that job was Chewy's indexing worker.
  describe "whose jobs these are" do
    # Stubbed rather than `load`-ed. A real subclass stays in
    # ActiveJob::Base.descendants for the rest of the run and keeps its name
    # even after remove_const, so a leftover from here would be counted as the
    # app's own job by a later example - the very bug under test.
    before { allow(Object).to receive(:const_source_location).and_call_original }

    def job(name, defined_in:)
      allow(Object).to receive(:const_source_location).with(name)
        .and_return(defined_in && [ defined_in, 1 ])
      double(name, name: name, queue_name: "default", priority: nil)
    end

    def names_reported_for(*jobs)
      allow(ActiveJob::Base).to receive(:descendants).and_return(jobs)
      described_class.new(Rails.application).call[:jobs].map { |j| j[:name] }
    end

    let(:app_job_file) { File.join(Rails.root, "app", "jobs", "example_job.rb") }

    it "drops a job defined outside the app" do
      gem_file = File.join(Gem.loaded_specs["rspec-core"].full_gem_path, "lib", "rspec", "core.rb")
      expect(names_reported_for(job("GemIndexingWorker", defined_in: gem_file)))
        .not_to include("GemIndexingWorker")
    end

    it "keeps a job defined inside the app" do
      expect(names_reported_for(job("RuntimeProbeJob", defined_in: app_job_file)))
        .to include("RuntimeProbeJob")
    end

    # Dropping one would understate what the app runs, which is the worse of
    # the two mistakes this filter can make.
    it "keeps a job whose source location is unknown" do
      expect(names_reported_for(job("PlacelessWorker", defined_in: nil)))
        .to include("PlacelessWorker")
    end

    it "keeps the app's job while dropping the gem's in one pass" do
      gem_file = File.join(Gem.loaded_specs["rspec-core"].full_gem_path, "lib", "rspec", "core.rb")
      reported = names_reported_for(
        job("GemIndexingWorker", defined_in: gem_file),
        job("RuntimeProbeJob", defined_in: app_job_file)
      )
      expect(reported).to eq(%w[RuntimeProbeJob])
    end
  end

  # `instance_methods(false)` is not Rails' definition of a mailer action. It
  # returns protected methods too, and from Rails 8.1 on, ActiveSupport aliases
  # `_run_<kind>_callbacks` onto the first class in a hierarchy to declare a
  # callback of that kind - so `ApplicationMailer` was reported as having three
  # deliverable actions where Rails dispatches on none.
  #
  # The fixtures carry that shape: ApplicationMailer is an abstract base with a
  # callback and two protected helpers, NotificationMailer a concrete mailer
  # with one action and one protected helper beside it.
  describe "mailer actions" do
    subject(:mailers) { described_class.new(Rails.application).call[:mailers] }

    # Without ActionMailer in the bundle, ActionMailer::Base is undefined and
    # extract_mailers returns [] - which would leave every assertion below
    # passing over an empty array.
    it "sees the fixture mailers" do
      expect(mailers.map { |m| m[:name] }).to include("NotificationMailer", "UserMailer")
    end

    it "omits an abstract base that has no deliverable action" do
      expect(mailers.map { |m| m[:name] }).not_to include("ApplicationMailer")
    end

    it "reports the action of a concrete mailer without the protected helper beside it" do
      expect(mailers.find { |m| m[:name] == "NotificationMailer" }[:actions]).to eq(%w[digest])
    end

    it "reports exactly what Rails dispatches on" do
      mailers.each do |mailer|
        klass = mailer[:name].safe_constantize
        next unless klass.respond_to?(:action_methods)

        expect(mailer[:actions]).to eq(klass.action_methods.to_a.map(&:to_s).sort)
      end
    end

    it "never reports an ActiveSupport callback runner as an action" do
      expect(mailers.flat_map { |m| m[:actions] }).to all(satisfy { |a| !a.start_with?("_run_") })
    end

    it "answers the same as the static tier when no helper is inherited" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        %w[application_mailer notification_mailer].each do |name|
          FileUtils.cp(File.join(Rails.root, "app", "mailers", "#{name}.rb"),
                       File.join(dir, "app", "mailers"))
        end

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:mailers]
        expect(static.map { |m| m.slice(:name, :actions) })
          .to eq([ { name: "NotificationMailer", actions: %w[digest] } ])
      end
    end

    # Rails dispatches on every public instance method a mailer inherits, not
    # only the ones its own file defines. The AST sees one file at a time, so
    # a public helper on a base class is an action the booted tier reports and
    # the static tier cannot. Pinned because the gap is real and undocumented,
    # not because it is acceptable.
    it "misses an inherited public helper the booted tier calls an action" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "billing_base_mailer.rb"), <<~RUBY)
          class BillingBaseMailer < ActionMailer::Base
            def locale_for_account(account) = account
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "invoice_mailer.rb"), <<~RUBY)
          class InvoiceMailer < BillingBaseMailer
            def invoice(id)
              mail(to: "test@example.com")
            end
          end
        RUBY

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:mailers]
        invoice = static.find { |m| m[:name] == "InvoiceMailer" }
        expect(invoice[:actions]).to eq(%w[invoice])
        expect(invoice[:confidence]).to eq(RailsAiContext::Confidence::STATIC)
      end
    end
  end
end
