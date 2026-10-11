# frozen_string_literal: true

require "spec_helper"
# The controller reaches MCP::Server through Server#build but never requires
# the SDK itself, so running this file alone leaves MCP undefined.
require "mcp"
require "timeout"

RSpec.describe RailsAiContext::McpController do
  # McpController inherits from ActionController::API.
  # We test the class-level transport memoization, double-checked locking,
  # and the #handle instance method at the unit level (no routing required).

  # Before as well as after: this file asserts the transport gets built, so it
  # must not inherit one that another file left memoized on the class.
  before { described_class.reset_transport! }

  after { described_class.reset_transport! }

  describe ".mcp_transport" do
    it "returns an MCP StreamableHTTPTransport" do
      transport = described_class.mcp_transport
      expect(transport).to be_a(MCP::Server::Transports::StreamableHTTPTransport)
    end

    it "memoizes the transport across calls" do
      first  = described_class.mcp_transport
      second = described_class.mcp_transport
      expect(first).to equal(second)
    end

    it "builds the transport using an HTTP-configured Server" do
      expect(RailsAiContext::Server).to receive(:new)
        .with(Rails.application, transport: :http)
        .and_call_original

      described_class.mcp_transport
    end
  end

  describe ".reset_transport!" do
    it "clears the memoized transport" do
      first = described_class.mcp_transport
      described_class.reset_transport!
      second = described_class.mcp_transport

      expect(first).not_to equal(second)
    end

    it "does not raise when no transport is set" do
      expect { described_class.reset_transport! }.not_to raise_error
    end
  end

  describe "thread safety" do
    it "initializes the transport only once under concurrent access" do
      described_class.reset_transport!

      build_count = Concurrent::AtomicFixnum.new(0)
      allow(RailsAiContext::Server).to receive(:new).and_wrap_original do |original, *args, **kwargs|
        build_count.increment
        original.call(*args, **kwargs)
      end

      threads = 10.times.map do
        Thread.new { described_class.mcp_transport }
      end

      transports = threads.map(&:value)

      # All threads should get the same transport instance
      expect(transports.uniq.size).to eq(1)
      # Server should only have been built once
      expect(build_count.value).to eq(1)
    end
  end

  describe "inherited subclasses" do
    it "serve the one transport the engine keeps" do
      subclass = Class.new(described_class)

      expect(subclass.mcp_transport).to equal(described_class.mcp_transport)
    end
  end

  # The engine's app/controllers is reloaded with the app's code, and the
  # transport memoized on the class went with every edit: each session's next
  # call answered 404 "Session not found", and the old transport's session
  # reaper ran on.
  describe "a reload of the controller class" do
    it "keeps the transport, and with it every session" do
      transport = described_class.mcp_transport
      file = described_class.instance_method(:handle).source_location.first
      RailsAiContext.send(:remove_const, :McpController)
      load file

      expect(RailsAiContext::McpController).not_to equal(described_class)
      expect(RailsAiContext::McpController.mcp_transport).to equal(transport)
    end

    it "is not what a reset is: that closes the transport it drops, stopping its session reaper" do
      transport = described_class.mcp_transport
      expect(transport).to receive(:close).and_call_original

      described_class.reset_transport!
      expect(described_class.mcp_transport).not_to equal(transport)
    end
  end

  describe "#handle" do
    let(:rack_response) do
      [
        200,
        { "Content-Type" => "application/json", "X-Custom" => "value" },
        [ '{"jsonrpc":"2.0","result":{}}' ]
      ]
    end

    let(:transport) do
      instance_double(MCP::Server::Transports::StreamableHTTPTransport, close: nil).tap do |t|
        allow(t).to receive(:handle_request).and_return(rack_response)
      end
    end

    let(:controller) { described_class.new }

    before do
      described_class.reset_transport!
      RailsAiContext::McpEdge.instance_variable_set(:@engine_transport, transport)

      # Set up a minimal request/response for the controller. A POST: a GET
      # asks for the server-push stream, which the engine does not open.
      request = ActionDispatch::TestRequest.create("REQUEST_METHOD" => "POST")
      response = ActionDispatch::TestResponse.new
      controller.instance_variable_set(:@_request, request)
      controller.instance_variable_set(:@_response, response)
      controller.instance_variable_set(:@_action_name, "handle")
    end

    it "delegates to the transport's handle_request" do
      controller.handle
      expect(transport).to have_received(:handle_request)
    end

    it "sets the response status from the Rack response" do
      controller.handle
      expect(controller.response.status).to eq(200)
    end

    it "copies headers from the Rack response" do
      controller.handle
      expect(controller.response.headers["Content-Type"]).to eq("application/json")
      expect(controller.response.headers["X-Custom"]).to eq("value")
    end

    # mcp >= 1.0 returns Rack 3-style lowercase header keys. On Rails 7.0 the
    # response header hash is case-sensitive, so a lowercase "content-type"
    # would never register and Rails would fall back to text/html.
    it "normalizes a lowercase content-type key to Content-Type" do
      allow(transport).to receive(:handle_request).and_return(
        [ 200, { "content-type" => "application/json" }, [ '{"jsonrpc":"2.0","result":{}}' ] ]
      )

      controller.handle
      expect(controller.response.headers["Content-Type"]).to eq("application/json")
    end

    it "sets the response body from the Rack response" do
      controller.handle
      expect(controller.response_body).to eq([ '{"jsonrpc":"2.0","result":{}}' ])
    end

    it "forwards non-200 status codes" do
      allow(transport).to receive(:handle_request).and_return(
        [ 405, { "Content-Type" => "application/json" }, [ '{"error":"method not allowed"}' ] ]
      )

      controller.handle
      expect(controller.response.status).to eq(405)
    end

    # The MCP SDK names headers in lowercase from 1.0 on. Rails 7.1+ stores
    # them case-insensitively so either spelling resolves here; on Rails 7.0
    # the canonical lookup misses a lowercase key and Rails labels the response
    # text/html instead. These pin the contract the controller owns on every
    # version - the 7.0 regression itself is caught by that CI matrix cell.
    %w[content-type Content-Type CONTENT-TYPE].each do |header_name|
      context "when the transport spells the type #{header_name.inspect}" do
        let(:rack_response) do
          [ 200, { header_name => "application/json", "mcp-session-id" => "abc" }, [ "{}" ] ]
        end

        it "types the response as JSON" do
          controller.handle
          expect(controller.response.media_type).to eq("application/json")
        end

        it "passes other headers through untouched" do
          controller.handle
          expect(controller.response.headers["mcp-session-id"]).to eq("abc")
        end
      end
    end

    # Rails 7.1+ resolves either spelling, so the examples above cannot fail on
    # a modern Rails even without the normalization. This one can: it writes
    # into a plain case-sensitive Hash, which is exactly what Rails 7.0's
    # get_header reads (actionpack 7.0 response.rb:179, `headers[key]`).
    it "writes the type under the canonical key a case-sensitive Hash needs" do
      captured = {}
      allow(controller).to receive(:response).and_return(double(headers: captured))

      controller.send(:apply_transport_headers,
                      "content-type" => "application/json", "mcp-session-id" => "abc")

      expect(captured["Content-Type"]).to eq("application/json")
      expect(captured["mcp-session-id"]).to eq("abc")
    end

    it "keeps an SSE content type from a lowercase transport header" do
      allow(transport).to receive(:handle_request)
        .and_return([ 200, { "content-type" => "text/event-stream" }, [ "" ] ])

      controller.handle
      expect(controller.response.media_type).to eq("text/event-stream")
    end

    context "when the transport raises" do
      before do
        allow(transport).to receive(:handle_request).and_raise(RuntimeError, "transport exploded")
        allow(RailsAiContext).to receive(:log_warn)
      end

      it "answers with a 500 JSON-RPC error body instead of raising" do
        controller.handle
        expect(controller.response.status).to eq(500)
      end

      # The frame's contents are McpEdge's, pinned once in mcp_edge_spec.
      # What the controller owes is emitting that frame rather than letting
      # the exception become a generic Rails HTML 500.
      it "returns the shared error frame" do
        controller.handle
        body = controller.response_body.is_a?(Array) ? controller.response_body.join : controller.response_body

        expect(body).to eq(RailsAiContext::McpEdge.internal_error_frame(RuntimeError.new("transport exploded")))
      end

      it "logs the failure" do
        controller.handle
        expect(RailsAiContext).to have_received(:log_warn).with(a_string_matching("transport exploded"))
      end
    end

    # The stream is read before anything is sent, so one that fails partway
    # leaves no half-written SSE answer behind: the client gets the error
    # frame, under the type that says it is JSON.
    context "when a streaming body fails partway" do
      before do
        allow(RailsAiContext).to receive(:log_warn)
        allow(transport).to receive(:handle_request).and_return(
          [ 200, { "Content-Type" => "text/event-stream" }, proc { |stream|
            stream.write("data: partial\n\n")
            raise "stream exploded"
          } ]
        )
      end

      it "answers the shared error frame, and nothing of the stream" do
        controller.handle

        expect(controller.response.status).to eq(500)
        expect(controller.response.media_type).to eq("application/json")
        expect(Array(controller.response_body).join)
          .to eq(RailsAiContext::McpEdge.internal_error_frame(RuntimeError.new("stream exploded")))
      end

      it "logs the failure" do
        controller.handle

        expect(RailsAiContext).to have_received(:log_warn).with(a_string_matching("stream exploded"))
      end
    end

    context "when a plain body fails as it is read" do
      let(:failing_body) do
        Object.new.tap do |body|
          def body.each
            raise "body exploded"
          end
        end
      end

      before do
        allow(RailsAiContext).to receive(:log_warn)
        allow(transport).to receive(:handle_request).and_return(
          [ 200, { "Content-Type" => "application/json" }, failing_body ]
        )
      end

      it "still answers with the shared error frame" do
        controller.handle

        expect(controller.response.status).to eq(500)
        expect(Array(controller.response_body).join)
          .to eq(RailsAiContext::McpEdge.internal_error_frame(RuntimeError.new("body exploded")))
      end
    end
  end

  # A request as a web server runs it: on a thread of its own, through the
  # app's executor, which in development holds the request's share of the
  # code-loading interlock and, as the request ends, takes back the database
  # connection the call used; and the answer read as the server reads it.
  # A thread of its own also keeps that release off the suite's thread,
  # whose connection holds the in-memory test database.
  describe "a request through the app's executor" do
    let(:transport) { instance_double(MCP::Server::Transports::StreamableHTTPTransport, close: nil) }
    let(:app) { ActionDispatch::Executor.new(described_class.action(:handle), Rails.application.executor) }

    before { RailsAiContext::McpEdge.instance_variable_set(:@engine_transport, transport) }

    def request_mcp(body = "{}", headers = {})
      env = Rack::MockRequest.env_for("http://localhost/mcp", method: "POST", input: body,
                                      "CONTENT_TYPE" => "application/json", **headers)
      status, response_headers, response_body = app.call(env)
      text = +""
      response_body.each { |chunk| text << chunk }
      [ status, response_headers, text ]
    ensure
      response_body&.close
    end

    def post_mcp(body = "{}", headers = {})
      Thread.new { request_mcp(body, headers) }.value
    end

    def header(headers, name)
      headers.find { |key, _| key.casecmp?(name) }&.last
    end

    def streamed(&body)
      [ 200, { "content-type" => "text/event-stream" }, body ]
    end

    def wait_until(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      sleep 0.01 until (met = yield) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      met
    end

    it "sends a streamed answer whole, as SSE a client can parse" do
      allow(transport).to receive(:handle_request).and_return(streamed { |stream|
        stream.write(%(data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"working"}}\n\n))
        stream.flush
        stream.write(%(data: {"jsonrpc":"2.0","id":7,"result":{"content":[]}}\n\n))
        stream.flush
        stream.close
      })

      status, headers, text = post_mcp

      expect(status).to eq(200)
      expect(header(headers, "content-type")).to start_with("text/event-stream")
      events = text.scan(/^data: (.*)$/).flatten.map { |data| JSON.parse(data) }
      expect(events.map { |event| event["method"] || event["id"] }).to eq([ "notifications/message", 7 ])
    end

    it "answers a stream that fails partway with the JSON-RPC error frame, and nothing of the stream" do
      allow(RailsAiContext).to receive(:log_warn)
      allow(transport).to receive(:handle_request).and_return(streamed { |stream|
        stream.write("data: partial\n\n")
        raise "stream exploded"
      })

      status, headers, text = post_mcp

      expect(status).to eq(500)
      expect(header(headers, "content-type")).to start_with("application/json")
      expect(text).to eq(RailsAiContext::McpEdge.internal_error_frame(RuntimeError.new("stream exploded")))
    end

    # ActionController::Live ran the call on a thread of its own, which kept
    # the connection the tool queried with: from Rails 8.0 that thread lives
    # on in a pool, and each code reload in development waited ten seconds
    # for the connection before it unloaded anything, so every call after an
    # edit took ten seconds.
    it "runs the call on the request's thread, and Rails takes the call's connection back as the request ends" do
      ran_on = []
      leased = nil
      allow(transport).to receive(:handle_request) do
        ran_on << Thread.current
        streamed do |stream|
          ran_on << Thread.current
          leased = ActiveRecord::Base.connection.tap { |connection| connection.select_value("SELECT 1") }
          stream.write("data: {}\n\n")
        end
      end

      server = Thread.new { request_mcp }

      expect(server.value.values_at(0, 2)).to eq([ 200, "data: {}\n\n" ])
      expect(ran_on).to eq([ server, server ])
      expect(leased).not_to be_in_use
    end

    # Live's thread needs a share of the code-loading interlock to start, and
    # once a reload is queued no new share is granted until it has run. The
    # reload waited for the request's thread, which held its share while it
    # waited for the Live thread: with several clients calling while an agent
    # edited, every request hung. Development's executor gives each request
    # its share; the test environment does not reload, so the spec takes it.
    it "answers while a code reload waits for the request, and lets the reload run once it is done" do
      allow(transport).to receive(:handle_request).and_return(streamed { |stream| stream.write("data: {}\n\n") })
      interlock = ActiveSupport::Dependencies.interlock
      reloaded = Queue.new
      reload = nil
      queued = nil

      server = Thread.new do
        interlock.running do
          reload = Thread.new { interlock.running { interlock.unloading { reloaded << true } } }
          queued = wait_until(5) { interlock.raw_state { |threads| threads.dig(reload, :waiting) } }
          [ request_mcp, reloaded.empty? ]
        end
      end

      answered = server.join(5)
      # A call that never answers must not hold the interlock for the rest of the suite.
      server.kill unless answered
      expect(queued).to be(true)
      expect(answered).to be_truthy, "the call never answered while a code reload waited"
      answer, reload_waited = server.value
      expect(answer.values_at(0, 2)).to eq([ 200, "data: {}\n\n" ])
      expect(reload_waited).to be(true)
      expect(reload.join(5)).to be_truthy
      expect(reloaded.pop(true)).to be(true)
    ensure
      reload&.join(5)
    end

    context "with the transport the engine builds" do
      let(:accept) { { "HTTP_ACCEPT" => "application/json, text/event-stream" } }

      before { described_class.reset_transport! }

      it "answers a request inside a session with the SDK's SSE stream, whole" do
        _status, headers, = post_mcp(JSON.generate(jsonrpc: "2.0", id: 1, method: "initialize",
                                                   params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } }), accept)
        session = { "HTTP_MCP_SESSION_ID" => header(headers, "mcp-session-id"), "HTTP_MCP_PROTOCOL_VERSION" => "2025-06-18", **accept }
        post_mcp(JSON.generate(jsonrpc: "2.0", method: "notifications/initialized"), session)

        status, headers, text = post_mcp(JSON.generate(jsonrpc: "2.0", id: 2, method: "tools/list"), session)

        expect(status).to eq(200)
        expect(header(headers, "content-type")).to start_with("text/event-stream")
        answer = JSON.parse(text[/^data: (.*)$/, 1])
        expect(answer["id"]).to eq(2)
        expect(answer.dig("result", "tools").map { |tool| tool["name"] }).to include("rails_get_schema")
      end

      # Answered whole, the stream `subscriptions/listen` delivers
      # notifications on cannot stay open: the client would get the
      # acknowledgement alone, told it was subscribed, and hear nothing more.
      it "answers subscriptions/listen as a method it does not have, at once" do
        skip "mcp #{MCP::VERSION} has no subscriptions/listen" unless MCP::Server::Transports::StreamableHTTPTransport.method_defined?(:serves_subscriptions_listen?)

        envelope = { "io.modelcontextprotocol/protocolVersion" => "2026-07-28", "io.modelcontextprotocol/clientCapabilities" => {} }
        listen = JSON.generate(jsonrpc: "2.0", id: 1, method: "subscriptions/listen",
                               params: { _meta: envelope, notifications: { toolsListChanged: true } })

        status, _headers, text = post_mcp(listen, { "HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28", "HTTP_MCP_METHOD" => "subscriptions/listen", **accept })

        expect(status).to eq(404)
        expect(JSON.parse(text)).to include("id" => 1, "error" => a_hash_including("code" => -32601))
      end
    end
  end

  # Nothing in the engine sends a server-initiated message, and a held GET
  # cost a thread per client and kept `rails server` from stopping while a
  # client stayed connected. The spec's answer for a server without the
  # channel is 405.
  describe "a GET for the server-push stream" do
    let(:transport) { instance_double(MCP::Server::Transports::StreamableHTTPTransport, handle_request: nil, close: nil) }
    let(:controller) { described_class.new }

    before do
      RailsAiContext::McpEdge.instance_variable_set(:@engine_transport, transport)
      request = ActionDispatch::TestRequest.create("REQUEST_METHOD" => "GET")
      controller.instance_variable_set(:@_request, request)
      controller.instance_variable_set(:@_response, ActionDispatch::TestResponse.new)
      controller.instance_variable_set(:@_action_name, "handle")
    end

    it "answers 405 with a JSON-RPC error and opens no stream" do
      controller.handle

      expect(controller.response.status).to eq(405)
      expect(controller.response.headers["Allow"]).to eq("POST, DELETE")
      expect(JSON.parse(controller.response.body).dig("error", "message")).to include("no server-push stream")
      expect(transport).not_to have_received(:handle_request)
    end
  end

  describe "in production" do
    let(:transport) { instance_double(MCP::Server::Transports::StreamableHTTPTransport, handle_request: nil, close: nil) }
    let(:controller) { described_class.new }

    before do
      RailsAiContext::McpEdge.instance_variable_set(:@production_refusal_logged, nil)
      allow(RailsAiContext).to receive(:environment_name).and_return("production")
      allow(RailsAiContext).to receive(:log_warn)
      RailsAiContext::McpEdge.instance_variable_set(:@engine_transport, transport)
      controller.instance_variable_set(:@_request, ActionDispatch::TestRequest.create("REQUEST_METHOD" => "POST"))
      controller.instance_variable_set(:@_response, ActionDispatch::TestResponse.new)
      controller.instance_variable_set(:@_action_name, "handle")
    end

    it "refuses with a 403 that says how to opt in, and never reaches the transport" do
      controller.handle

      expect(controller.response.status).to eq(403)
      expect(controller.response.media_type).to eq("application/json")
      expect(JSON.parse(controller.response.body).dig("error", "message")).to include("allow_http_in_production")
      expect(transport).not_to have_received(:handle_request)
    end

    it "serves once the app opts in" do
      allow(RailsAiContext.configuration).to receive(:allow_http_in_production).and_return(true)
      allow(transport).to receive(:handle_request).and_return([ 200, { "Content-Type" => "application/json" }, [ "{}" ] ])

      controller.handle

      expect(controller.response.status).to eq(200)
    end
  end

  describe "class hierarchy" do
    it "inherits from ActionController::API" do
      expect(described_class).to be < ActionController::API
    end

    # The deadlock "a request through the app's executor" pins: Live answers
    # on a thread of its own, which needs a share the queued reload holds back.
    it "answers on the request's own thread, without ActionController::Live" do
      expect(described_class.ancestors).not_to include(ActionController::Live)
    end
  end

  describe "BufferedStream" do
    let(:stream) { described_class::BufferedStream.new }

    it "keeps what is written, in order, and refuses a write once closed, as a closed socket does" do
      stream.write("data: 1\n\n")
      stream.flush
      stream.write("data: 2\n\n")
      stream.close

      expect(stream.string).to eq("data: 1\n\ndata: 2\n\n")
      expect(stream).to be_closed
      expect { stream.write("data: 3\n\n") }.to raise_error(IOError)
    end
  end
end
