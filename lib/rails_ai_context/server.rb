# frozen_string_literal: true

require "mcp"

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

    # Backwards-compatible constant — delegates to the registry.
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

    # Build and return the configured MCP::Server instance
    def build
      config = RailsAiContext.configuration

      validated_custom_tools = config.custom_tools.select do |tool|
        if tool.is_a?(Class) && tool < MCP::Tool
          true
        else
          $stderr.puts "[rails-ai-context] WARNING: Skipping invalid custom_tool #{tool.inspect} (must be an MCP::Tool subclass)"
          false
        end
      end

      mcp_config = MCP::Configuration.new(
        instrumentation_callback: Instrumentation.callback
      )

      server = MCP::Server.new(
        name: config.server_name,
        version: config.server_version,
        instructions: "Ground truth engine for Rails apps. Live Prism AST introspection. Zero stale data.",
        tools: active_tools(config) + validated_custom_tools,
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

    def active_tools(config)
      tools = self.class.builtin_tools
      skip = config.skip_tools
      return tools if skip.empty?

      tools.reject { |t| skip.include?(t.tool_name) }
    end

    def start_stdio(server)
      transport = MCP::Server::Transports::StdioTransport.new(server)
      tools = active_tools(RailsAiContext.configuration)
      # Log to stderr so we don't pollute the JSON-RPC channel on stdout
      $stderr.puts "[rails-ai-context] MCP server started (stdio transport)"
      $stderr.puts "[rails-ai-context] Tools (#{tools.size}): #{tools.map { |t| t.tool_name }.join(', ')}"
      maybe_start_live_reload(server)
      transport.open
    end

    def start_http(server)
      config = RailsAiContext.configuration
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

      # Build a minimal Rack app that delegates to the MCP transport
      rack_app = build_rack_app(transport, config.http_path)

      loopback = %w[127.0.0.1 ::1 localhost].freeze
      unless loopback.include?(config.http_bind)
        $stderr.puts "[rails-ai-context] WARNING: MCP HTTP transport binding to #{config.http_bind} — " \
                     "this exposes all tools to the network without authentication. " \
                     "Use 127.0.0.1 (default) unless you have external auth in place."
      end
      tools = active_tools(config)
      $stderr.puts "[rails-ai-context] MCP server starting on #{config.http_bind}:#{config.http_port}#{config.http_path}"
      $stderr.puts "[rails-ai-context] Tools (#{tools.size}): #{tools.map { |t| t.tool_name }.join(', ')}"
      maybe_start_live_reload(server)

      begin
        require "rackup"
        Rackup::Handler.default.run(rack_app, Host: config.http_bind, Port: config.http_port)
      rescue LoadError
        # Fallback for older rack without rackup gem
        require "rack/handler"
        Rack::Handler.default.run(rack_app, Host: config.http_bind, Port: config.http_port)
      end
    end

    # Conditionally start live reload based on configuration.
    # :auto  — try to load `listen`, skip silently with a tip if missing
    # true   — try to load `listen`, raise if missing
    # false  — skip entirely
    def maybe_start_live_reload(mcp_server)
      mode = RailsAiContext.configuration.live_reload

      return if mode == false

      begin
        live_reload = LiveReload.new(app, mcp_server)
        live_reload.start
        @live_reload = live_reload
      rescue LoadError
        if mode == true
          raise LoadError, "Live reload requires the `listen` gem. Add to your Gemfile: gem 'listen', group: :development"
        end

        # :auto mode — skip silently with a tip
        $stderr.puts "[rails-ai-context] Live reload unavailable (add `listen` gem for auto-refresh)"
      end
    end

    def build_rack_app(transport, path)
      lambda do |env|
        # Only handle requests at the configured MCP path
        unless env["PATH_INFO"] == path || env["PATH_INFO"] == "#{path}/"
          return [ 404, { "Content-Type" => "application/json" }, [ '{"error":"Not found"}' ] ]
        end

        request = Rack::Request.new(env)
        transport.handle_request(request)
      end
    end
  end
end
