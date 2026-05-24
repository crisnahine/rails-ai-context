# frozen_string_literal: true

require_relative "e2e_helper"

# MCP HTTP protocol round-trip test. Boots a real Rails server in the test
# app on a free local port (Railtie auto-mounts the Rack middleware at
# /mcp) and sends JSON-RPC POST requests over HTTP.
#
# This verifies the HTTP transport path — distinct from stdio. Many
# deployed MCP clients (especially team/shared contexts) use HTTP rather
# than spawning one stdio server per consumer.
RSpec.describe "E2E: MCP HTTP protocol", type: :e2e do
  before(:all) do
    @builder = E2E.shared_app(install_path: :in_gemfile)
    @http = E2E::HttpServerHarness.new(@builder).start!
    @init_response = @http.jsonrpc("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "e2e-harness", version: "0.0.0" }
    })
  end

  after(:all) do
    @http&.stop!
  end

  it "initialize returns server capabilities over HTTP" do
    expect(@init_response["result"]).to be_a(Hash)
    expect(@init_response["result"]["capabilities"]).to have_key("tools")
  end

  it "tools/list returns the full tool registry over HTTP" do
    response = @http.jsonrpc("tools/list")
    tools = response.dig("result", "tools")
    expect(tools).to be_a(Array)
    expect(tools.size).to eq(RailsAiContext::Server.builtin_tools.size)
  end

  it "tools/call works over HTTP for rails_get_schema" do
    response = @http.jsonrpc("tools/call", { name: "rails_get_schema", arguments: {} })
    content = response.dig("result", "content")
    expect(content).to be_a(Array)
    expect(content.first["text"]).to match(/posts|Post/)
  end
end
