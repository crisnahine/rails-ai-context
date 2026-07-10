# frozen_string_literal: true

module E2E
  # Minimal MCP JSON-RPC 2.0 client over stdio. Spawns `rails-ai-context serve`
  # as a subprocess, sends Content-Length-framed JSON-RPC messages, and
  # parses responses. Used by mcp_stdio_spec.rb to verify the full
  # initialize → tools/list → tools/call handshake against a real server.
  class McpStdioClient
    class Error < StandardError; end

    def initialize(app_builder, timeout: 20)
      @app     = app_builder
      @timeout = timeout
      @id      = 0
    end

    def start!
      prefix = if @app.isolated_gem_home?
        [ File.join(@app.gem_home, "bin", "rails-ai-context") ]
      else
        [ "bundle", "exec", "rails-ai-context" ]
      end
      @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(
        @app.env, *prefix, "serve", chdir: @app.app_path
      )
      # Server may emit a line of banner text before the JSON-RPC stream.
      # we tolerate that because the MCP SDK also does (the first byte of
      # JSON starts the message). But if the process dies early, fail loud.
      sleep 0.25
      unless @wait_thr.alive?
        stderr_output = @stderr.read rescue ""
        raise Error, "server died on startup:\n#{stderr_output}"
      end
      self
    end

    def stop!
      return unless @wait_thr
      Process.kill("TERM", @wait_thr.pid) rescue nil
      begin
        Timeout.timeout(3) { @wait_thr.value }
      rescue Timeout::Error
        Process.kill("KILL", @wait_thr.pid) rescue nil
      end
      [ @stdin, @stdout, @stderr ].each { |io| io&.close rescue nil }
    end

    # Send a JSON-RPC request and return the parsed response hash.
    # Raises McpStdioClient::Error on protocol / framing errors or on timeout.
    def request(method, params = {})
      @id += 1
      payload = { jsonrpc: "2.0", id: @id, method: method, params: params }
      write_message(payload)
      read_message_matching(@id)
    end

    # Send a JSON-RPC notification (no id, no response expected).
    def notify(method, params = {})
      payload = { jsonrpc: "2.0", method: method, params: params }
      write_message(payload)
    end

    def initialize!
      request("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "e2e-harness", version: "0.0.0" }
      })
      notify("notifications/initialized")
    end

    def list_tools
      request("tools/list")
    end

    def call_tool(name, arguments = {})
      request("tools/call", { name: name, arguments: arguments })
    end

    # Drain whatever stderr output is currently buffered without blocking
    # for the full `timeout` once data starts arriving. The server writes
    # log lines synchronously while handling a request, so by the time its
    # stdout response has been read, any stderr line for that same request
    # is already flushed and ready to read - this just waits briefly for it.
    def read_stderr_available(timeout: 1.0, quiet_period: 0.05)
      buffer = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0

        wait = buffer.empty? ? remaining : quiet_period
        ready, = IO.select([ @stderr ], nil, nil, wait)
        break if ready.nil?

        chunk = @stderr.read_nonblock(65536)
        buffer << chunk
      rescue IO::WaitReadable
        next
      rescue EOFError
        break
      end
      buffer
    end

    private

    # The MCP stdio transport uses newline-delimited JSON (NDJSON) per the
    # official SDK - each message is one line of JSON, not LSP-style
    # Content-Length framing. Confirmed by reading the SDK's
    # StdioTransport#send_message / receive_message.
    def write_message(payload)
      line = JSON.generate(payload)
      @stdin.write(line + "\n")
      @stdin.flush
    rescue Errno::EPIPE => e
      raise Error, "server closed stdin: #{e.message}"
    end

    def read_message_matching(expected_id)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Error, "timeout waiting for response id=#{expected_id}" if remaining <= 0

        line = read_line_with_timeout(remaining)
        raise Error, "server closed stdout" if line.nil?
        next if line.strip.empty?

        begin
          msg = JSON.parse(line)
        rescue JSON::ParserError
          # Banner line or log output - skip.
          next
        end

        # Skip server-initiated notifications we didn't ask for
        next unless msg.is_a?(Hash) && msg["id"] == expected_id

        if msg["error"]
          raise Error, "JSON-RPC error for id=#{expected_id}: #{msg['error'].inspect}"
        end
        return msg
      end
    end

    def read_line_with_timeout(seconds)
      ready, = IO.select([ @stdout ], nil, nil, seconds)
      return nil if ready.nil?
      @stdout.gets
    end
  end
end
