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

    # The transport is built on the first MCP request, not the first request
    # of any kind: building it builds the whole MCP server.
    def call(env)
      return @app.call(env) unless McpEdge.mcp_request?(env)

      McpEdge.production_refusal || McpEdge.serve(env, transport)
    end

    private

    def transport
      @mutex.synchronize { @mcp_transport ||= McpEdge.build_transport }
    end
  end
end
