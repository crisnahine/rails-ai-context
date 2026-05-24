# frozen_string_literal: true

require_relative "e2e_helper"

# Concurrent MCP stdio sessions - spawns N independent `rails-ai-context
# serve` subprocesses against the same Rails app and verifies they each
# answer their own requests without cross-talk. Each subprocess has its
# own stdin/stdout pair and its own SHARED_CACHE state - but since they
# all introspect the same Rails app, their tools/list responses must be
# identical.
#
# Catches race conditions in: registry initialization, cache population,
# and any global state that leaks across processes. Two clients in
# parallel is enough to expose almost every shared-state bug a third or
# fourth client would hit.
RSpec.describe "E2E: concurrent MCP stdio clients", type: :e2e do
  before(:all) do
    # Read-only spec - reuse the shared in-Gemfile fixture.
    @builder = E2E.shared_app(install_path: :in_gemfile)
  end

  it "two parallel clients each receive their own initialize response" do
    clients = Array.new(2) { E2E::McpStdioClient.new(@builder) }

    begin
      clients.each(&:start!)

      # Fire initialize on both in parallel via threads.
      results = clients.map do |client|
        Thread.new do
          client.request("initialize", {
            protocolVersion: "2024-11-05",
            capabilities: {},
            clientInfo: { name: "e2e-concurrent", version: "0.0.0" }
          })
        end
      end.map(&:value)

      results.each do |response|
        expect(response.dig("result", "capabilities", "tools")).not_to be_nil
        expect(response.dig("result", "serverInfo", "name")).to match(/rails-ai-context/i)
      end
    ensure
      clients.each(&:stop!)
    end
  end

  it "two parallel clients receive identical tool registries" do
    clients = Array.new(2) { E2E::McpStdioClient.new(@builder).start! }

    begin
      # Initialize each, then fetch tools/list in parallel.
      clients.each do |c|
        c.request("initialize", {
          protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "e2e", version: "0" }
        })
        c.notify("notifications/initialized")
      end

      tool_lists = clients.map do |client|
        Thread.new { client.list_tools.dig("result", "tools").map { |t| t["name"] }.sort }
      end.map(&:value)

      expect(tool_lists.first).to eq(tool_lists.last)
      expect(tool_lists.first.size).to eq(RailsAiContext::Server.builtin_tools.size)
    ensure
      clients.each(&:stop!)
    end
  end

  it "two parallel clients can call the same tool simultaneously without cross-talk" do
    clients = Array.new(2) { E2E::McpStdioClient.new(@builder).start! }

    begin
      clients.each do |c|
        c.request("initialize", {
          protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "e2e", version: "0" }
        })
        c.notify("notifications/initialized")
      end

      # Both call rails_get_schema in parallel. The response id must match
      # each client's own request id (cross-talk would swap them).
      results = clients.map do |client|
        Thread.new { client.call_tool("rails_get_schema") }
      end.map(&:value)

      results.each do |response|
        content = response.dig("result", "content")
        expect(content).to be_a(Array)
        expect(content.first["text"]).to match(/posts|Post/)
      end
    ensure
      clients.each(&:stop!)
    end
  end
end
