# frozen_string_literal: true

require "delegate"

module RailsAiContext
  # Rails controller for serving MCP over Streamable HTTP.
  # Alternative to the Rack middleware - integrates with Rails routing,
  # authentication, and middleware stack.
  #
  # Mount in routes, guarded so the routes file still loads where the gem is
  # not (production, with the gem in the development group, or after it is
  # removed): mount RailsAiContext::Engine, at: "/mcp" if defined?(RailsAiContext::Engine)
  class McpController < ActionController::API
    # Live: the transport answers SSE-mode requests with a Rack 3 streaming
    # body (a Proc that writes to a stream). Handing that Proc to a plain
    # controller works only where the response body passes through untouched;
    # Rails 7.x's response buffer feeds it through Rack::ETag, which 500s on
    # the callable. Live's stream is exactly the interface the Proc expects
    # (write/close) and keeps every middleware away from the body on all
    # supported Rails versions.
    include ActionController::Live

    # The MCP SDK's SSE writer calls stream.flush after every event, but
    # Live's buffer writes straight through to the client and defines no
    # flush - the NoMethodError would 500 the request after the payload was
    # already delivered.
    class FlushableStream < SimpleDelegator
      def flush; end
    end

    def handle
      if (refused = McpEdge.production_refusal)
        return answer_rack(refused)
      end
      return refuse_server_push if request.get?

      Tools::BaseTool.with_session_for(request.env) do
        serve_transport
      end
    rescue => e
      # Once the response is committed the status and headers are already on
      # the wire, so a JSON-RPC frame written here cannot reach the client.
      # Worse, assigning a body swaps the stream out from under the thread
      # still draining the old one, turning a truncated SSE stream into a
      # garbled one. The streaming branch's ensure always closes the stream,
      # and closing commits, so every streaming failure lands here committed.
      # Hand those to Live, which logs them with a backtrace and tears the
      # connection down.
      raise if response.committed?

      # A transport failure must still answer in JSON-RPC shape. Without this
      # the exception escapes into a generic Rails 500 (HTML), breaking the
      # client's JSON-RPC loop.
      RailsAiContext.log_warn "[rails-ai-context] MCP request failed: #{e.class}: #{e.message}"
      self.status = 500
      response.headers["Content-Type"] = "application/json"
      self.response_body = McpEdge.internal_error_frame(e)
    end

    private

    def serve_transport
      status_code, rack_headers, body = McpEdge.engine_transport.handle_request(request)
      self.status = status_code
      apply_transport_headers(rack_headers)
      if body.respond_to?(:each)
        # Plain enumerable body (initialize, errors, JSON mode): join to a
        # string so Content-Length/ETag semantics stay conventional.
        chunks = []
        body.each { |chunk| chunks << chunk }
        body.close if body.respond_to?(:close)
        self.response_body = chunks.join
      elsif body.respond_to?(:call)
        stream = response.stream
        stream = FlushableStream.new(stream) unless stream.respond_to?(:flush)
        begin
          body.call(stream)
        ensure
          begin
            response.stream.close
          rescue StandardError
            nil
          end
        end
      else
        self.response_body = body
      end
    end

    # Rack 3 transports name their headers in lowercase, and the MCP SDK
    # switched to that in 1.0. Rails 7.0 keeps response headers in a
    # case-sensitive Hash, so a lowercase "content-type" is invisible to the
    # canonical lookup Rails makes when it commits, and it labels the response
    # with its own text/html default - a correct JSON-RPC body under a type no
    # client will parse. Rails 7.1 moved to case-insensitive Rack::Headers and
    # does not have the problem. Only the type needs the canonical spelling,
    # because Rails is the only reader that looks a header up by name; the
    # value is passed through so nothing gains a charset it did not have.
    def apply_transport_headers(rack_headers)
      rack_headers.each do |name, value|
        key = name.to_s.casecmp?("content-type") ? "Content-Type" : name
        response.headers[key] = value
      end
    end

    # A Rack triple answered whole, for the refusals McpEdge builds.
    def answer_rack((status, headers, body))
      self.status = status
      apply_transport_headers(headers)
      self.response_body = body.join
    end

    # The engine has nothing to push: live reload, the one thing that sends
    # a server-initiated message, runs only in the standalone server. Held
    # open, the GET channel carried keepalive pings and nothing else, cost a
    # server thread per connected client, and a client that stayed connected
    # kept `rails server` from stopping. A server without the channel answers
    # the GET with 405, which clients read as "POST only".
    def refuse_server_push
      self.status = 405
      response.headers["Allow"] = "POST, DELETE"
      response.headers["Content-Type"] = "application/json"
      self.response_body = McpEdge.error_frame(McpEdge::INVALID_REQUEST,
        "Method not allowed: this endpoint opens no server-push stream. Send requests with POST.")
    end

    class << self
      # The transport outlives this class, which the app's reloader replaces
      # on every edit in development (McpEdge.engine_transport).
      def mcp_transport
        McpEdge.engine_transport
      end

      def reset_transport!
        McpEdge.reset_engine_transport!
      end
    end
  end
end
