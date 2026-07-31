# frozen_string_literal: true

require "spec_helper"
# The controller reaches MCP::Server through Server#build but never requires
# the SDK itself, so running this file alone leaves MCP undefined.
require "mcp"

RSpec.describe RailsAiContext::McpController do
  # McpController inherits from ActionController::API.
  # We test the class-level transport memoization, double-checked locking,
  # and the #handle instance method at the unit level (no routing required).

  after do
    # Clean up any transport state between examples
    described_class.reset_transport!
  end

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
    it "get their own mutex (not shared with parent)" do
      subclass = Class.new(described_class)
      parent_mutex = described_class.instance_variable_get(:@transport_mutex)
      child_mutex = subclass.instance_variable_get(:@transport_mutex)

      expect(child_mutex).to be_a(Mutex)
      expect(child_mutex).not_to equal(parent_mutex)
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
      instance_double(MCP::Server::Transports::StreamableHTTPTransport).tap do |t|
        allow(t).to receive(:handle_request).and_return(rack_response)
      end
    end

    let(:controller) { described_class.new }

    before do
      described_class.reset_transport!
      described_class.instance_variable_set(:@mcp_transport, transport)

      # Set up a minimal request/response for the controller
      request = ActionDispatch::TestRequest.create
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

    context "when the transport raises" do
      before do
        allow(transport).to receive(:handle_request).and_raise(RuntimeError, "transport exploded")
        allow(RailsAiContext).to receive(:log_warn)
      end

      it "answers with a 500 JSON-RPC error body instead of raising" do
        controller.handle
        expect(controller.response.status).to eq(500)
      end

      it "returns a -32603 JSON-RPC frame" do
        controller.handle
        body = controller.response_body.is_a?(Array) ? controller.response_body.join : controller.response_body
        parsed = JSON.parse(body)
        expect(parsed["jsonrpc"]).to eq("2.0")
        expect(parsed["error"]["code"]).to eq(-32603)
        expect(parsed["error"]["message"]).to include("transport exploded")
        expect(parsed["id"]).to be_nil
      end

      it "logs the failure" do
        controller.handle
        expect(RailsAiContext).to have_received(:log_warn).with(a_string_matching("transport exploded"))
      end
    end

    context "when a streaming body fails after the response is committed" do
      let(:streaming_body) do
        proc do |stream|
          stream.write("data: partial\n\n")
          raise "stream exploded"
        end
      end

      before do
        allow(transport).to receive(:handle_request).and_return(
          [ 200, { "Content-Type" => "text/event-stream" }, streaming_body ]
        )
        allow(RailsAiContext).to receive(:log_warn)
      end

      it "re-raises so Rails' streaming error path owns the failure" do
        expect { controller.handle }.to raise_error(RuntimeError, "stream exploded")
      end

      it "leaves the status already sent to the client alone" do
        expect { controller.handle }.to raise_error(RuntimeError)
        expect(controller.response.status).to eq(200)
      end

      it "leaves the headers already sent to the client alone" do
        expect { controller.handle }.to raise_error(RuntimeError)
        expect(controller.response.headers["Content-Type"]).to include("text/event-stream")
      end

      it "does not swap the stream the server is draining" do
        expect { controller.handle }.to raise_error(RuntimeError)
        expect(controller.response.body).to eq("data: partial\n\n")
      end

      it "does not report a committed-stream failure as an MCP request failure" do
        expect { controller.handle }.to raise_error(RuntimeError)
        expect(RailsAiContext).not_to have_received(:log_warn)
      end
    end

    context "when the failure happens before anything is committed" do
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

      it "still answers with a 500 JSON-RPC frame" do
        controller.handle
        expect(controller.response.status).to eq(500)
        expect(JSON.parse(Array(controller.response_body).join)["error"]["code"]).to eq(-32603)
      end
    end
  end

  describe "class hierarchy" do
    it "inherits from ActionController::API" do
      expect(described_class).to be < ActionController::API
    end
  end
end
