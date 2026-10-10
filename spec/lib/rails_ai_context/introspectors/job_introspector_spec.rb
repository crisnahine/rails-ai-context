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

    # One normalized list, the text every listing prints: the options come off
    # the call, so the order they were written in does not reach the reader.
    it "records the retry policy as the reader sees it" do
      jobs = introspector.send(:extract_jobs_from_source)
      cleanup = jobs.find { |j| j[:name] == "CleanupJob" }

      expect(cleanup[:retries]).to eq([
        "retry_on ActiveRecord::Deadlocked, attempts: 3, wait: 5.seconds",
        "discard_on ActiveJob::DeserializationError"
      ])
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
    def macros_for(src)
      introspector.send(:channel_macros, src)
    end

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
      expect(introspector.send(:extract_identified_by, macros_for(source))).to contain_exactly("current_user", "tenant")
    end

    it "extracts stream_from and stream_for targets" do
      streams = introspector.send(:extract_channel_streams, macros_for(source))
      expect(streams[:stream_from]).to include("chat_room_general")
      expect(streams[:stream_for]).to include("current_user")
    end

    it "extracts periodically timers with intervals" do
      timers = introspector.send(:extract_channel_periodic, macros_for(source))
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
      timers = introspector.send(:extract_channel_periodic, macros_for(complex))
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

      expect(introspector.send(:extract_identified_by, macros_for(wrapped))).to contain_exactly("current_user", "tenant")
      expect(introspector.send(:extract_channel_streams, macros_for(wrapped))[:stream_from]).to eq([ "notifications:global" ])
    end

    it "returns nil when source has no identified_by" do
      expect(introspector.send(:extract_identified_by, macros_for("class Foo; end"))).to be_nil
    end

    it "returns nil when source has no streams" do
      expect(introspector.send(:extract_channel_streams, macros_for("class Foo; end"))).to be_nil
    end

    it "returns nil when source has no periodic timers" do
      expect(introspector.send(:extract_channel_periodic, macros_for("class Foo; end"))).to be_nil
    end
  end

  def write_cable_app(dir)
    FileUtils.mkdir_p(File.join(dir, "app", "channels", "application_cable"))
    File.write(File.join(dir, "app", "channels", "application_cable", "connection.rb"), <<~RUBY)
      module ApplicationCable
        class Connection < ActionCable::Connection::Base
          identified_by :current_user
        end
      end
    RUBY
    File.write(File.join(dir, "app", "channels", "chat_channel.rb"), <<~'RUBY')
      class ChatChannel < ApplicationCable::Channel
        periodically :ping, every: 30.seconds
        periodically every: 10.seconds do
          transmit({ t: Time.now })
        end
        def subscribed
          stream_from "chat_#{params[:room]}"
          stream_for current_user
        end
        def speak(data); end
        private
        def ping; end
      end
    RUBY
  end

  # The booted tier reads the same files the static tier does, so both give one answer.
  describe "channels when booted" do
    it "reads a block timer and the connection's identifiers" do
      Dir.mktmpdir do |dir|
        write_cable_app(dir)
        allow(Rails.application).to receive(:root).and_return(Pathname.new(dir))
        base = Class.new
        stub_const("ActionCable::Channel::Base", base)
        channel = Class.new(base) do
          def subscribed; end
          def speak(data); end
          private def ping; end
        end
        stub_const("ChatChannel", channel)
        allow(base).to receive(:descendants).and_return([ channel ])
        allow(Object).to receive(:const_source_location).and_call_original
        allow(Object).to receive(:const_source_location).with("ChatChannel")
          .and_return([ File.join(dir, "app", "channels", "chat_channel.rb"), 1 ])

        result = described_class.new(Rails.application).call
        booted = result[:channels].find { |c| c[:name] == "ChatChannel" }
        expect(booted[:periodic]).to eq([ { method: "ping", every: "30.seconds" }, { block: true, every: "10.seconds" } ])
        expect(booted[:actions]).to eq([ "speak" ])
        expect(result[:connections].map { |c| c[:identified_by] }).to eq([ [ "current_user" ] ])
      end
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
  describe "methods delayed_job queues with handle_asynchronously" do
    let(:model_file) { File.join(Rails.root, "app/models/async_note.rb") }

    before { File.write(model_file, "class AsyncNote < ApplicationRecord\n  def ping; end\n  handle_asynchronously :ping, queue: \"low\"\nend\n") }
    after { FileUtils.rm_f(model_file) }

    it "reads them from the model source on both tiers" do
      expected = [ { owner: "AsyncNote", method: "ping", file: "app/models/async_note.rb:3", options: "queue: low" } ]

      expect(described_class.new(Rails.application).call[:async_methods]).to eq(expected)
      expect(described_class.new(Rails.application).static_call[:async_methods]).to eq(expected)
    end
  end

  # delayed_job's handle_asynchronously in a concern's `included do` wraps the
  # method on every class that includes it.
  describe "handle_asynchronously in a concern" do
    it "lists the method under each model that includes the concern, not the concern" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models/concerns"))
        File.write(File.join(dir, "app/models/concerns/notifiable.rb"),
          "module Notifiable\n  extend ActiveSupport::Concern\n  included do\n    handle_asynchronously :notify_all, queue: \"notify\"\n  end\n  def notify_all; end\nend\n")
        File.write(File.join(dir, "app/models/application_record.rb"), "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n")
        File.write(File.join(dir, "app/models/post.rb"), "class Post < ApplicationRecord\n  include Notifiable\nend\n")
        File.write(File.join(dir, "app/models/comment.rb"), "class Comment < ApplicationRecord\nend\n")

        found = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:async_methods]

        expect(found).to eq([ { owner: "Post", method: "notify_all", file: "app/models/concerns/notifiable.rb:4", options: "queue: notify" } ])
      end
    end

    it "still treats the concern as a mixin when it nests an error class" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models/concerns"))
        File.write(File.join(dir, "app/models/concerns/notifiable.rb"),
          "module Notifiable\n  extend ActiveSupport::Concern\n  class DeliveryError < StandardError; end\n  included do\n    handle_asynchronously :notify_all\n  end\n  def notify_all; end\nend\n")
        File.write(File.join(dir, "app/models/application_record.rb"), "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n")
        File.write(File.join(dir, "app/models/post.rb"), "class Post < ApplicationRecord\n  include Notifiable\nend\n")

        found = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:async_methods]

        expect(found).to eq([ { owner: "Post", method: "notify_all", file: "app/models/concerns/notifiable.rb:5" } ])
      end
    end

    it "follows a concern that another concern includes to the models including that one" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models/concerns"))
        File.write(File.join(dir, "app/models/concerns/notifiable.rb"),
          "module Notifiable\n  extend ActiveSupport::Concern\n  included do\n    handle_asynchronously :notify_all\n  end\n  def notify_all; end\nend\n")
        File.write(File.join(dir, "app/models/concerns/trackable.rb"),
          "module Trackable\n  extend ActiveSupport::Concern\n  include Notifiable\nend\n")
        File.write(File.join(dir, "app/models/application_record.rb"), "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n")
        File.write(File.join(dir, "app/models/note.rb"), "class Note < ApplicationRecord\n  include Trackable\nend\n")

        found = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:async_methods]

        expect(found).to eq([ { owner: "Note", method: "notify_all", file: "app/models/concerns/notifiable.rb:4" } ])
      end
    end
  end

  describe "#static_call" do
    def static_result(&build)
      Dir.mktmpdir do |dir|
        build.call(dir)
        return described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
      end
    end

    it "reads a base's class body from the candidate walk, with no second traversal" do
      base = "class ApplicationJob < ActiveJob::Base\n  queue_with_priority 5\n  before_perform :log\nend\n"
      walks = 0
      parses = 0
      allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk_source).and_wrap_original do |original, src, *rest|
        walks += 1 if src == base
        original.call(src, *rest)
      end
      allow(Prism).to receive(:parse).and_wrap_original do |original, src, *rest, **opts|
        parses += 1 if src == base
        original.call(src, *rest, **opts)
      end
      jobs = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/jobs"))
        File.write(File.join(dir, "app/jobs/application_job.rb"), base)
        3.times { |i| File.write(File.join(dir, "app/jobs/job#{i}_job.rb"), "class Job#{i}Job < ApplicationJob\n  def perform; end\nend\n") }
      end[:jobs]

      expect(jobs.map { |job| job[:priority] }.uniq).to eq([ 5 ])
      expect(walks).to eq(1)
      expect(parses).to be <= 1
    end

    # The worker's calls came from a second walk of a tree the candidate walk
    # had just dispatched, and an app can have 500 workers.
    it "walks a worker once for its macros, methods and calls" do
      source = <<~RUBY
        class RefreshWorker
          include Sidekiq::Worker
          sidekiq_options queue: :low

          def perform(id)
            Billing::Charge.call(id)
          end
        end
      RUBY
      walks = 0
      allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk_source).and_wrap_original do |original, src, *rest|
        walks += 1 if src == source
        original.call(src, *rest)
      end

      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "workers"))
        File.write(File.join(dir, "app", "workers", "refresh_worker.rb"), source)
      end

      expect(result[:workers].first[:calls]).to eq([ "Billing::Charge.call" ])
      expect(walks).to eq(1)
    end

    it "walks an initializer once for the GoodJob cron and the mailer settings, mailers or not" do
      source = "Rails.application.configure do\n  config.good_job.cron = { sweep: { cron: \"0 * * * *\", class: \"SweepJob\" } }\n" \
               "  config.action_mailer.deliver_later_queue_name = :mail\nend\n"
      walks = 0
      allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk_source).and_wrap_original do |original, src, *rest|
        walks += 1 if src == source
        original.call(src, *rest)
      end

      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "both.rb"), source)
      end

      expect(result[:recurring_jobs]).to include(include(name: "sweep", class: "SweepJob"))
      expect(walks).to eq(1)
    end

    it "reads a config file once for the GoodJob cron and the mailer settings" do
      source = "Rails.application.configure do\n  config.good_job.cron = { sweep: { cron: \"0 * * * *\", class: \"SweepJob\" } }\n" \
               "  config.action_mailer.deliver_later_queue_name = :mail\nend\n"
      reads = 0
      allow(RailsAiContext::SafeFile).to receive(:read).and_wrap_original do |original, path, **opts|
        reads += 1 if path.to_s.end_with?("config/initializers/both.rb")
        original.call(path, **opts)
      end

      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "both.rb"), source)
      end

      expect(result[:recurring_jobs]).to include(include(name: "sweep", class: "SweepJob"))
      expect(reads).to eq(1)
    end

    it "lets a recurring schedule reader's failure raise" do
      allow(RailsAiContext::Introspectors::RecurringSchedules).to receive(:read).and_raise(NoMethodError, "broken reader")

      expect { static_result { |_dir| nil } }.to raise_error(NoMethodError, "broken reader")
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

    # The hook rule dropped the class from the app/mailers pass and the
    # whole-app pass put it straight back, because the second pass skipped
    # only the files the first one kept.
    it "does not re-add an interceptor the hook rule dropped" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "application_mailer.rb"), <<~RUBY)
          class ApplicationMailer < ActionMailer::Base
            default from: "from@example.com"
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "tracking_mailer.rb"), <<~RUBY)
          class TrackingMailer < ApplicationMailer
            def self.delivering_email(mail); end
          end
        RUBY
      end

      expect(result[:mailers].map { |m| m[:name] }).to eq([])
    end

    # A mailer's actions are often written as modules mixed into one class -
    # GitLab keeps 20 of them under app/mailers/emails, holding every
    # notification it sends. Those are a mailer's interface; an interceptor is
    # not, and the framework hook is what tells them apart.
    it "keeps a module whose methods are mailer actions" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers", "emails"))
        File.write(File.join(dir, "app", "mailers", "notify.rb"), <<~RUBY)
          class Notify < ApplicationMailer
            include Emails::Issues
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "emails", "issues.rb"), <<~RUBY)
          module Emails
            module Issues
              def new_issue_email(recipient_id)
                mail(to: recipient_id)
              end
            end
          end
        RUBY
      end

      expect(result[:mailers].map { |m| m[:name] }).to include("Emails::Issues")
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

    it "reads a channel's streams, timers and actions, and the connection's identifiers" do
      result = static_result { |dir| write_cable_app(dir) }

      channel = result[:channels].find { |c| c[:name] == "ChatChannel" }
      expect(channel[:streams]).to eq(stream_from: [ "\"chat_\#{params[:room]}\"" ], stream_for: [ "current_user" ])
      expect(channel[:periodic]).to eq([ { method: "ping", every: "30.seconds" }, { block: true, every: "10.seconds" } ])
      expect(channel[:actions]).to eq([ "speak" ])
      expect(result[:connections]).to eq([ { name: "ApplicationCable::Connection",
                                             file: "app/channels/application_cable/connection.rb",
                                             identified_by: [ "current_user" ] } ])
    end

    # ActiveJob's queue_name_from_part: prefix and name joined by the delimiter,
    # and a job with no queue_as on the default queue name.
    it "names queues with the configured prefix, delimiter and default queue name" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "application.rb"), <<~RUBY)
          module App
            class Application < Rails::Application
              config.active_job.queue_name_prefix = "myapp"
              config.active_job.queue_name_delimiter = "."
              config.active_job.default_queue_name = "normal"
            end
          end
        RUBY
        File.write(File.join(dir, "app", "jobs", "cleanup_job.rb"), "class CleanupJob < ApplicationJob\n  queue_as :low\n  def perform; end\nend\n")
        File.write(File.join(dir, "app", "jobs", "digest_job.rb"), "class DigestJob < ApplicationJob\n  def perform; end\nend\n")
      end

      queues = result[:jobs].to_h { |job| [ job[:name], job[:queue] ] }
      expect(queues).to eq("CleanupJob" => "myapp.low", "DigestJob" => "myapp.normal")
    end

    it "reads a constant or interpolated queue prefix as computed, and adjacent literals as their value" do
      queue = lambda do |prefix|
        static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config", "application.rb"),
                     "module App\n  class Application < Rails::Application\n    config.active_job.queue_name_prefix = #{prefix}\n  end\nend\n")
          File.write(File.join(dir, "app", "jobs", "digest_job.rb"), "class DigestJob < ApplicationJob\n  def perform; end\nend\n")
        end[:jobs].first[:queue]
      end

      expect(queue.call("::Prefix::NAME")).to eq("`::Prefix::NAME`_default (computed)")
      expect(queue.call('"a#{ENV["X"]}"')).to eq("`\"a\#{ENV[\"X\"]}\"`_default (computed)")
      expect(queue.call('"my" "app"')).to eq("myapp_default")
      expect(queue.call(":Shop")).to eq("Shop_default")
    end

    it "names a job with no queue_as and no queue config the default queue, as the booted app does" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
        File.write(File.join(dir, "app", "jobs", "digest_job.rb"), "class DigestJob < ApplicationJob\n  def perform; end\nend\n")
      end

      expect(result[:jobs].map { |job| job[:queue] }).to eq([ "default" ])
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

    # Whitehall's MultiNotifications fans one notification out to every author
    # through `self.` methods. Dropping a mailer with no instance action hid a
    # class three models call.
    it "keeps a mailer whose interface is class methods" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "multi_notifications.rb"), <<~RUBY)
          class MultiNotifications < ApplicationMailer
            def self.deadline_passed(consultation)
              consultation
            end
          end
        RUBY
      end

      mailer = result[:mailers].find { |m| m[:name] == "MultiNotifications" }
      expect(mailer).not_to be_nil
      expect(mailer[:actions]).to eq([])
      expect(mailer[:class_actions]).to eq(%w[deadline_passed])
    end

    # Diaspora's DiasporaDeviseMailer overrides `self.mailer_name` and nothing
    # else. That is ActionMailer configuration, not a method anybody calls.
    it "does not read an ActionMailer class-level override as an interface" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "diaspora_devise_mailer.rb"), <<~RUBY)
          class DiasporaDeviseMailer < Devise::Mailer
            def self.mailer_name
              "devise/mailer"
            end
          end
        RUBY
      end

      mailer = result[:mailers].find { |m| m[:name] == "DiasporaDeviseMailer" }
      expect(mailer[:parent_class]).to eq("Devise::Mailer")
      expect(mailer).not_to have_key(:class_actions)
    end

    # Consul's DeviseMailer overrides one protected method and takes the rest
    # from a gem base. It is still the class the app delivers Devise mail
    # through, and the parent is what says where the actions live.
    it "keeps a mailer that declares no action of its own" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "devise_mailer.rb"), <<~RUBY)
          class DeviseMailer < Devise::Mailer
            protected

            def devise_mail(record, action, opts = {})
              super
            end
          end
        RUBY
      end

      mailer = result[:mailers].find { |m| m[:name] == "DeviseMailer" }
      expect(mailer).not_to be_nil
      expect(mailer[:actions]).to eq([])
      expect(mailer[:parent_class]).to eq("Devise::Mailer")
    end

    # Consul's ApplicationMailer makes `default_url_options` public and
    # OpenProject's defines three header helpers. Rails dispatches on all of
    # them, and every subclass inherits them: they are not emails anybody
    # sends, so the base leaves the listing and the answer names it.
    it "leaves a base other mailers inherit from out of the listing" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "application_mailer.rb"), <<~RUBY)
          class ApplicationMailer < ActionMailer::Base
            def default_url_options
              { host: "example.com" }
            end
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "post_mailer.rb"), <<~RUBY)
          class PostMailer < ApplicationMailer
            def notify
              mail(to: "a@b.c")
            end
          end
        RUBY
      end

      expect(result[:mailers].map { |m| m[:name] }).to eq(%w[PostMailer])
      expect(result[:mailer_bases].map { |b| b[:name] }).to eq(%w[ApplicationMailer])
    end

    # Every mailer runs with what its base declares: Mastodon's
    # ApplicationMailer sets the layout, three helpers and an after_action,
    # Forem's the from and reply_to defaults. The base record carries them as
    # the app wrote them, what it defines, and who inherits it.
    # OpenProject's ApplicationMailer writes `helper :application, # for
    # format_text` across three lines with a comment on each, and reads
    # `default[:from]` inside `class << self` methods. The declaration printed
    # the comments folded into the call, and each read as a `default`.
    it "prints a declaration without its comments, and only the class body's" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "application_mailer.rb"), <<~RUBY)
          class ApplicationMailer < ActionMailer::Base
            helper :application, # for format_text
                   :work_packages, # for css classes
                   :mail_layout # for layouting

            default from: Proc.new { Setting.mail_from }

            class << self
              def mail_from
                default[:from].call
              end

              def reply_to = default[:reply_to]
            end
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "user_mailer.rb"), <<~RUBY)
          class UserMailer < ApplicationMailer
            def welcome = mail(to: "a@b.c")
          end
        RUBY
      end

      expect(result[:mailer_bases].first[:declares]).to eq([
        "helper :application, :work_packages, :mail_layout",
        "default from: Proc.new { Setting.mail_from }"
      ])
    end

    # `self.default_url_options =` is a class-body declaration written with a
    # receiver; the same assignment inside a method is not one.
    it "keeps a self-receiver declaration in the class body and drops one in a method" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "application_mailer.rb"), <<~RUBY)
          class ApplicationMailer < ActionMailer::Base
            self.default_url_options = { host: "example.com" }

            def self.reset_host!
              self.default_url_options = {}
            end
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "user_mailer.rb"), <<~RUBY)
          class UserMailer < ApplicationMailer
            def welcome = mail(to: "a@b.c")
          end
        RUBY
      end

      expect(result[:mailer_bases].first[:declares]).to eq([ "self.default_url_options = { host: \"example.com\" }" ])
    end

    it "records what a mailer base declares and who inherits it" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "application_mailer.rb"), <<~RUBY)
          class ApplicationMailer < ActionMailer::Base
            layout 'mailer'
            helper :application
            include Deliverable

            default(
              from: -> { email_from },
              reply_to: "support@example.com",
            )

            after_action :set_autoreply_headers!

            protected

            def set_autoreply_headers!; end
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "post_mailer.rb"), <<~RUBY)
          class PostMailer < ApplicationMailer
            def notify
              mail(to: "a@b.c")
            end
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "admin_mailer.rb"), <<~RUBY)
          class AdminMailer < ApplicationMailer
            def report
              mail(to: "a@b.c")
            end
          end
        RUBY
      end

      expect(result[:mailer_bases]).to eq([ {
        name: "ApplicationMailer",
        file: "app/mailers/application_mailer.rb",
        declares: [
          "layout 'mailer'",
          "helper :application",
          "include Deliverable",
          "default(from: -> { email_from }, reply_to: \"support@example.com\")",
          "after_action :set_autoreply_headers!"
        ],
        methods: %w[set_autoreply_headers!],
        inherited_by: %w[AdminMailer PostMailer]
      } ])
    end

    # `class Admin::X < Parent` reads Parent at the top level, whatever Admin holds.
    it "follows a compact mailer's bare superclass to the top-level class" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers", "admin"))
        File.write(File.join(dir, "app", "mailers", "application_mailer.rb"), "class ApplicationMailer < ActionMailer::Base\nend\n")
        File.write(File.join(dir, "app", "mailers", "base_mailer.rb"), "class BaseMailer < ApplicationMailer\nend\n")
        File.write(File.join(dir, "app", "mailers", "notifier.rb"), "class Notifier < ApplicationMailer\nend\n")
        File.write(File.join(dir, "app", "mailers", "admin", "base_mailer.rb"),
                   "module Admin\n  class BaseMailer < ApplicationMailer\n    def hi = mail\n  end\nend\n")
        File.write(File.join(dir, "app", "mailers", "admin", "notifier.rb"), "module Admin\n  class Notifier\n  end\nend\n")
        File.write(File.join(dir, "app", "mailers", "admin", "report_mailer.rb"), "class Admin::ReportMailer < BaseMailer\n  def report = mail\nend\n")
        File.write(File.join(dir, "app", "mailers", "admin", "alert.rb"), "class Admin::Alert < Notifier\n  def alert = mail\nend\n")
      end

      expect(result[:mailer_bases].map { |b| [ b[:name], b[:inherited_by] ] }).to include([ "BaseMailer", %w[Admin::ReportMailer] ])
      expect(result[:mailer_bases].map { |b| b[:name] }).not_to include("Admin::BaseMailer")
      expect(result[:mailers].map { |m| m[:name] }).to include("Admin::Alert", "Admin::BaseMailer")
    end

    # A Base nobody inherits from is somebody's only mailer.
    it "keeps a base-named mailer nothing inherits from" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "mailer_base.rb"), <<~RUBY)
          class MailerBase < ActionMailer::Base
            def contact_form(message)
              mail(to: "a@b.c")
            end
          end
        RUBY
      end

      expect(result[:mailers].map { |m| m[:name] }).to eq(%w[MailerBase])
      expect(result[:mailer_bases]).to eq([])
    end

    # Diaspora keeps NotificationMailers::Base, a plain class, and twelve
    # subclasses that only build header hashes, all under app/mailers. None
    # reaches ActionMailer, so none is a mailer, and the base is nobody's
    # mailer base either.
    it "leaves out a class under app/mailers whose chain reaches no mailer" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers", "notification_mailers"))
        File.write(File.join(dir, "app", "mailers", "notification_mailers", "base.rb"), <<~RUBY)
          module NotificationMailers
            class Base
              def set_headers; end
            end
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "notification_mailers", "liked.rb"), <<~RUBY)
          module NotificationMailers
            class Liked < NotificationMailers::Base
              def set_headers; end
            end
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "notifier.rb"), <<~RUBY)
          class Notifier < ApplicationMailer
            def liked(id)
              mail(to: "a@b.c")
            end
          end
        RUBY
        File.write(File.join(dir, "app", "mailers", "application_mailer.rb"), <<~RUBY)
          class ApplicationMailer < ActionMailer::Base; end
        RUBY
        File.write(File.join(dir, "app", "mailers", "diaspora_devise_mailer.rb"), <<~RUBY)
          class DiasporaDeviseMailer < Devise::Mailer; end
        RUBY
      end

      expect(result[:mailers].map { |m| m[:name] }).to eq(%w[DiasporaDeviseMailer Notifier])
      expect(result[:mailer_bases].map { |b| b[:name] }).to eq(%w[ApplicationMailer])
    end

    # The chain can run through app classes the mailer scan never lists:
    # ReceiptMailer < Notifications::Sender (app/lib) < BaseNotifier (lib) <
    # ActionMailer::Base. Stopping at the first class whose line names no
    # *Mailer parent left a real mailer out.
    it "follows a mailer's chain through app classes on the autoload roots" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        FileUtils.mkdir_p(File.join(dir, "app", "lib", "notifications"))
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "app", "mailers", "receipt_mailer.rb"), <<~RUBY)
          class ReceiptMailer < Notifications::Sender
            def receipt(id)
              mail(to: "a@b.c")
            end
          end
        RUBY
        File.write(File.join(dir, "app", "lib", "notifications", "sender.rb"), <<~RUBY)
          module Notifications
            class Sender < BaseNotifier
              def sign; end
            end
          end
        RUBY
        File.write(File.join(dir, "lib", "base_notifier.rb"), <<~RUBY)
          class BaseNotifier < ActionMailer::Base; end
        RUBY
      end

      expect(result[:mailers].map { |m| m[:name] }).to include("ReceiptMailer")
    end

    it "leaves out a chain through app classes that reaches no mailer" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "app", "mailers", "header_builder.rb"), <<~RUBY)
          class HeaderBuilder < Formatting::Base
            def build; end
          end
        RUBY
        FileUtils.mkdir_p(File.join(dir, "lib", "formatting"))
        File.write(File.join(dir, "lib", "formatting", "base.rb"), <<~RUBY)
          module Formatting
            class Base; end
          end
        RUBY
      end

      expect(result[:mailers]).to eq([])
    end

    # A parent the app does not define is a gem's; only a gem mailer
    # (Devise::Mailer) makes a mailer of it.
    it "leaves out a class whose gem parent is not a mailer" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "digest_builder.rb"), <<~RUBY)
          class DigestBuilder < SomeGem::Formatter
            def build; end
          end
        RUBY
      end

      expect(result[:mailers]).to eq([])
    end

    # Canvas keeps `class Mailer < ActionMailer::Base` in app/models. Scanning
    # app/mailers alone answered "no mailers found" for an app that sends every
    # notification it has through one.
    it "finds a mailer outside app/mailers" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "mailer.rb"), <<~RUBY)
          class Mailer < ActionMailer::Base
            def create_message(message)
              mail(to: message.to)
            end
          end
        RUBY
      end

      mailer = result[:mailers].find { |m| m[:name] == "Mailer" }
      expect(mailer).not_to be_nil
      expect(mailer[:actions]).to eq(%w[create_message])
      expect(mailer[:file]).to eq("app/models/mailer.rb")
    end

    # A model that happens to subclass an app mailer is a mailer too, and the
    # only name its source carries is the parent's.
    it "follows an app mailer parent outside app/mailers" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        FileUtils.mkdir_p(File.join(dir, "app", "services"))
        File.write(File.join(dir, "app", "mailers", "base_mailer.rb"), <<~RUBY)
          class BaseMailer < ActionMailer::Base
            def ping; end
          end
        RUBY
        File.write(File.join(dir, "app", "services", "receipt_mailer.rb"), <<~RUBY)
          class ReceiptMailer < BaseMailer
            def receipt
              mail(to: "a@b.c")
            end
          end
        RUBY
      end

      expect(result[:mailers].map { |m| m[:name] }).to include("ReceiptMailer")
    end

    # Forem's DeviseMailer and DigestMailer: `action_methods` counts both, but
    # a method a callback macro names is a filter and a predicate delivers
    # nothing.
    it "leaves callback filters and predicates out of the actions" do
      result = static_result do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "mailers"))
        File.write(File.join(dir, "app", "mailers", "digest_mailer.rb"), <<~RUBY)
          class DigestMailer < ApplicationMailer
            before_action :use_settings_general_values

            def digest_email
              mail(to: "a@b.c")
            end

            def use_settings_general_values; end

            def follows_any?
              true
            end
          end
        RUBY
      end

      mailer = result[:mailers].find { |m| m[:name] == "DigestMailer" }
      expect(mailer[:actions]).to eq(%w[digest_email])
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

    # A line scan counted a queue named in a comment: OFN's file names
    # config/initializers/sidekiq.rb under one, and the tool said the app
    # declares a queue called "config".
    describe "the Sidekiq config" do
      def sidekiq_config(yaml)
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config", "sidekiq.yml"), yaml)
          return described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:sidekiq_config]
        end
      end

      it "reads the queue list the file declares, not the words in its comments" do
        config = sidekiq_config(<<~YAML)
          ---

          :verbose: false
          :concurrency: 5

          :queues:
            - default
            - mailers

          # This config is loaded before dotenv. See:
          #
          # - config/initializers/sidekiq.rb
        YAML

        expect(config).to eq(concurrency: 5, queues: %w[default mailers])
      end

      it "reads a weighted queue by its name" do
        config = sidekiq_config(":queues:\n  - [critical, 2]\n  - default\n")

        expect(config[:queues]).to eq(%w[critical default])
      end

      # Whitehall wraps its scheduler section in ERB; the queue list above it
      # still reads.
      it "reads a file that computes part of itself in ERB" do
        config = sidekiq_config(<<~YAML)
          :concurrency: 8
          :queues:
            - scheduled_publishing
            - default

          <% if ENV["RAILS_ENV"] == "production" %>
          :scheduler:
            :schedule:
              nightly:
                cron: '0 4 * * *'
          <% end %>
        YAML

        expect(config[:queues]).to eq(%w[scheduled_publishing default])
      end

      it "takes the queues an env section names when the top level names none" do
        config = sidekiq_config("production:\n  :queues:\n    - critical\n")

        expect(config[:queues]).to eq(%w[critical])
      end

      it "answers nothing for a file it cannot parse" do
        expect(sidekiq_config("::::\n\tbroken: [")).to be_nil
      end
    end

    # A worker that inherits from a base worker carries the include on the
    # parent, so a file that must name a mixin in its own source drops every
    # one of them: Mastodon reported 97 of its 116 workers, and the missing 19
    # were exactly the inheriting ones and the three-line IterableJob mixin.
    describe "workers" do
      def worker_tree(dir)
        FileUtils.mkdir_p(File.join(dir, "app", "workers", "fasp"))
        File.write(File.join(dir, "app", "workers", "fasp", "base_worker.rb"), <<~RUBY)
          class Fasp::BaseWorker
            include Sidekiq::Worker

            sidekiq_options queue: 'fasp'
          end
        RUBY
        File.write(File.join(dir, "app", "workers", "fasp", "backfill_worker.rb"), <<~RUBY)
          class Fasp::BackfillWorker < Fasp::BaseWorker
            def perform(backfill_request_id); end
          end
        RUBY
        File.write(File.join(dir, "app", "workers", "cleanup_worker.rb"), <<~RUBY)
          class CleanupWorker
            include Sidekiq::IterableJob

            def build_enumerator(domain, cursor:); end
          end
        RUBY
      end

      it "lists a worker that inherits its mixin from a base worker" do
        workers = static_result { |dir| worker_tree(dir) }[:workers]

        expect(workers.map { |w| w[:name] })
          .to contain_exactly("Fasp::BackfillWorker", "CleanupWorker")
      end

      it "still excludes a file under app/workers that is not a worker" do
        workers = static_result do |dir|
          worker_tree(dir)
          File.write(File.join(dir, "app", "workers", "queue_names.rb"), <<~RUBY)
            class QueueNames
              PUSH = 'push'
            end
          RUBY
        end[:workers]

        expect(workers.map { |w| w[:name] }).not_to include("QueueNames")
      end

      it "answers nothing for an app with no workers" do
        workers = static_result { |dir| FileUtils.mkdir_p(File.join(dir, "app", "jobs")) }[:workers]

        expect(workers).to eq([])
      end
    end

    # A job is a job wherever the app autoloads it. Reading ActiveJob out of
    # app/jobs and Sidekiq out of app/workers dropped every job in the other
    # directory: Whitehall's 31 workers in app/sidekiq and OpenProject's ~80
    # ActiveJob classes in app/workers both answered "No jobs found".
    describe "job directories" do
      it "reads Sidekiq workers out of app/sidekiq" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "sidekiq"))
          File.write(File.join(dir, "app", "sidekiq", "job_base.rb"), <<~RUBY)
            class JobBase
              include Sidekiq::Job
            end
          RUBY
          File.write(File.join(dir, "app", "sidekiq", "author_notifier_job.rb"), <<~RUBY)
            class AuthorNotifierJob < JobBase
              sidekiq_options queue: "scheduled_publishing"

              def perform(edition_id); end
            end
          RUBY
        end

        expect(result[:workers].map { |w| w[:name] }).to eq(%w[AuthorNotifierJob])
        expect(result[:workers].first[:options]).to eq("queue" => "scheduled_publishing")
      end

      it "reads ActiveJob classes out of app/workers" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "workers", "mails"))
          File.write(File.join(dir, "app", "workers", "application_job.rb"), <<~RUBY)
            class ApplicationJob < ActiveJob::Base; end
          RUBY
          File.write(File.join(dir, "app", "workers", "bulk_job.rb"), <<~RUBY)
            class BulkJob < ApplicationJob
              queue_as :bulk
            end
          RUBY
          File.write(File.join(dir, "app", "workers", "mails", "member_job.rb"), <<~RUBY)
            module Mails
              class MemberJob < ::BulkJob
                def perform(member_id); end
              end
            end
          RUBY
        end

        expect(result[:jobs].map { |j| j[:name] }).to eq(%w[BulkJob Mails::MemberJob])
        expect(result[:workers]).to eq([])
      end

      # Discourse's 236 jobs are Sidekiq workers through Jobs::Base, and the
      # queue each one declares is on `sidekiq_options`, not `queue_as`: read
      # as ActiveJob they all came back on the default queue.
      it "reads a Sidekiq queue off a job in app/jobs" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs", "regular"))
          File.write(File.join(dir, "app", "jobs", "base.rb"), <<~RUBY)
            module Jobs
              class Base
                include Sidekiq::Worker

                def perform(*args); end
              end
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "regular", "anonymize_user.rb"), <<~RUBY)
            module Jobs
              class AnonymizeUser < ::Jobs::Base
                sidekiq_options queue: "low"

                def execute(args); end
              end
            end
          RUBY
        end

        expect(result[:jobs]).to eq([])
        expect(result[:workers].map { |w| [ w[:name], w[:options] ] })
          .to eq([ [ "Jobs::AnonymizeUser", { "queue" => "low" } ] ])
      end

      # An app that autoloads app/jobs/regular as a root of its own gives
      # Jobs::AnonymizeUser a path that camelizes to Regular::AnonymizeUser.
      # The constant the file declares is the one the app answers to, and the
      # one a reader greps for.
      it "names a job by the constant its file declares, not by its path" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs", "regular"))
          File.write(File.join(dir, "app", "jobs", "regular", "notify.rb"), <<~RUBY)
            module Jobs
              class Notify < ActiveJob::Base
                def perform; end
              end
            end
          RUBY
        end

        expect(result[:jobs].map { |j| j[:name] }).to eq(%w[Jobs::Notify])
      end

      # The name came from the path while the base came from the first class in
      # the file, so a file the path names nothing in was listed under the
      # path's name with another class's ancestry.
      it "names a job and reads its base from the same declaration" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          File.write(File.join(dir, "app", "jobs", "application_job.rb"), <<~RUBY)
            class ApplicationJob < ActiveJob::Base; end
          RUBY
          File.write(File.join(dir, "app", "jobs", "misc.rb"), <<~RUBY)
            module Jobs
              class Cleanup < ::ApplicationJob
                def perform; end
              end

              class Sweep < ::ApplicationJob
                def perform; end
              end
            end
          RUBY
        end

        expect(result[:jobs].map { |j| [ j[:name], j[:unknown_base] ] }).to eq([ [ "Jobs::Cleanup", nil ] ])
      end

      # An error class beside a job in one file is not a job. The file's own
      # `perform` and the file's own ancestry both belong to the other class.
      it "does not read another class in the file as this one's job" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          File.write(File.join(dir, "app", "jobs", "application_job.rb"), <<~RUBY)
            class ApplicationJob < ActiveJob::Base; end
          RUBY
          File.write(File.join(dir, "app", "jobs", "retry_signal.rb"), <<~RUBY)
            module Jobs
              class RetrySignal < StandardError; end

              class Rebuild < ::ApplicationJob
                def perform; end
              end
            end
          RUBY
        end

        expect(result[:jobs].map { |j| j[:name] }).to eq([])
      end

      # The path is still the only thing carrying the namespace when the
      # source does not name it.
      it "keeps the path's namespace when the source declares a bare class" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs", "admin"))
          File.write(File.join(dir, "app", "jobs", "admin", "audit_job.rb"), <<~RUBY)
            class AuditJob < ActiveJob::Base
              def perform; end
            end
          RUBY
        end

        expect(result[:jobs].map { |j| j[:name] }).to eq(%w[Admin::AuditJob])
      end

      it "does not count a class in a job directory that is neither" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          File.write(File.join(dir, "app", "jobs", "queue_names.rb"), <<~RUBY)
            class QueueNames
              PUSH = "push"
            end
          RUBY
        end

        expect(result[:jobs]).to eq([])
        expect(result[:workers]).to eq([])
      end

      # Jobs::Base was one of Discourse's 236 jobs, JobBase one of Whitehall's
      # 32 workers. Neither is a unit of work anyone enqueues.
      it "drops an abstract base another job inherits from" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          File.write(File.join(dir, "app", "jobs", "application_job.rb"), <<~RUBY)
            class ApplicationJob < ActiveJob::Base; end
          RUBY
          File.write(File.join(dir, "app", "jobs", "import_job_base.rb"), <<~RUBY)
            class ImportJobBase < ApplicationJob; end
          RUBY
          File.write(File.join(dir, "app", "jobs", "import_users_job.rb"), <<~RUBY)
            class ImportUsersJob < ImportJobBase
              def perform; end
            end
          RUBY
        end

        expect(result[:jobs].map { |j| j[:name] }).to eq(%w[ImportUsersJob])
      end

      # Not every app's jobs are ActiveJob or Sidekiq. A Resque job is a class
      # with a class-level perform and a @queue, and a plain PORO enqueued by
      # hand is a class with an instance one; dropping both left an app whose
      # every job is one of them reading "No jobs found".
      it "lists a job whose ancestry it cannot place but whose perform it can see" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          File.write(File.join(dir, "app", "jobs", "archive.rb"), <<~RUBY)
            class Archive
              @queue = :file_serve

              def self.perform(id); end
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "legacy_job.rb"), <<~RUBY)
            class LegacyJob
              def perform(id); end
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "send_email_job.rb"), <<~RUBY)
            class SendEmailJob < ActiveJob::Base
              def perform(id); end
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "queue_names.rb"), <<~RUBY)
            class QueueNames
              PUSH = "push"
            end
          RUBY
        end

        expect(result[:jobs].map { |j| j[:name] }).to eq(%w[Archive LegacyJob SendEmailJob])
        expect(result[:jobs].map { |j| j[:unknown_base] })
          .to eq([ true, true, nil ])
      end

      it "reads a Resque job's @queue and lists a Que job, which defines run, with its queue" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          File.write(File.join(dir, "app", "jobs", "archive_job.rb"), <<~RUBY)
            class ArchiveJob
              @queue = :archive
              def self.perform(id)
                @queue = :other
              end
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "mail_job.rb"), <<~RUBY)
            class MailJob < Que::Job
              self.queue = "mail"
              def run(account_id); end
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "digest_job.rb"), <<~RUBY)
            class DigestJob < MailJob
              def run; end
            end
          RUBY
        end

        expect(result[:jobs].map { |j| [ j[:name], j[:queue], j[:unknown_base] ] })
          .to eq([ [ "ArchiveJob", "archive", true ], [ "DigestJob", "mail", nil ], [ "MailJob", "mail", nil ] ])
      end

      it "takes run as the entry point of a Que job only, never of an ActiveJob job or a worker" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          FileUtils.mkdir_p(File.join(dir, "app", "workers"))
          File.write(File.join(dir, "app", "jobs", "mail_job.rb"), "class MailJob < Que::Job\n  def run(account_id); end\nend\n")
          File.write(File.join(dir, "app", "jobs", "sync_job.rb"), "class SyncJob < ApplicationJob\n  def run(step); end\nend\n")
          File.write(File.join(dir, "app", "workers", "base_worker.rb"),
                     "class BaseWorker\n  include Sidekiq::Job\n  def perform(id); run(id); end\nend\n")
          File.write(File.join(dir, "app", "workers", "sync_worker.rb"), "class SyncWorker < BaseWorker\n  def run(step); end\nend\n")
        end

        jobs = result[:jobs].to_h { |j| [ j[:name], j[:perform_signature] ] }
        expect(jobs).to include("MailJob" => "account_id")
        expect(jobs["SyncJob"]).to be_nil
        worker = result[:workers].find { |w| w[:name] == "SyncWorker" }
        expect(worker.slice(:entry_point, :perform_signature)).to eq({})
      end

      # The walk already read every file; reading each one again to render it
      # made a job disappear if anything touched the tree in between, and the
      # listing said nothing about the one it lost.
      it "renders a job from the source the walk read" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          file = File.join(dir, "app", "jobs", "import_job.rb")
          File.write(file, <<~RUBY)
            class ImportJob < ActiveJob::Base
              queue_as :imports

              def perform(id); end
            end
          RUBY

          introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
          introspector.send(:job_candidates)
          FileUtils.rm_f(file)

          expect(introspector.static_call[:jobs].map { |j| j[:name] }).to eq(%w[ImportJob])
        end
      end

      # The listing offers to answer for a base by name, so the record has to
      # carry the file that answer is read from.
      # Whitehall's PublishingApiRedirectJob sets only `retry: 0`; its queue is
      # the one PublishingApiJob declares, and Sidekiq hands it down. The
      # nearest class that sets a key wins it.
      it "reads a worker's options down the app's own chain" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "sidekiq"))
          File.write(File.join(dir, "app", "sidekiq", "job_base.rb"), <<~RUBY)
            class JobBase
              include Sidekiq::Job
              sidekiq_options retry: 5, backtrace: true
            end
          RUBY
          File.write(File.join(dir, "app", "sidekiq", "publishing_api_job.rb"), <<~RUBY)
            class PublishingApiJob < JobBase
              sidekiq_options queue: "publishing_api"

              def perform(id); end
            end
          RUBY
          File.write(File.join(dir, "app", "sidekiq", "publishing_api_redirect_job.rb"), <<~RUBY)
            class PublishingApiRedirectJob < PublishingApiJob
              sidekiq_options retry: 0

              def perform(id); end
            end
          RUBY
        end

        redirect = result[:workers].find { |w| w[:name] == "PublishingApiRedirectJob" }
        expect(redirect[:options]).to eq("retry" => 0, "backtrace" => true, "queue" => "publishing_api")
      end

      it "reads an ActiveJob queue from the nearest class that sets one" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          File.write(File.join(dir, "app", "jobs", "application_job.rb"), "class ApplicationJob < ActiveJob::Base; end\n")
          File.write(File.join(dir, "app", "jobs", "bulk_job.rb"), <<~RUBY)
            class BulkJob < ApplicationJob
              queue_as :bulk

              def perform; end
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "bulk_move_job.rb"), <<~RUBY)
            class BulkMoveJob < BulkJob
              def perform; end
            end
          RUBY
        end

        expect(result[:jobs].to_h { |j| [ j[:name], j[:queue] ] }).to eq("BulkJob" => "bulk", "BulkMoveJob" => "bulk")
      end

      # A queue picked at enqueue time was reported as "dynamic", or not at
      # all: say it is computed, and show how.
      it "shows a computed queue's source" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          File.write(File.join(dir, "app", "jobs", "urgent_job.rb"), <<~RUBY)
            class UrgentJob < ActiveJob::Base
              queue_as -> { arguments.first.urgent? ? :high : :low }

              def perform(item); end
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "env_job.rb"), <<~RUBY)
            class EnvJob < ActiveJob::Base
              queue_as ENV.fetch("ENV_QUEUE", "default")

              def perform; end
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "processing_job.rb"), <<~RUBY)
            class ProcessingJob < ActiveJob::Base
              def self.processing_queue = :processing
              queue_as processing_queue

              def perform; end
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "block_job.rb"), <<~RUBY)
            class BlockJob < ActiveJob::Base
              queue_as do
                # urgent jobs go high
                arguments.first.urgent? ? :high : :low
              end
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "const_job.rb"), <<~RUBY)
            class ConstJob < ActiveJob::Base
              QUEUE = -> { :high }
              queue_as QUEUE
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "outside_const_job.rb"), "class OutsideConstJob < ActiveJob::Base\n  queue_as Queues::HIGH\nend\n")
          File.write(File.join(dir, "app", "jobs", "brace_job.rb"), "class BraceJob < ActiveJob::Base\n  queue_as { :high }\nend\n")
          File.write(File.join(dir, "app", "jobs", "proc_job.rb"), "class ProcJob < ActiveJob::Base\n  queue_as proc { :x }\nend\n")
          File.write(File.join(dir, "app", "jobs", "proc_new_job.rb"), "class ProcNewJob < ActiveJob::Base\n  queue_as Proc.new { :x }\nend\n")
          File.write(File.join(dir, "app", "jobs", "pick_job.rb"), "class PickJob < ActiveJob::Base\n  queue_as(&PICK)\nend\n")
        end

        expect(result[:jobs].to_h { |j| [ j[:name], j[:queue] ] }).to eq(
          "BlockJob" => "computed by a block: `do arguments.first.urgent? ? :high : :low; end`",
          "BraceJob" => "computed by a block: `{ :high }`",
          "ConstJob" => "#{described_class::PROC_QUEUE}: `-> { :high }`",
          "EnvJob" => "`ENV.fetch(\"ENV_QUEUE\", \"default\")` (computed)",
          "OutsideConstJob" => "`Queues::HIGH` (computed)",
          "PickJob" => "computed by a block",
          "ProcessingJob" => "`processing_queue` (computed)",
          "ProcJob" => "#{described_class::PROC_QUEUE}: `proc { :x }`",
          "ProcNewJob" => "#{described_class::PROC_QUEUE}: `Proc.new { :x }`",
          "UrgentJob" => "#{described_class::PROC_QUEUE}: `-> { arguments.first.urgent? ? :high : :low }`"
        )
      end

      # OpenProject keeps a PDF style class, Styles::Base, in app/workers, and
      # it has subclasses: a base by name, and no job at all. A job base is one
      # whose own chain reaches ActiveJob or a Sidekiq mixin.
      it "does not call a subclassed class with no job chain a job base" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "workers", "styles"))
          File.write(File.join(dir, "app", "workers", "styles", "base.rb"), <<~RUBY)
            module Styles
              class Base
                def font_size = 10
              end
            end
          RUBY
          File.write(File.join(dir, "app", "workers", "styles", "cover.rb"), <<~RUBY)
            module Styles
              class Cover < Base
                def font_size = 14
              end
            end
          RUBY
        end

        expect(result[:job_bases]).to eq([])
        expect(result[:jobs]).to eq([])
        expect(result[:workers]).to eq([])
      end

      it "records the file each base was read from" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          File.write(File.join(dir, "app", "jobs", "import_job_base.rb"), <<~RUBY)
            class ImportJobBase < ActiveJob::Base; end
          RUBY
          File.write(File.join(dir, "app", "jobs", "import_users_job.rb"), <<~RUBY)
            class ImportUsersJob < ImportJobBase
              def perform; end
            end
          RUBY
        end

        expect(result[:job_bases]).to eq([ { name: "ImportJobBase", file: "app/jobs/import_job_base.rb", active_job: true,
                                             inherited_by: %w[ImportUsersJob] } ])
      end

      # A base's own declarations are what every job inheriting it runs with.
      it "records the queue, options and retries a base declares" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          File.write(File.join(dir, "app", "jobs", "import_job_base.rb"), <<~RUBY)
            class ImportJobBase < ActiveJob::Base
              queue_as :imports
              discard_on ActiveJob::DeserializationError
            end
          RUBY
          File.write(File.join(dir, "app", "jobs", "import_users_job.rb"), <<~RUBY)
            class ImportUsersJob < ImportJobBase
              def perform; end
            end
          RUBY
        end

        expect(result[:job_bases]).to eq([
          { name: "ImportJobBase", file: "app/jobs/import_job_base.rb", active_job: true, queue: "imports",
            retries: [ "discard_on ActiveJob::DeserializationError" ], inherited_by: %w[ImportUsersJob] }
        ])
      end

      it "reads a compact job's bare superclass from the top level" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs", "admin"))
          File.write(File.join(dir, "app", "jobs", "base_job.rb"), "class BaseJob < ActiveJob::Base\n  queue_as :web\nend\n")
          File.write(File.join(dir, "app", "jobs", "admin", "base_job.rb"),
                     "module Admin\n  class BaseJob < ActiveJob::Base\n    queue_as :admin\n  end\nend\n")
          File.write(File.join(dir, "app", "jobs", "admin", "sync_job.rb"), "class Admin::SyncJob < BaseJob\n  def perform; end\nend\n")
        end

        expect(result[:jobs].find { |j| j[:name] == "Admin::SyncJob" }[:queue]).to eq("web")
      end

      # Both halves of the base rule matter: a base nobody inherits from is
      # somebody's only job.
      it "keeps a job named like a base that nothing inherits from" do
        result = static_result do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
          File.write(File.join(dir, "app", "jobs", "rebuild_base_job.rb"), <<~RUBY)
            class RebuildBaseJob < ActiveJob::Base
              def perform; end
            end
          RUBY
        end

        expect(result[:jobs].map { |j| j[:name] }).to eq(%w[RebuildBaseJob])
      end
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

    def job(name, defined_in:, subclasses: [])
      allow(Object).to receive(:const_source_location).with(name)
        .and_return(defined_in && [ defined_in, 1 ])
      double(name, name: name, queue_name: "default", priority: nil, descendants: subclasses)
    end

    # The fixture app's own job files are merged in from source; these
    # examples are about what reflection reports.
    def names_reported_for(*jobs)
      source_only = described_class.new(Rails.application).static_call[:jobs].map { |j| j[:name] } - jobs.map(&:name)
      allow(ActiveJob::Base).to receive(:descendants).and_return(jobs)
      described_class.new(Rails.application).call[:jobs].map { |j| j[:name] } - source_only
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

    # The static tier drops an abstract base another job inherits from, and a
    # booted app reporting one job more than the same app read statically is a
    # disagreement about what the app runs.
    it "drops an abstract base another job inherits from" do
      base = job("ImportJobBase", defined_in: app_job_file, subclasses: [ "ImportUsersJob" ])
      child = job("ImportUsersJob", defined_in: app_job_file)

      expect(names_reported_for(base, child)).to eq(%w[ImportUsersJob])
    end

    # Only an Active Job record is checked against the queues a worker polls.
    it "marks a reflected job and a reflected base as Active Job" do
      base = job("ImportJobBase", defined_in: app_job_file, subclasses: [ "ImportUsersJob" ])
      child = job("ImportUsersJob", defined_in: app_job_file)
      allow(ActiveJob::Base).to receive(:descendants).and_return([ base, child ])

      result = described_class.new(Rails.application).call

      expect(result[:jobs].find { |j| j[:name] == "ImportUsersJob" }).to include(active_job: true)
      expect(result[:job_bases].find { |b| b[:name] == "ImportJobBase" }).to include(active_job: true)
    end

    it "keeps a job named like a base that nothing inherits from" do
      expect(names_reported_for(job("RebuildBaseJob", defined_in: app_job_file)))
        .to eq(%w[RebuildBaseJob])
    end

    # Reflection lists no Resque job and no PORO - neither is an ActiveJob
    # descendant - so a hybrid app named them under --no-boot and dropped them
    # booted, which is the tier disagreeing about what the app runs.
    it "keeps the jobs reflection cannot see beside the ones it can" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
        File.write(File.join(dir, "app", "jobs", "archive.rb"), <<~RUBY)
          class Archive
            @queue = :file_serve

            def self.perform(id); end
          end
        RUBY
        allow(Rails.application).to receive(:root).and_return(Pathname.new(dir))
        allow(ActiveJob::Base).to receive(:descendants)
          .and_return([ job("RuntimeProbeJob", defined_in: File.join(dir, "app", "jobs", "archive.rb")) ])

        jobs = described_class.new(Rails.application).call[:jobs]

        expect(jobs.map { |j| [ j[:name], j[:unknown_base] ] })
          .to eq([ [ "Archive", true ], [ "RuntimeProbeJob", nil ] ])
      end
    end

    # The queue_name each example reads is what this Rails version stores when
    # the class body runs from the file, so a Proc's text names that file.
    def reflected_job(name, file, from: 2, to: nil)
      source = File.readlines(file)
      klass = Class.new(ActiveJob::Base)
      klass.class_eval(source[(from - 1)...(to || source.size - 1)].join, file, from)
      reflected = job(name, defined_in: file)
      allow(reflected).to receive(:queue_name).and_return(klass.queue_name)
      allow(ActiveJob::Base).to receive(:descendants).and_return([ reflected ])
    end

    def booted_queue(name)
      described_class.new(Rails.application).call[:jobs].find { |j| j[:name] == name }[:queue]
    end

    it "reads a queue_as block as computed, with its source and without its comments" do
      with_job_file("UrgentJob", <<~RUBY) do |file|
        class UrgentJob < ActiveJob::Base
          queue_as do
            # urgent jobs go high
            :high
          end

          def perform; end
        end
      RUBY
        reflected_job("UrgentJob", file)

        expect(booted_queue("UrgentJob")).to eq("computed by a block: `do :high; end`")
      end
    end

    # ActiveJob never calls a lambda given as the argument: it names the queue
    # after the Proc's inspect string, a memory address and a path.
    it "reads a lambda queue_as argument from its source, never as the Proc" do
      with_job_file("UrgentJob", <<~RUBY) do |file|
        class UrgentJob < ActiveJob::Base
          queue_as -> { :high }

          def perform; end
        end
      RUBY
        reflected_job("UrgentJob", file)

        expect(booted_queue("UrgentJob")).to eq("#{described_class::PROC_QUEUE}: `-> { :high }`")
      end
    end

    it "never prints the Proc when the lambda's source is not found" do
      queue_stored_as("ElsewhereJob", "#<Proc:0x0000000100000000 /nowhere/elsewhere_job.rb:2 (lambda)>")

      expect(booted_queue("ElsewhereJob")).to eq(described_class::PROC_QUEUE)
    end

    it "reads a Proc held in a constant as the Proc it is" do
      with_job_file("ConstantJob", <<~RUBY) do |file|
        class ConstantJob < ActiveJob::Base
          QUEUE = -> { :high }
          queue_as QUEUE
        end
      RUBY
        reflected_job("ConstantJob", file)

        expect(booted_queue("ConstantJob")).to eq("#{described_class::PROC_QUEUE}: `-> { :high }`")
      end
    end

    # The parent's queue_as is the nearest one up the class chain, but the
    # concern's runs later and is the one Rails keeps.
    it "reads the Proc a concern's queue_as set, not the parent's literal" do
      with_job_file("RoutedJob", <<~RUBY) do |file|
        class ParentJob < ActiveJob::Base
          queue_as :x
        end

        module Routing
          extend ActiveSupport::Concern
          included do
            queue_as -> { :urgent }
          end
        end

        class RoutedJob < ParentJob
          include Routing
        end
      RUBY
        reflected_job("RoutedJob", file, from: 8, to: 8)

        expect(booted_queue("RoutedJob")).to eq("#{described_class::PROC_QUEUE}: `-> { :urgent }`")
      end
    end

    it "reads the block a concern's queue_as set, not the parent's literal" do
      with_job_file("RoutedJob", <<~RUBY) do |file|
        class ParentJob < ActiveJob::Base
          queue_as :x
        end

        module Routing
          extend ActiveSupport::Concern
          included do
            queue_as { :urgent }
          end
        end
      RUBY
        reflected_job("RoutedJob", file, from: 8, to: 8)

        expect(booted_queue("RoutedJob")).to eq("computed by a block: `{ :urgent }`")
      end
    end

    it "leaves the source out when two Procs share the line that set the queue" do
      with_job_file("TwinJob", <<~RUBY) do |file|
        class TwinJob < ActiveJob::Base
          OTHER = -> { :low }; queue_as -> { :high }
        end
      RUBY
        reflected_job("TwinJob", file)

        expect(booted_queue("TwinJob")).to eq(described_class::PROC_QUEUE)
      end
    end

    def queue_stored_as(name, queue, file: app_job_file)
      reflected = job(name, defined_in: file)
      allow(reflected).to receive(:queue_name).and_return(queue)
      allow(ActiveJob::Base).to receive(:descendants).and_return([ reflected ])
    end

    it "reads no file outside the app a Proc's text names" do
      Dir.mktmpdir do |outside|
        file = File.join(outside, "secret.rb")
        File.write(file, "SECRET = -> { :secret }\n")
        with_job_file("PlainJob", "class PlainJob < ActiveJob::Base\nend\n") do |job_file|
          queue_stored_as("PlainJob", "#<Proc:0x0000000100000000 #{file}:1 (lambda)>", file: job_file)

          expect(booted_queue("PlainJob")).to eq(described_class::PROC_QUEUE)
        end
      end
    end

    it "reads no file outside the app a Proc's text reaches through .." do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "secret.rb"), "SECRET = -> { :secret }\n")
        with_job_file("PlainJob", "class PlainJob < ActiveJob::Base\nend\n") do |job_file|
          climbing = File.join(File.dirname(job_file, 3), "..", File.basename(outside), "secret.rb")
          queue_stored_as("PlainJob", "#<Proc:0x0000000100000000 #{climbing}:1 (lambda)>", file: job_file)

          expect(booted_queue("PlainJob")).to eq(described_class::PROC_QUEUE)
        end
      end
    end

    it "reads no file over the size cap a Proc's text names" do
      with_job_file("PlainJob", "class PlainJob < ActiveJob::Base\nend\n") do |job_file|
        concern = File.join(File.dirname(job_file, 3), "app", "models", "concerns", "routing.rb")
        FileUtils.mkdir_p(File.dirname(concern))
        File.write(concern, "module Routing\n  ROUTE = -> { :urgent }\nend\n# #{'x' * 300}\n")
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(200)
        queue_stored_as("PlainJob", "#<Proc:0x0000000100000000 #{concern}:2 (lambda)>", file: job_file)

        expect(booted_queue("PlainJob")).to eq(described_class::PROC_QUEUE)
      end
    end

    it "never prints a Proc whose text names no file" do
      [ method(:puts).to_proc, lambda(&:to_s) ].each do |stored|
        queue_stored_as("NowhereJob", Class.new(ActiveJob::Base) { queue_as stored }.queue_name)

        expect(booted_queue("NowhereJob")).to eq(described_class::PROC_QUEUE)
      end
    end

    it "reads a block with no source location as computed" do
      queue_stored_as("SymbolJob", Class.new(ActiveJob::Base) { queue_as(&:to_s) }.queue_name)

      expect(booted_queue("SymbolJob")).to eq("computed by a block")
    end

    it "reads a job file's queue from the walk that found the job" do
      with_job_file("UrgentJob", "class UrgentJob < ActiveJob::Base\n  queue_as -> { :high }\nend\n") do |file|
        reflected_job("UrgentJob", file)
        allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk_source).and_call_original

        expect(booted_queue("UrgentJob")).to eq("#{described_class::PROC_QUEUE}: `-> { :high }`")
        expect(RailsAiContext::Introspectors::SourceIntrospector)
          .not_to have_received(:walk_source).with(anything, described_class::QUEUE_AS_LISTENERS)
      end
    end

    # ActiveJob 7.0+ defaults queue_name to a lambda, so every job without a
    # queue_as holds a Proc.
    it "reads the framework's default queue lambda as the default queue" do
      default_job = job("DefaultQueueJob", defined_in: app_job_file)
      allow(default_job).to receive(:queue_name).and_return(ActiveJob::Base.queue_name)
      allow(default_job).to receive(:queue_name_from_part).with(nil).and_return("default")
      allow(ActiveJob::Base).to receive(:descendants).and_return([ default_job ])

      jobs = described_class.new(Rails.application).call[:jobs]

      expect(jobs.find { |j| j[:name] == "DefaultQueueJob" }[:queue]).to eq("default")
    end

    def with_job_file(name, source)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
        file = File.join(dir, "app", "jobs", "#{name.underscore}.rb")
        File.write(file, source)
        allow(Rails.application).to receive(:root).and_return(Pathname.new(dir))
        yield file
      end
    end

    # Reflection knows the queue and nothing about the retry policy; the
    # source carries it, and the booted record must not lose it.
    it "keeps the retries the source declares on a reflected job" do
      with_job_file("DigestJob", <<~RUBY) do |file|
        class DigestJob < ApplicationJob
          retry_on ActiveRecord::Deadlocked,
                   attempts: 3

          def perform(id); end
        end
      RUBY
        allow(ActiveJob::Base).to receive(:descendants).and_return([ job("DigestJob", defined_in: file) ])

        record = described_class.new(Rails.application).call[:jobs].find { |j| j[:name] == "DigestJob" }

        expect(record).to include(queue: "default", perform_signature: "id")
        expect(record[:retries]).to eq([ "retry_on ActiveRecord::Deadlocked, attempts: 3" ])
      end
    end

    # A job in a root Zeitwerk does not manage never loads, so reflection
    # cannot list it; the source still can.
    it "keeps an ActiveJob job reflection never loaded" do
      with_job_file("UnloadedJob", <<~RUBY) do
        class UnloadedJob < ApplicationJob
          queue_as :chat

          def perform; end
        end
      RUBY
        allow(ActiveJob::Base).to receive(:descendants).and_return([ job("RuntimeProbeJob", defined_in: nil) ])

        jobs = described_class.new(Rails.application).call[:jobs]

        expect(jobs.map { |j| [ j[:name], j[:queue] ] }).to eq([ [ "RuntimeProbeJob", "default" ], [ "UnloadedJob", "chat" ] ])
      end
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

    # A mailer file under the app root, autoloaded the way the booted tier
    # finds every other one. An anonymous class would answer a const_source_location
    # outside the app, which is what tells a gem's mailer from the app's.
    def with_mailer(name, source)
      path = File.join(Rails.root, "app", "mailers", "#{name.underscore}.rb")
      File.write(path, source)
      load path
      yield
    ensure
      FileUtils.rm_f(path)
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end

    # Rails dispatches on none of MultiNotifications' methods, and the class is
    # still what three Whitehall models send their notifications through.
    it "keeps a mailer whose interface is class methods" do
      entry = with_mailer("FanoutMailer", <<~RUBY) { mailers.find { |m| m[:name] == "FanoutMailer" } }
        class FanoutMailer < ApplicationMailer
          def self.blast(recipients)
            recipients
          end
        end
      RUBY

      expect(entry).not_to be_nil
      expect(entry[:actions]).to eq([])
      expect(entry[:class_actions]).to eq(%w[blast])
      expect(entry[:parent_class]).to eq("ApplicationMailer")
    end

    # Without eager loading, a mailer kept in app/services or app/models loads
    # only when something names it, so it is loaded by the constant its file holds.
    it "loads a mailer kept outside app/mailers before reading descendants" do
      path = File.join(Rails.root, "app", "models", "services_probe_mailer.rb")
      File.write(path, <<~RUBY)
        class ServicesProbeMailer < ApplicationMailer
          def weekly = mail(to: "a@b.c")
        end
      RUBY
      Object.autoload(:ServicesProbeMailer, path)
      loader = Rails.autoloaders.main
      # Zeitwerk before 2.6.9 cannot name a file, and the file's own declaration names it instead.
      asks_loader = loader.respond_to?(:cpath_expected_at)
      allow(loader).to receive(:cpath_expected_at).and_call_original if asks_loader

      expect(mailers.find { |m| m[:name] == "ServicesProbeMailer" }&.dig(:actions)).to eq(%w[weekly])
      expect(loader).to have_received(:cpath_expected_at).with(path) if asks_loader
    ensure
      FileUtils.rm_f(path)
      Object.send(:remove_const, :ServicesProbeMailer) if Object.const_defined?(:ServicesProbeMailer, false)
    end

    # `action_methods` is every public instance method a mailer defines, so
    # Rails dispatches on a `before_action` filter and on a predicate as
    # readily as on an email. Neither delivers one, and offering them as
    # emails an agent can send is what this drops - the same rule the static
    # tier applies, so the two tiers cannot contradict each other about one
    # mailer. Nothing outside `action_methods` is ever added.
    it "reports what Rails dispatches on, minus what cannot deliver" do
      mailers.each do |mailer|
        klass = mailer[:name].safe_constantize
        next unless klass.respond_to?(:action_methods)

        expect(klass.action_methods.to_a.map(&:to_s)).to include(*mailer[:actions])
      end
    end

    # Forem's DeviseMailer: `use_settings_general_values` is a filter the class
    # registers on itself, and DigestMailer's `user_follows_any_subforems?` is
    # a predicate its own action calls.
    it "drops a callback filter and a predicate from the actions" do
      with_mailer("SubforemMailer", <<~RUBY) do
        class SubforemMailer < ApplicationMailer
          before_action :use_settings_general_values

          def welcome
            mail(to: "test@example.com", subject: "Welcome")
          end

          def use_settings_general_values; end

          def follows_any?
            true
          end
        end
      RUBY
        entry = mailers.find { |m| m[:name] == "SubforemMailer" }

        expect(SubforemMailer.action_methods.to_a.map(&:to_s))
          .to include("use_settings_general_values", "follows_any?")
        expect(entry[:actions]).to eq(%w[welcome])
      end
    end

    # The same rule as the static tier, through the same predicate: the
    # fixture's ApplicationMailer is what NotificationMailer inherits from.
    it "leaves a base other mailers inherit from out of the listing" do
      expect(described_class.new(Rails.application).call[:mailer_bases].map { |b| b[:name] }).to include("ApplicationMailer")
    end

    # `ActionMailer::Base.descendants` is every mailer in the process, gems
    # included, and a name test does not tell one from the app's own.
    it "leaves a gem's mailer out of the app's list" do
      stub_const("VendorGemMailer", Class.new(ActionMailer::Base))

      expect(mailers.map { |m| m[:name] }).not_to include("VendorGemMailer")
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

  describe "a mailer file that cannot load" do
    let(:broken) { File.join(Rails.root, "app", "mailers", "zz_broken_mailer.rb") }

    before { File.write(broken, "class ZzBrokenMailer < ApplicationMailer\n  def oops(\nend\n") }
    after { FileUtils.rm_f(broken) }

    it "costs itself, not the mailers list" do
      mailers = described_class.new(Rails.application).call[:mailers]
      expect(mailers.map { |m| m[:name] }).to include("UserMailer", "NotificationMailer")
      expect(mailers.map { |m| m[:name] }).not_to include("ZzBrokenMailer")
    end
  end

  describe "the carried file" do
    it "is recorded by the static tier for jobs and mailers" do
      result = described_class.new(RailsAiContext::StaticApp.new(IntrospectedFixture::ROOT)).static_call
      expect(result[:jobs].find { |j| j[:name] == "ExampleJob" }[:file]).to eq("app/jobs/example_job.rb")
      expect(result[:mailers].find { |m| m[:name] == "UserMailer" }[:file]).to eq("app/mailers/user_mailer.rb")
    end

    it "is recorded by the booted tier for jobs and mailers" do
      result = described_class.new(Rails.application).call
      expect(result[:jobs].find { |j| j[:name] == "ExampleJob" }[:file]).to eq("app/jobs/example_job.rb")
      expect(result[:mailers].find { |m| m[:name] == "UserMailer" }[:file]).to eq("app/mailers/user_mailer.rb")
    end

    it "is the pack path for a job in a pack" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "jobs"))
        File.write(File.join(dir, "packs", "billing", "app", "jobs", "invoice_job.rb"),
                   "class InvoiceJob < ApplicationJob\n  def perform(id); end\nend\n")

        jobs = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:jobs]
        expect(jobs).to contain_exactly(a_hash_including(name: "InvoiceJob", file: "packs/billing/app/jobs/invoice_job.rb"))
      end
    end

    it "is the path the app spells when the pack is a symlink out of the root" do
      Dir.mktmpdir do |outside|
        FileUtils.mkdir_p(File.join(outside, "billing", "app", "jobs"))
        File.write(File.join(outside, "billing", "app", "jobs", "symlinked_pack_job.rb"),
                   "class SymlinkedPackJob < ActiveJob::Base\n  def perform(id); end\nend\n")
        link = File.join(Rails.root, "packs")
        # Only ever remove the link this example makes. A committed packs
        # fixture would otherwise be deleted by a run of this spec.
        skip "a real packs directory is checked in" if File.exist?(link) && !File.symlink?(link)

        FileUtils.rm_f(link) if File.symlink?(link)
        File.symlink(outside, link)

        begin
          load File.join(link, "billing", "app", "jobs", "symlinked_pack_job.rb")
          jobs = described_class.new(Rails.application).call[:jobs]
          expect(jobs).to include(
            a_hash_including(name: "SymlinkedPackJob", file: "packs/billing/app/jobs/symlinked_pack_job.rb")
          )
        ensure
          FileUtils.rm_f(link) if File.symlink?(link)
          Object.send(:remove_const, :SymlinkedPackJob) if Object.const_defined?(:SymlinkedPackJob)
        end
      end
    end

    # Rails loads a job file the app links in from outside it; the class is
    # listed off reflection, but the file is neither named nor read.
    it "is none for a job file linked from outside the app" do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "secret.rb"),
                   "class LinkedOutJob < ActiveJob::Base\n  queue_as { :outside_secret }\n  def perform(id); end\nend\n")
        link = File.join(Rails.root, "app", "jobs", "linked_out_job.rb")
        skip "a real linked_out_job.rb is checked in" if File.exist?(link) && !File.symlink?(link)

        File.symlink(File.join(outside, "secret.rb"), link)
        begin
          load link
          job = described_class.new(Rails.application).call[:jobs].find { |j| j[:name] == "LinkedOutJob" }
          expect(job).not_to have_key(:file)
          expect(job.to_s).not_to include("outside_secret")
        ensure
          FileUtils.rm_f(link) if File.symlink?(link)
          Object.send(:remove_const, :LinkedOutJob) if Object.const_defined?(:LinkedOutJob)
        end
      end
    end
  end
end
