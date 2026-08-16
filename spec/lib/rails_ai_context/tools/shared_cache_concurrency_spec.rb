# frozen_string_literal: true

require "spec_helper"
require "rack"

# The audit of the two process-global caches BaseTool keeps: the introspection
# cache and the session record. Each property below is either a defect this
# spec pins and the code fixes, or a semantic worth stating so the next reader
# does not have to re-derive it from the mutex.
RSpec.describe "BaseTool shared caches under concurrency" do
  let(:base) { RailsAiContext::Tools::BaseTool }

  describe "the introspection cache" do
    before { base.reset_cache! }

    # Intended semantics, not a defect: every read is a deep copy, so a tool
    # that mutates what it got cannot corrupt the next tool's view. The cost
    # is that the copy happens while the mutex is held.
    it "hands every caller its own copy" do
      first  = base.send(:cached_context)
      second = base.send(:cached_context)

      expect(first).to eq(second)
      expect(first).not_to equal(second)

      first[:models] = { poisoned: true }
      expect(base.send(:cached_context)[:models]).not_to eq(poisoned: true)
    end

    # Intended semantics: the TTL check, the fingerprint walk and the
    # re-introspection all happen under one mutex, so concurrent callers
    # serialize rather than racing. Twenty threads see one introspection.
    it "introspects once no matter how many threads arrive together" do
      allow(RailsAiContext).to receive(:introspect).and_call_original

      results = 20.times.map { Thread.new { base.send(:cached_context) } }.map(&:value)

      expect(RailsAiContext).to have_received(:introspect).once
      expect(results.map { |r| r[:app_name] }.uniq.size).to eq(1)
    end

    it "survives a reset racing against readers" do
      errors = []
      threads = 10.times.map do |i|
        Thread.new do
          i.even? ? base.reset_cache! : base.send(:cached_context)
        rescue => e
          errors << e
        end
      end
      threads.each(&:join)

      expect(errors).to be_empty
    end
  end

  describe "the session record" do
    before { base.session_reset! }
    after { base.session_reset! }

    it "counts repeat calls rather than duplicating them" do
      10.times.map { Thread.new { base.session_record("rails_get_schema", { table: "users" }) } }.each(&:join)

      entries = base.session_queries
      expect(entries.size).to eq(1)
      expect(entries.first[:call_count]).to eq(10)
    end

    it "does not hand out the live entry for a caller to mutate" do
      base.session_record("rails_get_schema", { table: "users" })
      base.session_queries.first[:call_count] = 999

      expect(base.session_queries.first[:call_count]).to eq(1)
    end

    # The defect. The record is process-global, so under a shared HTTP
    # process one client's rails_session_context listed another client's
    # calls - the transports serve many conversations from one process,
    # which the stdio-era "one process, one conversation" comment assumed
    # away.
    it "keeps one client's calls out of another client's record" do
      base.with_session("session-a") { base.session_record("rails_get_schema", { table: "a_only" }) }
      base.with_session("session-b") { base.session_record("rails_get_routes", {}) }

      a_tools = base.with_session("session-a") { base.session_queries }.map { |q| q[:tool] }
      b_tools = base.with_session("session-b") { base.session_queries }.map { |q| q[:tool] }

      expect(a_tools).to eq([ "rails_get_schema" ])
      expect(b_tools).to eq([ "rails_get_routes" ])
    end

    it "keeps concurrent sessions separate" do
      threads = 8.times.map do |i|
        Thread.new do
          base.with_session("session-#{i}") do
            base.session_record("rails_get_schema", { table: "t#{i}" })
            base.session_queries
          end
        end
      end

      threads.map(&:value).each_with_index do |entries, i|
        expect(entries.map { |e| e[:params] }).to eq([ { table: "t#{i}" } ])
      end
    end

    it "falls back to one shared record when no session is named" do
      base.session_record("rails_get_schema", { table: "users" })

      expect(base.session_queries.map { |q| q[:tool] }).to eq([ "rails_get_schema" ])
    end
  end

  # Both HTTP transports run in one process against these caches, so drive
  # them together rather than trusting that the mutex covers it.
  describe "driven through both HTTP transports at once" do
    let(:body) do
      { jsonrpc: "2.0", id: 1, method: "tools/call",
        params: { name: "rails_get_schema", arguments: { detail: "summary" } } }.to_json
    end

    def rack_request(session_id)
      Rack::Request.new(Rack::MockRequest.env_for(
        RailsAiContext.configuration.http_path,
        method: "POST",
        input: body,
        "CONTENT_TYPE" => "application/json",
        "HTTP_ACCEPT" => "application/json, text/event-stream",
        "HTTP_MCP_SESSION_ID" => session_id
      ))
    end

    # All three HTTP entry points read the same header out of the same Rack
    # env; the engine controller reaches it through request.env rather than
    # spelling the Rails header name a third time.
    describe "reading the session from a request" do
      it "takes the client's session id" do
        expect(base.session_from("HTTP_MCP_SESSION_ID" => "abc")).to eq("abc")
      end

      it "falls back to the shared bucket when the client sent none" do
        expect(base.session_from({})).to eq(base::DEFAULT_SESSION)
      end

      it "treats a blank header as no session" do
        expect(base.session_from("HTTP_MCP_SESSION_ID" => "")).to eq(base::DEFAULT_SESSION)
      end

      it "scopes a block to the request's session in one call" do
        seen = nil
        base.with_session_for("HTTP_MCP_SESSION_ID" => "abc") { seen = base.current_session }

        expect(seen).to eq("abc")
        expect(base.current_session).to eq(base::DEFAULT_SESSION)
      end

      it "restores the previous session even when the block raises" do
        expect {
          base.with_session_for("HTTP_MCP_SESSION_ID" => "abc") { raise "boom" }
        }.to raise_error("boom")

        expect(base.current_session).to eq(base::DEFAULT_SESSION)
      end

      it "returns what the block returned" do
        expect(base.with_session_for({}) { :answer }).to eq(:answer)
      end

      # The header is client-controlled and its value becomes a hash key that
      # nothing evicts, in a process that stays up. Reading alone used to
      # grow the record, because the default block writes on lookup.
      it "does not grow a bucket for a session that only read" do
        base.session_reset!

        50.times { |i| base.with_session("reader-#{i}") { base.session_queries } }

        expect(base::SESSION_CONTEXT[:queries].size).to eq(0)
      end

      it "keeps the number of remembered sessions bounded" do
        base.session_reset!

        (base::MAX_SESSIONS + 25).times do |i|
          base.with_session("client-#{i}") { base.session_record("rails_get_schema", { n: i }) }
        end

        expect(base::SESSION_CONTEXT[:queries].size).to be <= base::MAX_SESSIONS
      end

      # Evicting by creation order drops the long-running conversation and
      # keeps a hundred idle newcomers - backwards, on the transport where
      # one session stays open for hours.
      it "keeps a session that is still being used" do
        base.session_reset!

        base.with_session("busy") { base.session_record("rails_get_schema", { n: 0 }) }
        99.times { |i| base.with_session("idle-#{i}") { base.session_record("rails_get_schema", { n: i }) } }
        base.with_session("busy") { base.session_record("rails_get_routes", {}) }

        base.with_session("newcomer") { base.session_record("rails_get_schema", {}) }

        expect(base.with_session("busy") { base.session_queries }).not_to be_empty
        expect(base.with_session("idle-0") { base.session_queries }).to be_empty
      end

      it "keeps the most recent sessions when it evicts" do
        base.session_reset!

        (base::MAX_SESSIONS + 5).times do |i|
          base.with_session("client-#{i}") { base.session_record("rails_get_schema", { n: i }) }
        end

        newest = "client-#{base::MAX_SESSIONS + 4}"
        expect(base.with_session(newest) { base.session_queries }).not_to be_empty
        expect(base.with_session("client-0") { base.session_queries }).to be_empty
      end

      it "caps a session id long enough to be a payload" do
        expect(base.session_from("HTTP_MCP_SESSION_ID" => "z" * 5_000).length).to be <= 200
      end
    end

    # The standalone `rails-ai-context serve --transport http` app is the
    # third HTTP entry point and serves many clients from one process too, so
    # it needs the same session scoping the other two got.
    it "scopes the standalone rack app's requests to the client's session" do
      seen = nil
      transport = instance_double(MCP::Server::Transports::StreamableHTTPTransport)
      allow(transport).to receive(:handle_request) do
        seen = base.current_session
        [ 200, {}, [ "{}" ] ]
      end

      app = RailsAiContext::Server.new(RailsAiContext.default_app).send(:build_rack_app, transport)
      app.call(rack_request("standalone-7").env.merge("PATH_INFO" => "/mcp"))

      expect(seen).to eq("standalone-7")
      expect(base.current_session).to eq(base::DEFAULT_SESSION)
    end

    # The controller memoizes its transport on the class, so building one here
    # leaves it set for whatever runs next - and the example that asserts the
    # controller builds one then sees it already built.
    after { RailsAiContext::McpController.reset_transport! }

    it "serves concurrent requests on both transports without corrupting either cache" do
      base.reset_cache!
      base.session_reset!

      middleware = RailsAiContext::Middleware.new(->(_env) { [ 404, {}, [] ] })
      errors = []

      threads = 12.times.map do |i|
        Thread.new do
          if i.even?
            middleware.call(rack_request("mw-#{i}").env)
          else
            RailsAiContext::McpController.mcp_transport
            base.with_session("sse-#{i}") { base.send(:cached_context) }
          end
        rescue => e
          errors << e
        end
      end
      threads.each(&:join)

      expect(errors).to be_empty
      expect(base.send(:cached_context)).to include(:app_name)
    end
  end
end
