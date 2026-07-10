# frozen_string_literal: true

require_relative "e2e_helper"

# MCP stdio protocol round-trip test. Verifies the full JSON-RPC 2.0
# handshake against a real `rails-ai-context serve` subprocess:
#
#   initialize → notifications/initialized → tools/list → tools/call
#
# Uses the in-Gemfile install path because that's what most users have;
# the stdio transport behavior is identical across install paths.
RSpec.describe "E2E: MCP stdio protocol", type: :e2e do
  before(:all) do
    # Read-only spec - reuse the shared in-Gemfile fixture.
    @builder = E2E.shared_app(install_path: :in_gemfile)
    @mcp = E2E::McpStdioClient.new(@builder).start!
  end

  after(:all) do
    @mcp&.stop!
  end

  it "initialize returns server capabilities" do
    response = @mcp.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "e2e-harness", version: "0.0.0" }
    })
    expect(response["result"]).to be_a(Hash)
    expect(response["result"]["protocolVersion"]).to be_a(String)
    expect(response["result"]["capabilities"]).to be_a(Hash)
    expect(response["result"]["capabilities"]).to have_key("tools")
    expect(response["result"]["serverInfo"]).to be_a(Hash)
    expect(response["result"]["serverInfo"]["name"]).to match(/rails-ai-context/i)
  end

  it "tools/list returns all registered tools" do
    @mcp.notify("notifications/initialized")
    response = @mcp.request("tools/list")
    tools = response.dig("result", "tools")
    expect(tools).to be_a(Array)

    expected_count = RailsAiContext::Server.builtin_tools.size
    expect(tools.size).to eq(expected_count), "expected #{expected_count} tools, got #{tools.size}"

    # Every tool must declare name + description + inputSchema
    tools.each do |tool|
      expect(tool).to have_key("name"), "tool missing name: #{tool.inspect}"
      expect(tool).to have_key("description"), "tool missing description: #{tool['name']}"
      expect(tool).to have_key("inputSchema"), "tool missing inputSchema: #{tool['name']}"
      expect(tool["name"]).to match(/\Arails_/), "tool name must be rails_-prefixed: #{tool['name']}"
    end

    # All built-ins must be advertised
    server_names = tools.map { |t| t["name"] }.sort
    local_names  = RailsAiContext::Server.builtin_tools.map(&:tool_name).sort
    expect(server_names).to eq(local_names)
  end

  it "tools/call returns a well-formed response for rails_get_schema" do
    response = @mcp.call_tool("rails_get_schema")
    content = response.dig("result", "content")
    expect(content).to be_a(Array)
    expect(content.first["type"]).to eq("text")
    expect(content.first["text"]).to be_a(String)
    expect(content.first["text"]).not_to be_empty
    # The scaffold created a Post table - expect it in the schema output
    expect(content.first["text"]).to include("posts").or include("Post")
  end

  it "tools/call returns a well-formed response for rails_get_routes" do
    response = @mcp.call_tool("rails_get_routes")
    content = response.dig("result", "content")
    expect(content).to be_a(Array)
    expect(content.first["text"]).to match(/posts|Post/)
  end

  it "tools/call with unknown tool returns a JSON-RPC error and logs quietly" do
    expect {
      @mcp.call_tool("rails_nonexistent_tool_xyz")
    }.to raise_error(E2E::McpStdioClient::Error, /JSON-RPC error/)

    # A bogus tool name is routine client-side traffic, not a server bug -
    # it must not dump a 10-line backtrace to stderr.
    stderr_output = @mcp.read_stderr_available
    expect(stderr_output).to match(/\[rails-ai-context\] request error \(invalid_params\).*Tool not found/)
    expect(stderr_output).not_to include("unhandled exception")

    # The server must still be alive and answering after a routine error.
    response = @mcp.list_tools
    expect(response.dig("result", "tools")).to be_a(Array)
  end
end
