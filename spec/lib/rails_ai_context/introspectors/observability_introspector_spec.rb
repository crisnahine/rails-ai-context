# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ObservabilityIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns a Hash without error" do
      expect(result).to be_a(Hash)
      expect(result).not_to have_key(:error)
    end

    it "returns log_subscribers as array" do
      expect(result[:log_subscribers]).to be_an(Array)
    end

    it "returns notification_subscribers as array" do
      expect(result[:notification_subscribers]).to be_an(Array)
    end

    it "returns server_timing as Hash" do
      expect(result[:server_timing]).to be_a(Hash)
      expect(result[:server_timing]).to have_key(:middleware_inserted)
    end

    it "returns event_reporter with :available key" do
      expect(result[:event_reporter]).to be_a(Hash)
      expect(result[:event_reporter][:available]).to eq(true).or(eq(false))
    end

    it "returns log_level as non-empty string" do
      expect(result[:log_level]).to be_a(String)
      expect(result[:log_level]).not_to be_empty
    end

    it "returns log_tags as array" do
      expect(result[:log_tags]).to be_an(Array)
    end

    it "returns colorize_logging as boolean" do
      expect(result[:colorize_logging]).to eq(true).or(eq(false))
    end

    it "returns known_events catalog with expected namespaces" do
      expect(result[:known_events]).to be_a(Hash)
      expect(result[:known_events].keys).to include(:action_controller, :active_record, :active_job)
    end

    it "known_events lists specific Rails event names" do
      expect(result[:known_events][:action_controller]).to include("process_action.action_controller")
      expect(result[:known_events][:active_record]).to include("sql.active_record")
    end

    context "with a subscribed notification" do
      before do
        @sub = ActiveSupport::Notifications.subscribe("my.test.event") { |*| }
      end

      after { ActiveSupport::Notifications.unsubscribe(@sub) }

      it "includes subscriptions in the subscribers list" do
        patterns = result[:notification_subscribers].map { |s| s[:pattern] }
        expect(patterns).to include("my.test.event")
      end
    end

    context "with a Regexp-pattern subscription (@other_subscribers path)" do
      before do
        @regexp_sub = ActiveSupport::Notifications.subscribe(/\Atest\.regexp\.[a-z]+\z/) { |*| }
      end

      after { ActiveSupport::Notifications.unsubscribe(@regexp_sub) }

      it "walks the @other_subscribers ivar and surfaces the Regexp pattern" do
        patterns = result[:notification_subscribers].map { |s| s[:pattern] }
        # The Regexp's source is captured via subscriber_raw_pattern.
        expect(patterns).to include(a_string_matching(/test\\\.regexp/))
      end
    end
  end
end
