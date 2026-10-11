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
      expect(result.error?).to be(true)
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

    # One HTTP process serves every client, so a reset is the caller's own.
    it "clears only the calling conversation's record on reset" do
      base = RailsAiContext::Tools::BaseTool
      base.with_session("a") { described_class.call(mark: "get_schema:users") }
      base.with_session("b") { described_class.call(mark: "get_routes:posts") }

      base.with_session("b") { described_class.call(action: "reset") }

      expect(base.with_session("a") { base.session_queries }.map { |q| q[:tool] }).to eq([ "rails_get_schema" ])
      expect(base.with_session("b") { base.session_queries }).to be_empty
    end

    it "records a mark under the name the server gives the tool" do
      described_class.call(mark: "schema:users")

      expect(RailsAiContext::Tools::BaseTool.session_queries.map { |q| q[:tool] }).to eq([ "rails_get_schema" ])
    end

    it "refuses a mark that names no tool" do
      result = described_class.call(mark: "")

      expect(result.error?).to be(true)
      expect(result.content.first[:text]).to include("names no tool")
      expect(RailsAiContext::Tools::BaseTool.session_queries).to be_empty
    end

    it "refuses a mark that names a tool the server does not have" do
      result = described_class.call(mark: "not_a_tool:x")

      expect(result.error?).to be(true)
      expect(result.content.first[:text]).to include("Unknown tool 'not_a_tool'")
      expect(RailsAiContext::Tools::BaseTool.session_queries).to be_empty
    end

    it "has read-only annotations" do
      annotations = described_class.annotations_value
      expect(annotations.read_only_hint).to eq(true)
    end

    # A 100 KB mark came back whole, was kept whole, and the next summary
    # was 100,402 bytes.
    it "echoes and keeps a long mark as an answer echoes it" do
      long = "a" * 100_000

      replies = [ described_class.call(mark: "schema:#{long}"), described_class.call(mark: long),
                  described_class.call(action: "summary"), described_class.call(action: "status") ]

      expect(replies.map { |r| r.content.first[:text].length }).to all(be < 1_000)
      expect(replies.first.content.first[:text]).to include("#{"a" * 80}... (100000 characters)")
      expect(RailsAiContext::Tools::BaseTool.session_queries.first[:params].length).to be < 120
    end

    it "keeps the latest queries of a session and says how many it dropped" do
      base = RailsAiContext::Tools::BaseTool
      (base::MAX_SESSION_QUERIES + 3).times { |i| base.session_record("rails_get_schema", { table: "t#{i}" }) }
      base.session_record("rails_get_schema", { table: "t3" })
      base.session_record("rails_get_schema", { table: "fresh" })

      kept = base.session_queries.map { |q| q[:params][:table] }
      text = described_class.call(action: "status").content.first[:text]

      expect(kept.size).to eq(base::MAX_SESSION_QUERIES)
      expect(kept).to include("t3", "fresh")
      expect(kept).not_to include("t0", "t1", "t2", "t4")
      expect(text).to include("_4 older queries dropped: the record keeps the latest #{base::MAX_SESSION_QUERIES}._")
      expect(described_class.call(action: "summary").content.first[:text]).to include("4 older queries dropped")
    end
  end

  # The note tells an agent which surface cannot track a session; in a
  # standalone install the CLI is the binary, not a rake task.
  describe "the note about the CLI" do
    def note(standalone:)
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(standalone)
      RailsAiContext::Tools::BaseTool.session_reset!
      described_class.call(action: "status").content.first[:text]
    end

    it "names the binary in a standalone install" do
      text = note(standalone: true)

      expect(text).to include("CLI (`rails-ai-context tool`)")
      expect(text).not_to include("rails ai:tool")
    end

    it "names the rake task where the app bundles the gem" do
      expect(note(standalone: false)).to include("CLI (`rails ai:tool`)")
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
