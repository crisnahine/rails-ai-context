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
      config = RailsAiContext.configuration
      path = config.http_path

      if env["PATH_INFO"] == path || env["PATH_INFO"] == "#{path}/"
        request = Rack::Request.new(env)
        # One process serves every client here, so the session record has to
        # be told which conversation this request belongs to.
        Tools::BaseTool.with_session(env["HTTP_MCP_SESSION_ID"] || Tools::BaseTool::DEFAULT_SESSION) do
          transport.handle_request(request)
        end
      else
        @app.call(env)
      end
    rescue => e
      McpEdge.internal_error_response(e)
    end

    private

    def transport
      @mutex.synchronize { @mcp_transport ||= McpEdge.build_transport }
    end
  end
end
