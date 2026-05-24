# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::SessionContext do
  before { RailsAiContext::Tools::BaseTool.session_reset! }

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call(action: "status")
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "requires action or mark parameter" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("action")
    end

    it "marks a tool as queried" do
      result = described_class.call(mark: "get_schema:users")
      text = result.content.first[:text]
      expect(text).to include("Marked")
    end

    it "shows empty status when nothing queried" do
      RailsAiContext::Tools::BaseTool.session_reset!
      result = described_class.call(action: "status")
      text = result.content.first[:text]
      # session_context itself is excluded from auto-tracking, so status should be empty
      expect(text).to include("No queries recorded")
    end

    it "auto-tracks tool calls via text_response" do
      RailsAiContext::Tools::BaseTool.session_reset!
      # Call a tool - it should auto-record in session
      RailsAiContext::Tools::GetSchema.call(detail: "summary")
      result = described_class.call(action: "status")
      text = result.content.first[:text]
      expect(text).to include("rails_get_schema")
    end

    it "shows recorded queries in status" do
      described_class.call(mark: "get_schema:users")
      result = described_class.call(action: "status")
      text = result.content.first[:text]
      expect(text).to include("get_schema")
      expect(text).to include("users")
    end

    it "returns compressed summary" do
      described_class.call(mark: "get_schema:users")
      described_class.call(mark: "get_model_details:User")
      result = described_class.call(action: "summary")
      text = result.content.first[:text]
      expect(text).to include("get_schema")
      expect(text).to include("get_model_details")
    end

    it "clears session on reset" do
      described_class.call(mark: "get_schema:users")
      described_class.call(action: "reset")
      result = described_class.call(action: "status")
      text = result.content.first[:text]
      expect(text).to include("No queries recorded")
    end

    it "has read-only annotations" do
      annotations = described_class.annotations_value
      expect(annotations.read_only_hint).to eq(true)
    end
  end
end

RSpec.describe "BaseTool session helpers" do
  before { RailsAiContext::Tools::BaseTool.session_reset! }

  it "session_reset! clears all state" do
    RailsAiContext::Tools::BaseTool.session_record("get_schema", { table: "users" })
    RailsAiContext::Tools::BaseTool.session_reset!
    expect(RailsAiContext::Tools::BaseTool.session_queries).to be_empty
  end

  it "is thread-safe for concurrent marks" do
    threads = 10.times.map do |i|
      Thread.new { RailsAiContext::Tools::BaseTool.session_record("tool_#{i}", { param: i }) }
    end
    threads.each(&:join)

    expect(RailsAiContext::Tools::BaseTool.session_queries.size).to eq(10)
  end
end
