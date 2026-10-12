# frozen_string_literal: true

module RailsAiContext
  # Rails controller for serving MCP over Streamable HTTP.
  # Alternative to the Rack middleware - integrates with Rails routing,
  # authentication, and middleware stack.
  #
  # Mount in routes, guarded so the routes file still loads where the gem is
  # not (production, with the gem in the development group, or after it is
  # removed): mount RailsAiContext::Engine, at: "/mcp" if defined?(RailsAiContext::Engine)
  #
  # Every request is answered whole, on the thread Rails runs it on. The SDK
  # answers a request inside a session with a body that writes an SSE stream;
  # this controller runs that body into a buffer and sends the text once the
  # call is done, as a plain string, which every middleware in the app's
  # stack passes through (Rails 7's Rack::ETag 500'd on the callable itself).
  #
  # It used to stream through ActionController::Live, which runs the action
  # on a thread of its own, and that deadlocked a development server. The
  # request's thread holds a share of the code-loading interlock and waits
  # for the Live thread to answer; the Live thread needs a share of its own
  # to start; once another request has queued a code reload after an edit,
  # no new share is granted until the reload runs, and the reload waits for
  # the request's thread to let go of its share. With several clients
  # calling while an agent edited, every request hung within seconds, and
  # SIGTERM waited on them. Live's thread also kept the database connection
  # a call used, and from Rails 8.0 that thread lives on in a pool, so each
  # call after an edit waited ten seconds for the reload to give up on it.
  # On the request's own thread the call needs no second share, the reload
  # waits for it to finish, and Rails returns its connection when the
  # request completes.
  #
  # The cost: what a tool sends during a call reaches the client with the
  # answer, not as it is sent. A custom tool's progress or log notifications
  # arrive together at the end, and a request a tool makes of the client
  # mid-call (sampling, elicitation, roots) fails at once, since no answer
  # could reach it before the call is over (McpEdge::AnsweredWhole). This
  # gem's own tools send neither, and the engine opens no stream of its own
  # (refuse_server_push).
  class McpController < ActionController::API
    # What the SDK's SSE writer needs of a stream - write, flush, close,
    # closed? - held in memory until the call is done. A write after close
    # raises IOError, as a closed socket's does, so the SDK drops a stream
    # the answer has already left on.
    class BufferedStream
      def initialize
        @chunks = []
        @closed = false
      end

      def write(chunk)
        raise IOError, "closed stream" if @closed

        text = chunk.to_s
        @chunks << text
        text.bytesize
      end

      def flush
        self
      end

      def close
        @closed = true
        nil
      end

      def closed?
        @closed
      end

      def string
        @chunks.join
      end
    end

    def handle
      if (refused = McpEdge.production_refusal || McpEdge.host_refusal(request.env))
        return answer_rack(refused)
      end
      return refuse_server_push if request.get?

      Tools::BaseTool.with_session_for(request.env) do
        serve_transport
      end
    rescue => e
      # A transport failure must still answer in JSON-RPC shape. Without this
      # the exception escapes into a generic Rails 500 (HTML), breaking the
      # client's JSON-RPC loop. Nothing has been sent yet, whatever the body
      # had written, so the frame replaces it whole.
      RailsAiContext.log_warn "[rails-ai-context] MCP request failed: #{e.class}: #{e.message}"
      self.status = 500
      response.headers["Content-Type"] = "application/json"
      self.response_body = McpEdge.internal_error_frame(e)
    end

    private

    # The body is read before the status and headers are set, so a body
    # that fails leaves nothing of the SDK's answer on the error frame.
    def serve_transport
      status_code, rack_headers, body = McpEdge.engine_transport.handle_request(request)
      text = read_body(body)
      self.status = status_code
      apply_transport_headers(rack_headers)
      self.response_body = text
    end

    # The SDK's answer as one string: a plain body (initialize, an error, a
    # notification's 202) joined, and a streaming one - the SSE stream a
    # request inside a session gets - run here into a buffer. The tool runs
    # inside it, on this thread, inside this request's session scope. The
    # buffer is closed once the body returns, as the answer leaves with it.
    def read_body(body)
      if body.respond_to?(:each)
        chunks = []
        body.each { |chunk| chunks << chunk }
        chunks.join
      elsif body.respond_to?(:call)
        stream = BufferedStream.new
        begin
          body.call(stream)
        ensure
          stream.close
        end
        stream.string
      else
        body
      end
    ensure
      body.close if body.respond_to?(:close)
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
      # One transport per process, kept by McpEdge.engine_transport.
      def mcp_transport
        McpEdge.engine_transport
      end

      def reset_transport!
        McpEdge.reset_engine_transport!
      end
    end
  end
end
