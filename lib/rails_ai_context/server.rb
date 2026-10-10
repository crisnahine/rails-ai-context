# frozen_string_literal: true

require "mcp"
require "json"

module RailsAiContext
  # Configures and starts an MCP server using the official Ruby SDK.
  # Registers all introspection tools and handles transport selection.
  class Server
    attr_reader :app, :transport_type

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

    # Build and return the configured MCP::Server instance
    def build
      config = RailsAiContext.configuration

      validated_custom_tools = self.class.resolve_custom_tools(config)

      mcp_config = MCP::Configuration.new(
        # Anything that still escapes a tool (schema validation bugs, SDK-level
        # failures) is named on stderr instead of vanishing into a bare
        # JSON-RPC internal error, in one line; the backtrace is DEBUG's, as
        # it is for a boot failure. Routine protocol-level errors (unknown
        # tool, invalid params) are expected traffic, not bugs - the mcp gem
        # already turns them into a proper JSON-RPC error response, so here
        # they get one quiet line.
        exception_reporter: lambda { |exception, _server_context|
          if exception.is_a?(MCP::Server::RequestHandlerError) && exception.error_type != :internal_error
            $stderr.puts "[rails-ai-context] request error (#{exception.error_type}): #{exception.message}"
          elsif ENV["DEBUG"]
            $stderr.puts "[rails-ai-context] unhandled exception: #{exception.class}: #{exception.message}"
            Array(exception.backtrace).first(10).each { |line| $stderr.puts "    #{line}" }
          else
            $stderr.puts "[rails-ai-context] unhandled exception: #{exception.class}: " \
                         "#{exception.message.to_s.lines.first&.strip} (DEBUG=1 prints the backtrace)"
          end
        },
        instrumentation_callback: Instrumentation.callback
      )

      server = SdkServer.new(
        skipped_tools: self.class.skipped_tools(config),
        name: self.class.announced_name(config),
        version: config.server_version,
        instructions: "Ground truth engine for Rails apps. Live Prism AST introspection. Answers follow edits to the app's files.",
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
    end

    def start_stdio(server)
      OutputGuard.quarantine_stdout(across_exec: false) do |channel|
        transport = StdioChannelTransport.new(server, channel)
        $stderr.puts "[rails-ai-context] MCP server started (stdio transport)"
        $stderr.puts tool_banner(server)
        RailsAiContext.stdio_open = true
        maybe_start_live_reload(server)
        transport.open
      end
    ensure
      RailsAiContext.stdio_open = false
    end

    def start_http(server)
      config = RailsAiContext.configuration
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

      # Build a minimal Rack app that delegates to the MCP transport
      rack_app = build_rack_app(transport)

      loopback = %w[127.0.0.1 ::1 localhost].freeze
      unless loopback.include?(config.http_bind)
        $stderr.puts "[rails-ai-context] WARNING: MCP HTTP transport binding to #{config.http_bind} - " \
                     "this exposes all tools to the network without authentication. " \
                     "Use 127.0.0.1 (default) unless you have external auth in place."
      end
      $stderr.puts "[rails-ai-context] MCP server starting on #{config.http_bind}:#{config.http_port}#{config.http_path}"
      $stderr.puts tool_banner(server)
      maybe_start_live_reload(server)

      handler = default_rack_handler
      handler.run(rack_app, **rack_handler_options(handler, config))
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
    # preload_app! through.
    def rack_handler_options(handler, config)
      options = { Host: config.http_bind, Port: config.http_port }
      return options unless puma_handler?(handler)

      $stderr.puts "[rails-ai-context] Puma pinned to single mode - MCP sessions are per-process, " \
                   "so config/puma.rb and WEB_CONCURRENCY are not read."
      options.merge(workers: 0, config_files: [ "-" ])
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
    # Without a watch, each tool call checks the app's files itself
    # (BaseTool.refresh_if_files_changed!), so answers still follow edits.
    def maybe_start_live_reload(mcp_server)
      mode = RailsAiContext.configuration.live_reload

      return Tools::BaseTool.check_files_per_call!(app) if mode == false

      begin
        live_reload = LiveReload.new(app, mcp_server)
        @live_reload = live_reload if live_reload.start
      rescue LoadError
        if mode == true
          raise LoadError, "Live reload requires the `listen` gem. Add to your Gemfile: gem 'listen', group: :development"
        end

        # :auto mode - skip with a tip
        $stderr.puts "[rails-ai-context] Live reload unavailable (add `listen` gem for auto-refresh)"
      end
      Tools::BaseTool.check_files_per_call!(app) unless @live_reload
    end

    def build_rack_app(transport)
      lambda do |env|
        McpEdge.rack_call(env, transport: transport) do
          [ 404, { "Content-Type" => "application/json" }, [ '{"error":"Not found"}' ] ]
        end
      end
    end
  end
end
