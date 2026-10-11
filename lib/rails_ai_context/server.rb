# frozen_string_literal: true

require "mcp"
require "json"

module RailsAiContext
  # Configures and starts an MCP server using the official Ruby SDK.
  # Registers all introspection tools and handles transport selection.
  class Server
    attr_reader :app, :transport_type

    STOP_SIGNALS = %w[TERM INT].freeze

    LOOPBACK = %w[127.0.0.1 ::1 localhost].freeze

    # Seconds a stopping server gives requests still in flight. Puma's
    # default is to wait for them forever, so one request that never
    # finished - a tool stuck on a lock, a client that stopped reading - kept
    # a stopped server running until SIGKILL. Puma then gives the request a
    # further grace period of its own before it kills the thread, so a stop
    # ends within about eight seconds.
    SHUTDOWN_TIMEOUT = 3

    # Past this many seconds after a stop signal the process exits whatever
    # is still running: the stop above has long had its chance by then.
    STOP_DEADLINE = 15

    # All built-in tools, auto-discovered from Tools::BaseTool subclasses.
    # Kept as a class method (not a constant) so auto-registration works.
    # Legacy constant accessor preserved for backwards compatibility.
    def self.builtin_tools
      Tools::BaseTool.registered_tools
    end

    # Backwards-compatible constant - delegates to the registry.
    # Existing code referencing Server::TOOLS continues to work.
    # Emits a deprecation notice once to guide migration.
    def self.const_missing(name)
      if name == :TOOLS
        unless @tools_deprecation_warned
          @tools_deprecation_warned = true
          $stderr.puts "[rails-ai-context] DEPRECATION: Server::TOOLS is deprecated, use Server.builtin_tools instead" if ENV["DEBUG"]
        end
        return builtin_tools
      end
      super
    end

    def initialize(app, transport: :stdio)
      @app = app
      @transport_type = transport
    end

    # Resolve config.custom_tools into MCP::Tool classes. Entries may be
    # classes or class-name strings: classes in app/ (e.g. app/mcp_tools/)
    # are not autoloadable while config/initializers run, so referencing the
    # constant there aborts boot - a string name defers resolution to here,
    # where autoloading is ready. Invalid entries are warn-skipped so one bad
    # entry cannot take down every tool invocation.
    def self.resolve_custom_tools(config = RailsAiContext.configuration)
      config.custom_tools.filter_map do |entry|
        tool = entry
        if tool.is_a?(String)
          # NameError messages never carry a leading "::", so normalize it
          # away up front or a missing "::Foo::Bar" entry could never be
          # classified as class-not-found below.
          tool = tool.delete_prefix("::")
          begin
            tool = Object.const_get(tool)
          rescue NameError => e
            # "class not found" only when the missing constant IS the entry
            # (or a leading namespace of it); a NameError raised from inside
            # the tool file's class body about some other constant means the
            # class exists but is broken - say so. The full constant path in
            # the message disambiguates where a bare #name cannot (a body
            # error about `Elastic::Search` must not read as entry
            # "Tools::Search" being absent).
            missing = e.message[/\Auninitialized constant ([\w:]+)/, 1]
            entry_missing = missing && (tool == missing || tool.start_with?("#{missing}::"))
            if entry_missing
              $stderr.puts "[rails-ai-context] WARNING: Skipping custom_tool #{entry.inspect} (class not found)"
            else
              $stderr.puts "[rails-ai-context] WARNING: Skipping custom_tool #{entry.inspect} (#{e.class}: #{e.message.lines.first.to_s.strip})"
            end
            next nil
          rescue StandardError, ScriptError => e
            # A syntax error or raising class body in the autoloaded file must
            # cost that one entry, not the whole server/CLI.
            $stderr.puts "[rails-ai-context] WARNING: Skipping custom_tool #{entry.inspect} (#{e.class}: #{e.message.lines.first.to_s.strip})"
            next nil
          end
        end

        if tool.is_a?(Class) && tool < MCP::Tool
          tool
        else
          $stderr.puts "[rails-ai-context] WARNING: Skipping invalid custom_tool #{entry.inspect} (must be an MCP::Tool subclass or its class name)"
          nil
        end
      end
    end

    # The built-in tools skip_tools turned off.
    def self.skipped_tools(config = RailsAiContext.configuration)
      config.skip_tools & builtin_tools.map(&:tool_name)
    end

    # One answer, on every surface, for a call naming a tool skip_tools
    # turned off: it is out of every list, and "Unknown tool" sent the
    # reader looking for a tool the gem has.
    def self.skipped_tool_message(tool_name)
      "#{tool_name} is turned off in this app: skip_tools lists it " \
        "(.rails-ai-context.yml or config/initializers/rails_ai_context.rb). Take it out of skip_tools to use it."
    end

    # What tools/list answers with: the built-ins skip_tools leaves, then
    # each custom tool whose name no tool before it claims. The generated
    # context files count and list this set, so they name no tool the
    # server lacks and leave out none it serves.
    def self.exposed_tools(config = RailsAiContext.configuration)
      merge_tools(active_tools(config), resolve_custom_tools(config), warn: false)
    end

    def self.active_tools(config)
      tools = builtin_tools
      skip = config.skip_tools
      return tools if skip.empty?

      tools.reject { |t| skip.include?(t.tool_name) }
    end

    # The MCP SDK refuses a tool list with a repeated name, so one duplicate
    # takes the whole server down. Two ways they arise:
    #
    #   - The same class twice. Naming a BaseTool subclass in custom_tools
    #     resolves its constant, which autoloads the file, which fires
    #     `inherited` and enrols it in the registry active_tools reads.
    #   - Two different classes claiming one name. Deliberate replacement is
    #     spelled with skip_tools; without it, keep the built-in and say so.
    def self.merge_tools(builtin, custom, warn: true)
      merged = (builtin + custom).uniq
      builtin_names = builtin.to_set { |t| tool_label(t) }

      merged.group_by { |t| tool_label(t) }.flat_map do |name, tools|
        next tools if tools.size == 1

        # Only skip_tools can settle a clash with a built-in; when both
        # claimants are custom there is no built-in to skip, and saying so
        # would send the user after a setting that cannot help.
        advice = if builtin_names.include?(name)
          "keeping the built-in. Add #{name.inspect} to config.skip_tools to replace it."
        else
          "keeping the first. Give one of them a different tool_name."
        end
        $stderr.puts "[rails-ai-context] WARNING: #{tools.size} tools claim the name #{name.inspect}; #{advice}" if warn
        [ tools.first ]
      end
    end

    # MCP::Tool subclasses answer tool_name; anything else falls back to the
    # class name, which is what the SDK would key on anyway.
    def self.tool_label(tool)
      tool.respond_to?(:tool_name) ? tool.tool_name : tool.name
    end

    # The name the server gives the client: config.server_name, and when
    # that is the default, RAILS_AI_CONTEXT_SERVER_NAME in its place. A
    # workspace's entries set the variable so each server announces its app
    # first, since VS Code names every tool after this name and keeps 13
    # characters of it; a name the app configured itself still wins.
    def self.announced_name(config = RailsAiContext.configuration)
      name = ENV[McpConfigGenerator::SERVER_NAME_ENV].to_s.strip
      return config.server_name if name.empty? || config.server_name != McpConfigGenerator::SERVER_NAME

      name
    end

    # What the client is told about freshness. An app that cannot reload
    # keeps what reflection read at boot, and its answers say so once app
    # code changed (BaseTool.stale_code_note).
    def self.instructions
      intro = "Ground truth engine for Rails apps. Live Prism AST introspection."
      return "#{intro} Answers follow edits to the app's files." if CodeReloader.reloadable? || RailsAiContext.static_tier?

      "#{intro} Answers follow edits to the app's files, except what reflection reads, such as associations: " \
        "RAILS_ENV=#{RailsAiContext.environment_name} does not reload code, so that stays as of boot, and every " \
        "answer says when app code changed since."
    end

    # Anything that still escapes a tool (schema validation bugs, SDK-level
    # failures) is named on stderr instead of vanishing into a bare JSON-RPC
    # internal error, in one line; the backtrace is DEBUG's, as it is for a
    # boot failure. Routine protocol-level errors (unknown tool, invalid
    # params) are expected traffic, not bugs - the mcp gem already turns them
    # into a proper JSON-RPC error response, so here they get one quiet line.
    EXCEPTION_REPORTER = lambda { |exception, _server_context|
      if exception.is_a?(MCP::Server::RequestHandlerError) && exception.error_type != :internal_error
        $stderr.puts "[rails-ai-context] request error (#{exception.error_type}): #{exception.message}"
      elsif ENV["DEBUG"]
        $stderr.puts "[rails-ai-context] unhandled exception: #{exception.class}: #{exception.message}"
        Array(exception.backtrace).first(10).each { |line| $stderr.puts "    #{line}" }
      else
        $stderr.puts "[rails-ai-context] unhandled exception: #{exception.class}: " \
                     "#{exception.message.to_s.lines.first&.strip} (DEBUG=1 prints the backtrace)"
      end
    }

    # Build and return the configured MCP::Server instance
    def build
      config = RailsAiContext.configuration

      validated_custom_tools = self.class.resolve_custom_tools(config)

      mcp_config = MCP::Configuration.new(
        exception_reporter: EXCEPTION_REPORTER,
        instrumentation_callback: Instrumentation.callback
      )

      server = SdkServer.new(
        skipped_tools: self.class.skipped_tools(config),
        name: self.class.announced_name(config),
        version: config.server_version,
        instructions: self.class.instructions,
        tools: self.class.merge_tools(self.class.active_tools(config), validated_custom_tools),
        resource_templates: Resources.resource_templates,
        configuration: mcp_config
      )

      Resources.register(server)

      server
    end

    # Start the MCP server with the configured transport
    def start
      server = build
      report_transport_errors

      case transport_type
      when :stdio
        start_stdio(server)
      when :http, :streamable_http
        start_http(server)
      else
        raise ConfigurationError, "Unknown transport: #{transport_type}. Use :stdio or :http"
      end
    end

    private

    # The SDK's transports report through MCP.configuration's reporter, not
    # the server's, so a stdio frame past the size limit ended the server
    # with nothing on stderr. This process serves only this server, so the
    # process-wide reporter is this one too, unless the app set its own.
    def report_transport_errors
      configuration = MCP.configuration
      return unless configuration.respond_to?(:exception_reporter=)
      return if configuration.respond_to?(:exception_reporter?) && configuration.exception_reporter?

      configuration.exception_reporter = EXCEPTION_REPORTER
    end

    # Read the list off the server rather than rebuilding it. Recomputing it
    # from the registry drops any custom tool that is not a BaseTool, so the
    # banner announced a different set than the server answered with.
    def tool_banner(server)
      names = server.tools.values.map { |t| self.class.tool_label(t) }.sort
      "[rails-ai-context] Tools (#{names.size}): #{names.join(', ')}"
    end

    # The SDK's server, told which tools skip_tools turned off. They are out
    # of tools/list, but a client can still name one - a context file written
    # before the skip, a model's guess - and the SDK answered "Tool not
    # found", a protocol error most clients never show the model.
    class SdkServer < MCP::Server
      def initialize(skipped_tools: [], **options)
        @skipped_tools = skipped_tools
        super(**options)
      end

      private

      def call_tool(request, ...)
        name = request[:name]
        return super unless @skipped_tools.include?(name) && !tools.key?(name)

        MCP::Tool::Response.new([ { type: "text", text: Server.skipped_tool_message(name) } ], error: true).to_h
      end
    end

    # Writes to the saved channel, since the session points $stdout and fd 1
    # at stderr so nothing a tool prints reaches the JSON-RPC stream.
    class StdioChannelTransport < MCP::Server::Transports::StdioTransport
      # The frame past the SDK's size limit that ended the connection, if one did.
      attr_reader :frame_error

      # The SDK sets UTF-8 on $stdout, which is $stderr here; it goes on the channel instead.
      def initialize(server, channel)
        stderr_encoding = [ $stdout.external_encoding, $stdout.internal_encoding ]
        super(server)
        $stdout.set_encoding(*stderr_encoding)
        @channel = channel
        @channel.set_encoding("UTF-8")
      end

      def send_response(message)
        @channel.puts(message.is_a?(String) ? message : JSON.generate(message))
        @channel.flush
      end

      private

      # The SDK ends the connection when a frame passes its size limit (4 MiB)
      # without a newline, and the server exited 0 with the client's request
      # unanswered. The client gets a JSON-RPC error first, and the failure
      # is kept for start_stdio to end on.
      def read_line(io)
        super
      rescue MCP::Server::RequestHandlerError => e
        @frame_error = e
        send_response({ jsonrpc: "2.0", id: nil, error: { code: McpEdge::INVALID_REQUEST, message: "Invalid Request: #{e.message}" } })
        raise
      end
    end

    def start_stdio(server)
      OutputGuard.quarantine_stdout(across_exec: false) do |channel|
        transport = StdioChannelTransport.new(server, channel)
        $stderr.puts "[rails-ai-context] MCP server started (stdio transport)"
        $stderr.puts tool_banner(server)
        RailsAiContext.stdio_open = true
        maybe_start_live_reload(server)
        transport.open
        raise RailsAiContext::Error, "MCP stdio connection closed: #{transport.frame_error.message}" if transport.frame_error
      end
    ensure
      RailsAiContext.stdio_open = false
    end

    def start_http(server)
      config = RailsAiContext.configuration
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

      # Build a minimal Rack app that delegates to the MCP transport
      rack_app = build_rack_app(transport)

      $stderr.puts bind_warning(config.http_bind) unless LOOPBACK.include?(config.http_bind)
      $stderr.puts "[rails-ai-context] MCP server starting on #{config.http_bind}:#{config.http_port}#{config.http_path}"
      $stderr.puts tool_banner(server)
      maybe_start_live_reload(server)

      handler = default_rack_handler
      handler.run(rack_app, **rack_handler_options(handler, config)) do |launcher|
        stop_outside_signal_handler(launcher) if puma_handler?(handler)
      end
    rescue SignalException => e
      # Puma stops gracefully on SIGTERM and then raises it, so a stop that
      # had already finished reached rake as "bin/rails aborted!
      # SignalException: SIGTERM". A stop signal ends the server, quietly.
      raise unless STOP_SIGNALS.include?(Signal.signame(e.signo))
    ensure
      stop_http(transport)
    end

    # Puma runs a SIGTERM stop inside the signal handler: it writes to its
    # wake-up pipe there and then joins the server thread, which closes that
    # pipe on its way out. When the close catches the handler's write still
    # registered on the pipe, Ruby makes the closer wait for the writer to
    # let go, which needs a mutex code in a signal handler may not take, so
    # neither thread moved again: the server printed "Gracefully stopping"
    # and hung until SIGKILL, and a second signal did nothing because signal
    # handlers do not nest. Here a stop signal only queues the stop, and an
    # ordinary thread asks Puma for it - the non-blocking stop its own
    # SIGINT handler uses - then ends the process if the stop never does.
    def stop_outside_signal_handler(launcher)
      stops = Thread::Queue.new
      booted = Thread::Queue.new
      trap_stops = -> { STOP_SIGNALS.each { |name| Signal.trap(name) { stops << name } } }

      # Replaced where Puma installs its own handlers, which is before it
      # binds the port, so no signal reaches Puma's. setup_signals is private
      # but has kept its name since Puma 2; without it, the handlers are
      # replaced once Puma has booted.
      replaced = launcher.respond_to?(:setup_signals, true)
      if replaced
        launcher.singleton_class.prepend(Module.new do
          define_method(:setup_signals) do
            super()
            trap_stops.call
          end
          private :setup_signals
        end)
      end

      events = launcher.events
      # Puma 7 renamed on_booted; the old name still works there, with a warning.
      events.public_send(events.respond_to?(:after_booted) ? :after_booted : :on_booted) do
        trap_stops.call unless replaced
        booted << true
      end

      Thread.new do
        stops.pop
        # Puma can stop only a server it has started: the port is bound before
        # the server exists, and a stop asked for in between was dropped.
        booted.pop
        launcher.stop
        sleep STOP_DEADLINE
        $stderr.puts "[rails-ai-context] Server did not stop within #{STOP_DEADLINE}s of the signal; exiting."
        exit!(1)
      end
    end

    # What a non-loopback bind does depends on the SDK. One with DNS rebinding
    # protection answers only a loopback Host header, so a client that
    # addresses the machine by IP or name is refused with 403 "Invalid Host
    # header" - while one that sends `Host: localhost` itself gets every tool.
    # The old warning said the bind served the network, which was true of
    # neither kind of client. An SDK without the check does serve everyone.
    def bind_warning(bind)
      prefix = "[rails-ai-context] WARNING: MCP HTTP transport binding to #{bind} opens its port to the network, with no authentication."
      unless host_checked?
        return "#{prefix} Every tool answers whoever reaches it. Use 127.0.0.1 (default) unless you have external auth in place."
      end

      "#{prefix} The MCP SDK answers only requests whose Host header is 127.0.0.1, ::1 or localhost, so a client that " \
        "addresses this machine by IP or name gets 403 \"Invalid Host header\", while one that sends Host: localhost gets " \
        "every tool. Bind it so for a container whose port is published to the host, where the client still connects to " \
        "localhost; otherwise keep 127.0.0.1 (default)."
    end

    def host_checked?
      MCP::Server::Transports::StreamableHTTPTransport.instance_method(:initialize).parameters.any? { |_, name| name == :allowed_hosts }
    end

    # Closes every session's stream so a connected client sees the server go,
    # and stops the file watcher, rather than leaving both to process exit.
    def stop_http(transport)
      @live_reload&.stop
      transport&.close
    rescue StandardError => e
      RailsAiContext.debug_fail(e, nil, label: "stop_http")
    end

    def default_rack_handler
      require "rackup"
      Rackup::Handler.default
    rescue LoadError
      # Fallback for older rack without rackup gem
      require "rack/handler"
      Rack::Handler.default
    end

    # MCP sessions live in this process's memory, so a forked worker cannot
    # answer a request whose `initialize` another worker handled - about half
    # of them come back "Session not found". Puma's handler otherwise reads the
    # host app's config/puma.rb, which on a real app sets `workers` (and a
    # pidfile this server would then write over). Both options are load-bearing:
    # refusing the file still leaves WEB_CONCURRENCY able to start a cluster on
    # its own, and pinning the worker count still lets the file's pidfile and
    # preload_app! through. The third bounds a stop; see SHUTDOWN_TIMEOUT.
    def rack_handler_options(handler, config)
      options = { Host: config.http_bind, Port: config.http_port }
      return options unless puma_handler?(handler)

      $stderr.puts "[rails-ai-context] Puma pinned to single mode - MCP sessions are per-process, " \
                   "so config/puma.rb and WEB_CONCURRENCY are not read."
      options.merge(workers: 0, config_files: [ "-" ], force_shutdown_after: SHUTDOWN_TIMEOUT)
    end

    # The handler is whatever Rackup picked, and only Puma understands these
    # keys. Puma::RackHandler is the module both Rackup::Handler::Puma and the
    # older Rack::Handler::Puma extend, so this recognizes either.
    def puma_handler?(handler)
      defined?(::Puma::RackHandler) && handler.singleton_class.include?(::Puma::RackHandler)
    end

    # Conditionally start live reload based on configuration.
    # :auto  - try to load `listen`, print a tip to stderr if missing
    # true   - try to load `listen`, raise if missing
    # false  - skip entirely
    #
    # Either way each tool call checks the app's files itself
    # (BaseTool.refresh_if_files_changed!), so answers follow edits made
    # before the call; the watch adds telling clients that files changed.
    def maybe_start_live_reload(mcp_server)
      mode = RailsAiContext.configuration.live_reload
      CodeReloader.track_loaded_code!
      Tools::BaseTool.check_files_per_call!(app)
      return if mode == false

      begin
        live_reload = LiveReload.new(app, mcp_server)
        @live_reload = live_reload if live_reload.start
      rescue LoadError
        # A standalone install reaches an installed listen; the app's Gemfile
        # is the place only when the gem itself is in it.
        remedy = InstallMode.standalone? ? "Install it: gem install listen" : "Add to your Gemfile: gem 'listen', group: :development"
        raise LoadError, "Live reload requires the `listen` gem. #{remedy}" if mode == true

        # :auto mode - skip with a tip. Answers still follow edits: each tool
        # call checks the app's files.
        $stderr.puts "[rails-ai-context] Live reload off: no `listen` gem, so clients are not told when files change. #{remedy}"
      end
    end

    def build_rack_app(transport)
      lambda do |env|
        if McpEdge.mcp_request?(env)
          McpEdge.serve(env, transport)
        else
          [ 404, { "Content-Type" => "application/json" }, [ '{"error":"Not found"}' ] ]
        end
      end
    end
  end
end
