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
end
