# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Instrumentation do
  describe ".callback" do
    it "returns a callable" do
      expect(described_class.callback).to respond_to(:call)
    end

    it "instruments with ActiveSupport::Notifications" do
      events = []
      ActiveSupport::Notifications.subscribe(/rails_ai_context/) do |name, _start, _finish, _id, payload|
        events << { name: name, payload: payload }
      end

      callback = described_class.callback
      callback.call({ method: "tools/call", tool: "rails_get_schema" })

      expect(events.size).to eq(1)
      expect(events.first[:name]).to eq("rails_ai_context.tools.call")
      expect(events.first[:payload][:tool]).to eq("rails_get_schema")
    ensure
      ActiveSupport::Notifications.unsubscribe(/rails_ai_context/)
    end

    it "sanitizes method names with slashes to dots" do
      events = []
      ActiveSupport::Notifications.subscribe(/rails_ai_context/) do |name, _start, _finish, _id, _payload|
        events << name
      end

      described_class.callback.call({ method: "resources/read" })
      expect(events.first).to eq("rails_ai_context.resources.read")
    ensure
      ActiveSupport::Notifications.unsubscribe(/rails_ai_context/)
    end

    it "uses 'unknown' when method is missing" do
      events = []
      ActiveSupport::Notifications.subscribe(/rails_ai_context/) do |name, _start, _finish, _id, _payload|
        events << name
      end

      described_class.callback.call({})
      expect(events.first).to eq("rails_ai_context.unknown")
    ensure
      ActiveSupport::Notifications.unsubscribe(/rails_ai_context/)
    end
  end
end
