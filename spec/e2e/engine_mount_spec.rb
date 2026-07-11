# frozen_string_literal: true

require_relative "e2e_helper"

# HTTP transport via the mounted engine - the README's documented
# `mount RailsAiContext::Engine, at: "/mcp"` path, served by the host app's
# own `rails server` process rather than the gem's standalone HTTP server.
# This route resolves the controller through the engine's route set, which
# the middleware/auto_mount path never exercises: v5.15.0 shipped with the
# mount 500ing on `uninitialized constant McpController` because only the
# middleware path was covered.
#
# Dedicated app: this spec appends the mount line to config/routes.rb.
RSpec.describe "E2E: MCP over mounted engine", type: :e2e do
  before(:all) do
    @builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "engine_mount_app",
      install_path: :in_gemfile
    ).build!

    routes_path = File.join(@builder.app_path, "config", "routes.rb")
    routes = File.read(routes_path)
    File.write(routes_path, routes.sub(
      "Rails.application.routes.draw do",
      "Rails.application.routes.draw do\n  mount RailsAiContext::Engine, at: \"/mcp\"\n"
    ))

    @http = E2E::HttpServerHarness.new(
      @builder,
      command: [ "bundle", "exec", "rails", "server", "-p", "%PORT%", "-b", "127.0.0.1" ]
    ).start!

    @init_response = @http.jsonrpc("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "e2e-harness", version: "0.0.0" }
    })
  end

  after(:all) do
    @http&.stop!
  end

  it "initialize succeeds through the engine route (no routing error)" do
    expect(@init_response["result"]).to be_a(Hash)
    expect(@init_response.dig("result", "serverInfo", "name")).to eq("rails-ai-context")
  end

  it "tools/call returns real app data through the mounted engine" do
    response = @http.jsonrpc("tools/call", { name: "rails_get_schema", arguments: {} })
    content = response.dig("result", "content")
    expect(content).to be_a(Array)
    expect(content.first["text"]).to match(/posts|Post/)
  end
end
