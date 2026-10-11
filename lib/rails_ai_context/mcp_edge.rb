# frozen_string_literal: true

require "mcp"
require "json"

module RailsAiContext
  # What the three HTTP entry points - the standalone rack app, the Rack
  # middleware and the engine controller - have in common: how a transport is
  # built, which conversation a request belongs to, and what a transport
  # failure looks like on the wire. Their genuine differences (streaming,
  # header handling, memoization lifetime) stay with them.
  module McpEdge
    INVALID_REQUEST = -32600
    INTERNAL_ERROR = -32603

    class << self
      # None of the three sits behind anything that would turn an exception
      # into a JSON-RPC reply, so each has to answer in JSON-RPC shape itself
      # or leave the client's request loop hanging on a non-JSON body.
      def internal_error_frame(error)
        error_frame(INTERNAL_ERROR, "Internal error: #{error.message}")
      end

      # JSON.generate rather than to_json: ActiveSupport replaces to_json,
      # and in an app whose encoder raises (Rails 8.0 under json 3: "unknown
      # keyword: quirks_mode") the frame that should name the failure failed
      # with it, so the client got the web server's plain-text 500.
      def error_frame(code, message)
        JSON.generate({ jsonrpc: "2.0", error: { code: code, message: message }, id: nil })
      end

      # The Rack-shaped answer, for the two entry points that return triples.
      def internal_error_response(error)
        RailsAiContext.log_warn "[rails-ai-context] MCP request failed: #{error.class}: #{error.message}"

        [ 500, { "Content-Type" => "application/json" }, [ internal_error_frame(error) ] ]
      end

      # Whether a request is for the MCP endpoint, trailing slash included.
      def mcp_request?(env)
        path = RailsAiContext.configuration.http_path
        env["PATH_INFO"] == path || env["PATH_INFO"] == "#{path}/"
      end

      # One MCP request, Rack-shaped: session scoping, dispatch and error
      # containment. Only a transport failure becomes an MCP error frame; the
      # middleware calls the app behind it outside this, so the app's own
      # exceptions stay the app's to handle.
      def serve(env, transport)
        request = Rack::Request.new(env)
        session = Tools::BaseTool.session_from(env)
        status, headers, body = Tools::BaseTool.with_session(session) { transport.handle_request(request) }
        [ status, headers, session_scoped(body, session) ]
      rescue => e
        internal_error_response(e)
      end

      # The SDK answers a request inside a session with a streaming body, and
      # the tool runs when the web server calls that body - after `serve` has
      # returned and the scope around handle_request is gone. Every client's
      # calls then landed in the one default record, so the scope travels
      # with the body.
      def session_scoped(body, session)
        return body unless body.respond_to?(:call) && !body.respond_to?(:each)

        ->(stream) { Tools::BaseTool.with_session(session) { body.call(stream) } }
      end

      # The middleware and the engine ride the app's own web server, which in
      # a deployed environment is the one the network reaches, and every tool
      # answers whoever asks. Serving there is the app's decision, so without
      # it the answer is a refusal that says how to make it. Deployed is any
      # environment but development and test: a staging app is reached the
      # way production is.
      def production_refusal
        config = RailsAiContext.configuration
        env = RailsAiContext.environment_name
        return nil if config.allow_http_in_production || LOCAL_ENVIRONMENTS.include?(env)

        log_production_refusal(env)
        [ 403, { "Content-Type" => "application/json" }, [ error_frame(INVALID_REQUEST, production_refusal_message(env)) ] ]
      end

      def production_refusal_message(env)
        "rails-ai-context does not serve MCP over HTTP in the #{env} environment, where every tool " \
          "would answer whoever can reach this app. To serve it here, put the endpoint behind your app's " \
          "authentication and set config.allow_http_in_production = true."
      end

      # Memoization is the caller's: the middleware holds one per instance
      # and the controller one per class. The standalone server builds its
      # own transport because start_http also needs the underlying server
      # for the banner and live reload.
      #
      # The middleware and the engine never start live reload; their tool
      # calls check the app's files themselves, as every server's do.
      def build_transport(app = nil)
        app ||= Rails.application
        transport = MCP::Server::Transports::StreamableHTTPTransport.new(Server.new(app, transport: :http).build)
        CodeReloader.track_loaded_code!
        Tools::BaseTool.check_files_per_call!(app)
        transport
      end

      private

      # Once per process: a client that keeps retrying would otherwise fill
      # the production log with the same line.
      def log_production_refusal(env)
        return if @production_refusal_logged

        @production_refusal_logged = true
        RailsAiContext.log_warn "[rails-ai-context] Refused an MCP request. #{production_refusal_message(env)}"
      end
    end

    # The environments the endpoint answers in without allow_http_in_production.
    LOCAL_ENVIRONMENTS = %w[development test].freeze
  end
end
