# frozen_string_literal: true

require "spec_helper"
require "rails_ai_context/middleware"
require "json"

RSpec.describe RailsAiContext::Middleware do
  let(:inner_app) { ->(_env) { [ 200, { "Content-Type" => "text/plain" }, [ "OK" ] ] } }
  let(:middleware) { described_class.new(inner_app) }

  describe "#call" do
    it "passes non-MCP requests through to the app" do
      env = Rack::MockRequest.env_for("/users")
      status, _headers, body = middleware.call(env)
      expect(status).to eq(200)
      expect(body).to eq([ "OK" ])
    end

    it "intercepts requests at the configured MCP path" do
      env = Rack::MockRequest.env_for("/mcp", method: "POST", input: "{}")
      status, _headers, _body = middleware.call(env)
      # MCP transport will respond (possibly 400/405 for invalid request)
      # but it should NOT be 200 from the inner app
      expect(status).not_to eq(200)
    end

    describe "in production" do
      before do
        RailsAiContext::McpEdge.instance_variable_set(:@production_refusal_logged, nil)
        allow(RailsAiContext).to receive(:environment_name).and_return("production")
        allow(RailsAiContext).to receive(:log_warn)
      end

      it "refuses an MCP request without building the MCP server" do
        allow(RailsAiContext::McpEdge).to receive(:build_transport)

        status, _headers, body = middleware.call(Rack::MockRequest.env_for("/mcp", method: "POST", input: "{}"))

        expect(status).to eq(403)
        expect(body.join).to include("allow_http_in_production")
        expect(RailsAiContext::McpEdge).not_to have_received(:build_transport)
      end

      it "still passes the app's own requests through" do
        expect(middleware.call(Rack::MockRequest.env_for("/users")).first).to eq(200)
      end
    end

    it "lets a downstream app exception propagate instead of answering an MCP error frame" do
      raising = described_class.new(->(_env) { raise "app boom" })
      env = Rack::MockRequest.env_for("/users")

      expect { raising.call(env) }.to raise_error("app boom")
    end

    # What the frame contains is McpEdge's, pinned once in mcp_edge_spec.
    # What this transport owes is routing a raise into it rather than letting
    # the exception reach the rackup.
    it "answers a raising transport with the shared error frame" do
      transport = instance_double(MCP::Server::Transports::StreamableHTTPTransport)
      allow(transport).to receive(:handle_request).and_raise(RuntimeError, "transport boom")
      middleware.instance_variable_set(:@mcp_transport, transport)

      env = Rack::MockRequest.env_for("/mcp", method: "POST", input: "{}")
      status, headers, body = middleware.call(env)

      # Compared against the frame builder rather than the response builder:
      # the latter logs, and an expected value should not do work.
      expect([ status, headers, body.join ]).to eq([
        500,
        { "Content-Type" => "application/json" },
        RailsAiContext::McpEdge.internal_error_frame(RuntimeError.new("transport boom"))
      ])
    end

    it "does not crash non-MCP requests when transport is broken" do
      transport = instance_double(MCP::Server::Transports::StreamableHTTPTransport)
      allow(transport).to receive(:handle_request).and_raise(RuntimeError, "broken")
      middleware.instance_variable_set(:@mcp_transport, transport)

      env = Rack::MockRequest.env_for("/users")
      status, _headers, body = middleware.call(env)
      expect(status).to eq(200)
      expect(body).to eq([ "OK" ])
    end

    it "logs the error via RailsAiContext.log_warn" do
      transport = instance_double(MCP::Server::Transports::StreamableHTTPTransport)
      allow(transport).to receive(:handle_request).and_raise(RuntimeError, "log me")
      middleware.instance_variable_set(:@mcp_transport, transport)

      expect(Rails.logger).to receive(:warn).with(/MCP request failed.*log me/)

      env = Rack::MockRequest.env_for("/mcp", method: "POST", input: "{}")
      middleware.call(env)
    end
  end
end
