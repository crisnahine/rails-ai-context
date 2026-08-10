# frozen_string_literal: true

require "mcp"
require "json"

module RailsAiContext
  # What the three HTTP entry points - the standalone rack app, the Rack
  # middleware and the engine controller - have in common: how a transport is
  # built, and what a transport failure looks like on the wire. Their genuine
  # differences (streaming, header handling, memoization lifetime) stay with
  # them.
  module McpEdge
    INTERNAL_ERROR = -32603

    class << self
      # None of the three sits behind anything that would turn an exception
      # into a JSON-RPC reply, so each has to answer in JSON-RPC shape itself
      # or leave the client's request loop hanging on a non-JSON body.
      def internal_error_frame(error)
        {
          jsonrpc: "2.0",
          error: { code: INTERNAL_ERROR, message: "Internal error: #{error.message}" },
          id: nil
        }.to_json
      end

      # The Rack-shaped answer, for the two entry points that return triples.
      def internal_error_response(error)
        RailsAiContext.log_warn "[rails-ai-context] MCP request failed: #{error.class}: #{error.message}"

        [ 500, { "Content-Type" => "application/json" }, [ internal_error_frame(error) ] ]
      end

      # Memoization is the caller's: the middleware holds one per instance,
      # the controller one per class, and the standalone server one per
      # process.
      def build_transport(app = nil)
        app ||= Rails.application
        MCP::Server::Transports::StreamableHTTPTransport.new(Server.new(app, transport: :http).build)
      end
    end
  end
end
