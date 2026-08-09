# frozen_string_literal: true

require "delegate"

module RailsAiContext
  # Rails controller for serving MCP over Streamable HTTP.
  # Alternative to the Rack middleware - integrates with Rails routing,
  # authentication, and middleware stack.
  #
  # Mount in routes: mount RailsAiContext::Engine, at: "/mcp"
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
    # already delivered and tear down long-lived GET streams.
    class FlushableStream < SimpleDelegator
      def flush; end
    end

    def handle
      status_code, rack_headers, body = self.class.mcp_transport.handle_request(request)
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
          # A GET opens the server-push channel: the transport registers the
          # stream and returns, expecting it to outlive this call. Live closes
          # the response when the action returns, so hold the thread until the
          # transport's keepalive (or the client) closes the stream. Live also
          # sends headers only on the first write - the transport writes
          # nothing until its first keepalive ping, so commit with an SSE
          # comment up front or clients sit waiting on headers.
          if request.get?
            begin
              stream.write(": connected\n\n")
            rescue IOError
              nil
            end
            wait_for_stream_close
          end
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

      # Mirror Middleware#json_rpc_error_response: a transport failure must
      # still answer in JSON-RPC shape. Without this the exception escapes
      # into a generic Rails 500 (HTML), breaking the client's JSON-RPC loop.
      RailsAiContext.log_warn "[rails-ai-context] MCP request failed: #{e.class}: #{e.message}"
      self.status = 500
      response.headers["Content-Type"] = "application/json"
      self.response_body = {
        jsonrpc: "2.0",
        error: { code: -32603, message: "Internal error: #{e.message}" },
        id: nil
      }.to_json
    end

    private

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

    def wait_for_stream_close
      sleep 0.5 until stream_finished?
    rescue IOError
      nil
    end

    # A client hangup aborts the buffer instead of closing it, so `closed?`
    # alone leaves this thread parked until the transport's next keepalive
    # write notices the hangup - up to the keepalive interval per dropped
    # client. Live's buffer reports the hangup through `connected?`; the plain
    # buffer used off the streaming path does not define it, so ask first.
    def stream_finished?
      stream = response.stream
      return true if stream.closed?

      stream.respond_to?(:connected?) && !stream.connected?
    end

    class << self
      # Class-level memoization - transport persists across requests.
      # Thread-safe: MCP::Server and transport are stateless for reads.
      def mcp_transport
        @transport_mutex.synchronize do
          @mcp_transport ||= begin
            server = RailsAiContext::Server.new(Rails.application, transport: :http).build
            MCP::Server::Transports::StreamableHTTPTransport.new(server)
          end
        end
      end

      def reset_transport!
        @transport_mutex.synchronize { @mcp_transport = nil }
      end

      private

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@transport_mutex, Mutex.new)
      end
    end

    @transport_mutex = Mutex.new
  end
end
