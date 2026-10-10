# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Server do
  let(:app) { Rails.application }
  let(:server) { described_class.new(app, transport: :stdio) }

  describe "#initialize" do
    it "stores the app reference" do
      expect(server.app).to eq(app)
    end

    it "stores the transport type" do
      expect(server.transport_type).to eq(:stdio)
    end

    it "defaults to stdio transport" do
      s = described_class.new(app)
      expect(s.transport_type).to eq(:stdio)
    end

    it "accepts http transport" do
      s = described_class.new(app, transport: :http)
      expect(s.transport_type).to eq(:http)
    end
  end

  describe ".builtin_tools" do
    it "returns an array of tool classes" do
      expect(described_class.builtin_tools).to be_an(Array)
      expect(described_class.builtin_tools).not_to be_empty
    end

    it "contains only MCP::Tool subclasses" do
      described_class.builtin_tools.each do |tool|
        expect(tool).to be < MCP::Tool
      end
    end

    it "includes core tools like GetSchema and GetRoutes" do
      expect(described_class.builtin_tools).to include(RailsAiContext::Tools::GetSchema)
      expect(described_class.builtin_tools).to include(RailsAiContext::Tools::GetRoutes)
    end
  end

  describe ".announced_name" do
    it "is config.server_name by default" do
      expect(described_class.announced_name).to eq(RailsAiContext.configuration.server_name)
    end

    # A workspace's entries name each server after its app this way, and an
    # app pinned to an older gem ignores the variable instead of failing.
    it "is RAILS_AI_CONTEXT_SERVER_NAME when the process sets it" do
      stub_const("ENV", ENV.to_h.merge("RAILS_AI_CONTEXT_SERVER_NAME" => "shop-rails-ai-context"))

      expect(described_class.announced_name).to eq("shop-rails-ai-context")
      expect(server.build.name).to eq("shop-rails-ai-context")
    end

    it "leaves a name the app configured itself" do
      stub_const("ENV", ENV.to_h.merge("RAILS_AI_CONTEXT_SERVER_NAME" => "shop-rails-ai-context"))
      allow(RailsAiContext.configuration).to receive(:server_name).and_return("billing-ctx")

      expect(described_class.announced_name).to eq("billing-ctx")
    end

    it "ignores a blank RAILS_AI_CONTEXT_SERVER_NAME" do
      stub_const("ENV", ENV.to_h.merge("RAILS_AI_CONTEXT_SERVER_NAME" => " "))

      expect(described_class.announced_name).to eq(RailsAiContext.configuration.server_name)
    end
  end

  describe "#build" do
    it "returns an MCP::Server instance" do
      mcp_server = server.build
      expect(mcp_server).to be_a(MCP::Server)
    end

    it "passes instrumentation callback in configuration" do
      mcp_server = server.build
      expect(mcp_server.configuration.instrumentation_callback).to be_a(Proc)
    end

    it "sets instructions on the server" do
      mcp_server = server.build
      expect(mcp_server.instructions).to include("Ground truth engine")
    end

    describe "exception_reporter" do
      let(:reporter) { server.build.configuration.exception_reporter }

      it "logs routine request errors (e.g. unknown tool) as a single quiet line" do
        error = MCP::Server::RequestHandlerError.new(
          "Tool not found: bogus", {}, error_type: :invalid_params
        )
        expect($stderr).to receive(:puts).once.with(
          "[rails-ai-context] request error (invalid_params): Tool not found: bogus"
        )
        reporter.call(error, {})
      end

      it "logs genuine internal errors with the full backtrace" do
        error = begin
          raise "boom"
        rescue => e
          e
        end
        expect($stderr).to receive(:puts).with(/unhandled exception: RuntimeError: boom/)
        expect($stderr).to receive(:puts).at_least(:once)
        reporter.call(error, {})
      end

      it "logs a RequestHandlerError whose error_type is :internal_error with the full backtrace" do
        error = begin
          raise MCP::Server::RequestHandlerError.new(
            "Internal error handling tools/call request", {}, error_type: :internal_error
          )
        rescue => e
          e
        end
        expect($stderr).to receive(:puts).with(/unhandled exception: MCP::Server::RequestHandlerError/)
        expect($stderr).to receive(:puts).with(/^    /).at_least(:once)
        reporter.call(error, {})
      end
    end

    it "registers 5 resource templates" do
      mcp_server = server.build
      templates = mcp_server.instance_variable_get(:@resource_templates)
      expect(templates.size).to eq(5)
    end

    it "uses configured server name" do
      RailsAiContext.configuration.server_name = "test-server"
      mcp_server = server.build
      expect(mcp_server.name).to eq("test-server")
    ensure
      RailsAiContext.configuration.server_name = "rails-ai-context"
    end

    context "with custom_tools" do
      let(:valid_tool) do
        Class.new(MCP::Tool) do
          tool_name "custom_valid_tool"
          description "A valid custom tool"
          def call
            MCP::Tool::Response.new([ { type: "text", text: "ok" } ])
          end
        end
      end

      it "includes valid custom tools" do
        RailsAiContext.configuration.custom_tools = [ valid_tool ]
        mcp_server = server.build
        expect(mcp_server.tools.values).to include(valid_tool)
      ensure
        RailsAiContext.configuration.custom_tools = []
      end

      it "rejects invalid custom tools with a warning" do
        RailsAiContext.configuration.custom_tools = [ "not_a_tool", 42, String ]
        expect($stderr).to receive(:puts).exactly(3).times
        server.build
      ensure
        RailsAiContext.configuration.custom_tools = []
      end

      # A BaseTool subclass enters the `inherited` registry that active_tools
      # reads, so naming one in custom_tools offered it to MCP::Server twice
      # and the SDK rejected the duplicate name - taking the whole server down
      # for any app that configured a custom tool.
      context "when the custom tool is a BaseTool subclass" do
        let(:registered_tool) do
          Class.new(RailsAiContext::Tools::BaseTool) do
            tool_name "rails_custom_registered_probe"
            description "A custom tool that also lives in the registry"

            def self.call(server_context: nil, **_params)
              text_response("ok")
            end
          end
        end

        after { registered_tool.abstract! }

        it "offers it to the MCP server exactly once" do
          RailsAiContext.configuration.custom_tools = [ registered_tool ]
          mcp_server = server.build
          matching = mcp_server.tools.values.select { |t| t.tool_name == "rails_custom_registered_probe" }
          expect(matching.size).to eq(1)
        ensure
          RailsAiContext.configuration.custom_tools = []
        end

        it "builds without raising on the duplicate name" do
          RailsAiContext.configuration.custom_tools = [ registered_tool ]
          expect { server.build }.not_to raise_error
        ensure
          RailsAiContext.configuration.custom_tools = []
        end
      end
    end

    context "with skip_tools" do
      it "excludes tools matching skip_tools names" do
        schema_tool_name = RailsAiContext::Tools::GetSchema.tool_name
        RailsAiContext.configuration.skip_tools = [ schema_tool_name ]
        mcp_server = server.build
        expect(mcp_server.tools.values).not_to include(RailsAiContext::Tools::GetSchema)
      ensure
        RailsAiContext.configuration.skip_tools = []
      end

      it "excludes tools named with symbols" do
        RailsAiContext.configuration.skip_tools = [ RailsAiContext::Tools::GetSchema.tool_name.to_sym ]
        mcp_server = server.build
        expect(mcp_server.tools.values).not_to include(RailsAiContext::Tools::GetSchema)
      ensure
        RailsAiContext.configuration.skip_tools = []
      end

      it "includes all tools when skip_tools is empty" do
        RailsAiContext.configuration.skip_tools = []
        mcp_server = server.build
        described_class.builtin_tools.each do |tool|
          expect(mcp_server.tools.values).to include(tool)
        end
      end

      # The SDK answered "Tool not found", a protocol error most clients
      # never show the model, for a tool the gem has and the app turned off.
      it "answers a call naming a skipped tool with why it is off, as a tool error" do
        RailsAiContext.configuration.skip_tools = [ "rails_get_schema" ]
        response = server.build.handle(
          { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rails_get_schema", arguments: {} } }
        )

        expect(response[:result][:isError]).to be true
        expect(response[:result][:content].first[:text]).to start_with("rails_get_schema is turned off in this app: skip_tools lists it")
      ensure
        RailsAiContext.configuration.skip_tools = []
      end

      it "still answers a name no tool has as the SDK does" do
        response = server.build.handle(
          { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rails_no_such_tool", arguments: {} } }
        )

        expect(response[:error][:message]).to match(/not found|Invalid params/i)
      end
    end
  end

  describe "#start" do
    it "raises ConfigurationError for unknown transport" do
      s = described_class.new(app, transport: :unknown)
      expect { s.start }.to raise_error(RailsAiContext::ConfigurationError, /Unknown transport/)
    end
  end

  # MCP sessions live in the transport's own memory, so a forked Puma worker
  # cannot answer a request whose `initialize` a sibling handled. Rackup hands
  # Puma the host app's config/puma.rb unless told not to, and a real app sets
  # `workers` there - which turned roughly half of all requests on a valid
  # session into "Session not found".
  describe "single-mode HTTP transport" do
    let(:s) { described_class.new(app, transport: :http) }
    let(:config) { RailsAiContext.configuration }

    def options_for(handler)
      s.send(:rack_handler_options, handler, config)
    end

    # Resolved the way start_http does, not through `require "rackup"`: Rails
    # 7.0 caps rack below 3, where rackup is not a separate gem and that
    # require raises. The production path already falls back to Rack::Handler,
    # and puma registers itself with whichever of the two is present.
    def resolved_handler
      s.send(:default_rack_handler)
    end

    before { allow($stderr).to receive(:puts) }

    it "resolves Puma as the handler" do
      expect(s.send(:puma_handler?, resolved_handler)).to be true
    end

    it "pins Puma to one process" do
      expect(options_for(resolved_handler))
        .to eq(Host: config.http_bind, Port: config.http_port, workers: 0, config_files: [ "-" ])
    end

    # A stand-in rather than a real second handler: webrick and falcon are not
    # in this bundle, and what is under test is only "not Puma".
    it "leaves a non-Puma handler's options alone" do
      expect(options_for(Module.new)).to eq(Host: config.http_bind, Port: config.http_port)
    end

    it "says that it dropped the app's puma config" do
      options_for(resolved_handler)
      expect($stderr).to have_received(:puts).with(/single mode/)
    end

    it "passes the options to the handler it resolved" do
      handler = double("handler")
      allow(s).to receive_messages(default_rack_handler: handler, build: instance_double(MCP::Server))
      allow(s).to receive(:rack_handler_options).and_return(Port: 6041)
      allow(MCP::Server::Transports::StreamableHTTPTransport).to receive(:new)
      allow(s).to receive(:maybe_start_live_reload)
      allow(s).to receive(:tool_banner).and_return("")
      allow(handler).to receive(:run)

      s.send(:start_http, instance_double(MCP::Server))
      expect(handler).to have_received(:run).with(anything, Port: 6041)
    end

    # The two options close two independent routes to a cluster, and Puma's own
    # resolution is the only thing that can show it: refusing the config file
    # still leaves WEB_CONCURRENCY, and pinning `workers` still lets the file's
    # pidfile and preload_app! through.
    describe "against Puma's own config resolution" do
      def resolved(options, env: {})
        require "puma/configuration"
        original = ENV.to_h
        env.each { |k, v| ENV[k] = v }
        conf = ::Puma::Configuration.new(options.dup, {})
        conf.clamp
        conf.options
      ensure
        ENV.replace(original)
      end

      around do |example|
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config", "puma.rb"), <<~RUBY)
            workers ENV.fetch("WEB_CONCURRENCY") { 2 }.to_i
            preload_app!
            pidfile "tmp/pids/server.pid"
          RUBY
          Dir.chdir(dir) { example.run }
        end
      end

      it "would run a cluster on the app's config without the pin" do
        expect(resolved({ Host: "127.0.0.1", Port: 6041 })[:workers]).to eq(2)
      end

      it "runs one process despite the app's config" do
        expect(resolved(options_for(resolved_handler))[:workers]).to eq(0)
      end

      it "runs one process despite WEB_CONCURRENCY" do
        options = options_for(resolved_handler)
        expect(resolved(options, env: { "WEB_CONCURRENCY" => "4" })[:workers]).to eq(0)
      end

      it "does not take over the app's pidfile" do
        expect(resolved(options_for(resolved_handler))[:pidfile]).to be_nil
      end
    end
  end

  describe "#build_rack_app" do
    let(:s) { described_class.new(app, transport: :http) }
    let(:mcp_path) { RailsAiContext.configuration.http_path }

    def call_rack_app(transport, path_info)
      rack_app = s.send(:build_rack_app, transport)
      rack_app.call(
        "PATH_INFO" => path_info,
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new("")
      )
    end

    it "404s requests outside the MCP path" do
      transport = instance_double("Transport")
      status, _headers, body = call_rack_app(transport, "/other")
      expect(status).to eq(404)
      expect(body.join).to include("Not found")
    end

    it "delegates MCP-path requests to the transport" do
      transport = instance_double("Transport")
      allow(transport).to receive(:handle_request).and_return([ 200, { "Content-Type" => "application/json" }, [ "{}" ] ])

      status, _headers, _body = call_rack_app(transport, mcp_path)
      expect(status).to eq(200)
      expect(transport).to have_received(:handle_request)
    end

    context "when the transport raises" do
      let(:transport) { instance_double("Transport") }

      before do
        allow(transport).to receive(:handle_request).and_raise(RuntimeError, "transport exploded")
        allow(RailsAiContext).to receive(:log_warn)
      end

      # The frame's contents are McpEdge's, pinned once in mcp_edge_spec.
      # What this app owes is answering in that shape rather than letting the
      # exception kill the request at the rackup level.
      it "answers with the shared error frame instead of raising" do
        status, headers, body = call_rack_app(transport, mcp_path)

        # Compared against the frame builder rather than the response builder:
        # the latter logs, and an expected value should not do work.
        expect([ status, headers, body.join ]).to eq([
          500,
          { "Content-Type" => "application/json" },
          RailsAiContext::McpEdge.internal_error_frame(RuntimeError.new("transport exploded"))
        ])
      end

      it "logs the failure" do
        call_rack_app(transport, mcp_path)
        expect(RailsAiContext).to have_received(:log_warn).with(a_string_matching("transport exploded"))
      end
    end
  end
  # The banner rebuilt the list from the BaseTool registry, so a custom tool
  # that is a plain MCP::Tool never appeared in it - the server announced one
  # set on stderr and answered with another.
  describe "#tool_banner" do
    let(:plain_custom_tool) do
      Class.new(MCP::Tool) do
        tool_name "custom_banner_probe"
        description "A custom tool outside the BaseTool registry"
      end
    end

    it "counts every tool the server actually serves" do
      RailsAiContext.configuration.custom_tools = [ plain_custom_tool ]
      mcp_server = server.build
      banner = server.send(:tool_banner, mcp_server)

      expect(banner).to include("custom_banner_probe")
      expect(banner).to include("Tools (#{mcp_server.tools.size})")
    ensure
      RailsAiContext.configuration.custom_tools = []
    end
  end

  # The stdio transport writes JSON-RPC to the real stdout, and an app logger pointed
  # at STDOUT would put the gem's own warnings in that stream.
  describe "warnings while the stdio transport is open" do
    it "go to stderr, not the app logger" do
      logger = instance_double(Logger, warn: nil)
      allow(Rails).to receive(:logger).and_return(logger)
      allow(described_class::StdioChannelTransport).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap do |transport|
          allow(transport).to receive(:open) { RailsAiContext.log_warn("[rails-ai-context] section failed") }
        end
      end
      allow(server).to receive(:maybe_start_live_reload)

      expect { server.send(:start_stdio, server.build) }
        .to output(/section failed/).to_stderr
      expect(logger).not_to have_received(:warn)
    end

    # The live-reload thread starts before the transport does, and a warning
    # from that window is still the gem's own.
    it "go to stderr from the live-reload start too" do
      logger = instance_double(Logger, warn: nil)
      allow(Rails).to receive(:logger).and_return(logger)
      allow(described_class::StdioChannelTransport).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap { |transport| allow(transport).to receive(:open) }
      end
      allow(server).to receive(:maybe_start_live_reload) do
        RailsAiContext.log_warn("[rails-ai-context] Live reload unavailable")
      end

      expect { server.send(:start_stdio, server.build) }
        .to output(/Live reload unavailable/).to_stderr
      expect(logger).not_to have_received(:warn)
    end

    it "go back to the app logger once the transport has closed" do
      logger = instance_double(Logger, warn: nil)
      allow(Rails).to receive(:logger).and_return(logger)
      allow(described_class::StdioChannelTransport).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap { |transport| allow(transport).to receive(:open) }
      end
      allow(server).to receive(:maybe_start_live_reload)
      allow($stderr).to receive(:puts)

      server.send(:start_stdio, server.build)
      RailsAiContext.log_warn("after")

      expect(logger).to have_received(:warn).with("after")
    end
  end

  # Sidekiq builds Logger.new($stdout) on first use, which is during a tool
  # call, long after the boot quarantine has ended.
  describe "a real stdio session" do
    it "carries nothing but JSON-RPC on stdout while a tool writes to stdout or the server notifies" do
      require "open3"

      Dir.mktmpdir do |dir|
        script = File.join(dir, "serve.rb")
        File.write(script, <<~RUBY)
          $LOAD_PATH.unshift(#{File.expand_path("../../../lib", __dir__).inspect})
          require "rails_ai_context"
          require "logger"
          require "mcp"

          class NoisyTool < MCP::Tool
            tool_name "noisy"
            description "writes to stdout"
            input_schema(properties: {})

            def self.call(server_context: nil, **)
              STDOUT.puts "constant noise"
              STDOUT.flush
              $stdout.puts "global noise"
              Logger.new($stdout).info("logger noise")
              system("echo child noise")
              $mcp.notify_resources_list_changed
              $stderr.puts "channel=\#{$mcp.transport.instance_variable_get(:@channel).external_encoding}"
              MCP::Tool::Response.new([ { type: "text", text: "done" } ])
            end
          end

          RailsAiContext::Server.prepend(Module.new { def build = ($mcp = super) })
          RailsAiContext.configuration.custom_tools = [ NoisyTool ]
          stderr_encoding = $stderr.external_encoding.inspect
          RailsAiContext::Server.new(RailsAiContext::StaticApp.new(#{dir.inspect}), transport: :stdio).start
          $stderr.puts "stderr before=\#{stderr_encoding} after=\#{$stderr.external_encoding.inspect}"
        RUBY

        requests = [
          { jsonrpc: "2.0", id: 1, method: "initialize",
            params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } } },
          { jsonrpc: "2.0", method: "notifications/initialized" },
          { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "noisy", arguments: {} } }
        ].map { |r| "#{JSON.generate(r)}\n" }.join

        out, err, status = Open3.capture3(RbConfig.ruby, script, stdin_data: requests, chdir: dir)

        expect(status).to be_success, err
        lines = out.lines
        messages = lines.map { |l| JSON.parse(l) }
        expect(messages.map { |m| m["id"] || m["method"] }).to eq([ 1, "notifications/resources/list_changed", 2 ]), out
        expect(lines.last).to include("done")
        expect(err).to include("constant noise", "global noise", "logger noise", "child noise", "channel=UTF-8")
        before, after = err.match(/stderr before=(\S+) after=(\S+)/).captures
        expect(after).to eq(before)
      end
    end
  end
end
