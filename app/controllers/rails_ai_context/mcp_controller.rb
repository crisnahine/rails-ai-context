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
      rack_headers.each { |k, v| response.headers[k] = v }

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
    end

    private

    def wait_for_stream_close
      sleep 0.5 until response.stream.closed?
    rescue IOError
      nil
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
