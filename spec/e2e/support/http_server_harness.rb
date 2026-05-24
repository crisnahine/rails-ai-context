# frozen_string_literal: true

module E2E
  # Boots a real Rails server (via `bin/rails server`) in the test app on a
  # free local port and tears it down cleanly. Used by mcp_http_spec.rb to
  # verify the HTTP transport end-to-end with actual Net::HTTP requests.
  class HttpServerHarness
    attr_reader :port

    def initialize(app_builder, timeout: 45)
      @app = app_builder
      @timeout = timeout
    end

    def start!
      @port = find_free_port
      # Use `rails-ai-context serve --transport http` rather than `rails server`
      # because auto_mount defaults to false - the Rack middleware isn't
      # inserted into the Rails app's stack unless explicitly configured.
      # The CLI HTTP mode starts a standalone MCP HTTP server with the gem's
      # own transport, which is what users of the HTTP transport actually
      # invoke.
      prefix = if @app.isolated_gem_home?
        [ File.join(@app.gem_home, "bin", "rails-ai-context") ]
      else
        [ "bundle", "exec", "rails-ai-context" ]
      end
      cmd = prefix + [ "serve", "--transport", "http", "--port", @port.to_s ]
      @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(@app.env, *cmd, chdir: @app.app_path)
      wait_for_ready!
      self
    end

    def stop!
      return unless @wait_thr
      Process.kill("TERM", @wait_thr.pid) rescue nil
      begin
        Timeout.timeout(5) { @wait_thr.value }
      rescue Timeout::Error
        Process.kill("KILL", @wait_thr.pid) rescue nil
      end
      [ @stdin, @stdout, @stderr ].each { |io| io&.close rescue nil }
    end

    # POST a JSON-RPC payload to /mcp and return the parsed response hash.
    # The MCP Streamable HTTP transport requires BOTH `application/json` AND
    # `text/event-stream` in the Accept header - the server may respond with
    # either a single JSON object or an SSE stream. We request both, then
    # switch on Content-Type below.
    #
    # The transport is also stateful by default: the `initialize` response
    # carries an `Mcp-Session-Id` header that MUST be echoed back on every
    # subsequent request, otherwise the server returns HTTP 400 "Missing
    # session ID". We capture the id automatically on initialize.
    def jsonrpc(method, params = {}, id: SecureRandom.uuid)
      uri = URI("http://127.0.0.1:#{@port}/mcp")
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req["Accept"] = "application/json, text/event-stream"
      req["Mcp-Session-Id"] = @session_id if @session_id
      req.body = JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params)

      res = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 15) do |http|
        http.request(req)
      end

      # Capture the session id from initialize so subsequent requests carry it.
      @session_id ||= res["Mcp-Session-Id"] if method == "initialize"

      raise "HTTP #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
      parse_response(res)
    end

    private

    # Handle both plain JSON and SSE responses per the Streamable HTTP spec.
    def parse_response(res)
      content_type = res["Content-Type"].to_s
      if content_type.start_with?("application/json")
        JSON.parse(res.body)
      elsif content_type.start_with?("text/event-stream")
        # Parse the first `data:` line from the SSE stream.
        data_line = res.body.lines.find { |l| l.start_with?("data:") }
        raise "SSE response missing data line:\n#{res.body}" unless data_line
        JSON.parse(data_line.sub(/\Adata:\s*/, ""))
      else
        raise "unexpected Content-Type: #{content_type.inspect}\nbody: #{res.body}"
      end
    end

    public

    private

    def find_free_port
      s = TCPServer.new("127.0.0.1", 0)
      port = s.addr[1]
      s.close
      port
    end

    def wait_for_ready!
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
      loop do
        raise "server not ready after #{@timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        begin
          TCPSocket.new("127.0.0.1", @port).close
          return
        rescue Errno::ECONNREFUSED
          raise "server died on startup:\n#{@stderr.read rescue ''}" unless @wait_thr.alive?
          sleep 0.3
        end
      end
    end
  end
end
