# frozen_string_literal: true

module RailsAiContext
  # Rails controller for serving MCP over Streamable HTTP.
  # Alternative to the Rack middleware — integrates with Rails routing,
  # authentication, and middleware stack.
  #
  # Mount in routes: mount RailsAiContext::Engine, at: "/mcp"
  class McpController < ActionController::API
    def handle
      rack_response = self.class.mcp_transport.handle_request(request)
      self.status = rack_response[0]
      rack_response[1].each { |k, v| response.headers[k] = v }
      self.response_body = rack_response[2]
    end

    class << self
      # Class-level memoization — transport persists across requests.
      # Thread-safe: MCP::Server and transport are stateless for reads.
      def mcp_transport
        @mcp_transport || @transport_mutex.synchronize do
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
