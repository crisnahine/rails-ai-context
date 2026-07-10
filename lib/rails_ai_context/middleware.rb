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
        transport.handle_request(request)
      else
        @app.call(env)
      end
    rescue => e
      RailsAiContext.log_warn "[rails-ai-context] MCP request failed: #{e.class}: #{e.message}"
      json_rpc_error_response(e)
    end

    private

    def transport
      @mutex.synchronize do
        @mcp_transport ||= begin
          server = Server.new(Rails.application, transport: :http).build
          MCP::Server::Transports::StreamableHTTPTransport.new(server)
        end
      end
    end

    def json_rpc_error_response(error)
      body = {
        jsonrpc: "2.0",
        error: {
          code: -32603,
          message: "Internal error: #{error.message}"
        },
        id: nil
      }.to_json

      [ 500, { "Content-Type" => "application/json" }, [ body ] ]
    end
  end
end
