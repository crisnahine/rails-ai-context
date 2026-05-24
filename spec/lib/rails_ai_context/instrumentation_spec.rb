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
      callback.call({ method: "tools/call", tool_name: "rails_get_schema", duration: 42 })

      expect(events.size).to eq(1)
      expect(events.first[:name]).to eq("rails_ai_context.tools.call")
      expect(events.first[:payload][:tool_name]).to eq("rails_get_schema")
      expect(events.first[:payload][:duration]).to eq(42)
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

    # v5.8.1 C2 - the MCP SDK forwards raw tool_arguments to the callback.
    # rails_query receives raw SQL, rails_get_env receives env var names,
    # rails_read_logs receives search patterns. Previously these were
    # forwarded unredacted to every AS::Notifications subscriber.
    describe "tool_arguments redaction (v5.8.1 C2)" do
      it "does NOT forward tool_arguments to subscribers by default" do
        events = []
        ActiveSupport::Notifications.subscribe(/rails_ai_context/) do |_n, _s, _f, _id, payload|
          events << payload
        end

        described_class.callback.call({
          method: "tools/call",
          tool_name: "rails_query",
          tool_arguments: { sql: "SELECT password_digest FROM users" },
          duration: 10
        })

        payload = events.first
        expect(payload).not_to have_key(:tool_arguments)
        expect(payload).not_to have_key(:arguments)
        expect(payload.to_s).not_to include("password_digest")
        expect(payload.to_s).not_to include("SELECT")
        # metadata still present
        expect(payload[:tool_name]).to eq("rails_query")
        expect(payload[:duration]).to eq(10)
      ensure
        ActiveSupport::Notifications.unsubscribe(/rails_ai_context/)
      end

      it "forwards tool_arguments when the user opts in via config" do
        original = RailsAiContext.configuration.instrumentation_include_arguments
        RailsAiContext.configuration.instrumentation_include_arguments = true

        events = []
        ActiveSupport::Notifications.subscribe(/rails_ai_context/) do |_n, _s, _f, _id, payload|
          events << payload
        end

        described_class.callback.call({
          method: "tools/call",
          tool_name: "rails_query",
          tool_arguments: { sql: "SELECT id FROM users" }
        })

        expect(events.first[:tool_arguments]).to eq({ sql: "SELECT id FROM users" })
      ensure
        ActiveSupport::Notifications.unsubscribe(/rails_ai_context/)
        RailsAiContext.configuration.instrumentation_include_arguments = original
      end
    end

    # v5.8.1 C2 - a failing subscriber must not crash the tool call. The MCP
    # SDK invokes this callback from an ensure block, so any exception would
    # overwrite the tool's actual return value.
    describe "subscriber failure isolation (v5.8.1 C2)" do
      it "swallows subscriber exceptions instead of crashing the tool call" do
        ActiveSupport::Notifications.subscribe(/rails_ai_context/) do |_n, _s, _f, _id, _payload|
          raise "simulated subscriber crash (Datadog dropped connection, etc.)"
        end

        # Should not raise - callback must rescue internally.
        expect {
          described_class.callback.call({ method: "tools/call", tool_name: "rails_get_schema" })
        }.not_to raise_error
      ensure
        ActiveSupport::Notifications.unsubscribe(/rails_ai_context/)
      end
    end
  end

  describe ".build_payload" do
    it "keeps only metadata fields" do
      payload = described_class.build_payload({
        method: "tools/call",
        tool_name: "rails_query",
        tool_arguments: { sql: "SECRET" },
        duration: 5,
        error: nil,
        resource_uri: "rails-ai-context://models/User",
        extra_field_from_future_sdk: "ignored"
      })

      expect(payload.keys).to contain_exactly(:method, :tool_name, :duration, :error, :resource_uri)
      expect(payload).not_to have_key(:tool_arguments)
      expect(payload).not_to have_key(:extra_field_from_future_sdk)
    end

    it "passes arguments through when opt-in is true" do
      original = RailsAiContext.configuration.instrumentation_include_arguments
      RailsAiContext.configuration.instrumentation_include_arguments = true

      payload = described_class.build_payload({
        method: "tools/call",
        tool_name: "rails_query",
        tool_arguments: { sql: "SELECT 1" }
      })

      expect(payload[:tool_arguments]).to eq({ sql: "SELECT 1" })
    ensure
      RailsAiContext.configuration.instrumentation_include_arguments = original
    end
  end
end
