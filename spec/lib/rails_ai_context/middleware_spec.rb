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
