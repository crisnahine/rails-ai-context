# frozen_string_literal: true

require "mcp"
require "json"

module RailsAiContext
  # Rack middleware that intercepts requests at the configured HTTP path
  # and delegates to the MCP StreamableHTTPTransport. All other requests
  # pass through to the Rails app.
  class Middleware
    def initialize(app)
      @app = app
      @mcp_transport = nil
      @mutex = Mutex.new
    end

    def call(env)
      McpEdge.rack_call(env, transport: transport) { @app.call(env) }
    end

    private

    def transport
      @mutex.synchronize { @mcp_transport ||= McpEdge.build_transport }
    end
  end
end
