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

  # "Answers follow edits" was false for an app that does not reload code:
  # an edited association went unseen until a restart.
  describe ".instructions" do
    it "says answers follow edits where the app reloads its code" do
      allow(RailsAiContext::CodeReloader).to receive(:reloadable?).and_return(true)

      expect(described_class.instructions).to end_with("Answers follow edits to the app's files.")
    end

    it "says what does not follow an edit where it cannot" do
      allow(RailsAiContext::CodeReloader).to receive(:reloadable?).and_return(false)

      expect(described_class.instructions).to end_with(
        "Answers follow edits to the app's files, except what reflection reads, such as associations: " \
        "RAILS_ENV=test does not reload code, so that stays as of boot, and every answer says when app code changed since."
      )
    end

    it "is what a client is handed" do
      allow(RailsAiContext::CodeReloader).to receive(:reloadable?).and_return(false)

      expect(server.build.instructions).to eq(described_class.instructions)
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

      def raised(error)
        raise error
      rescue => e
        e
      end

      def with_debug(value)
        previous = ENV["DEBUG"]
        value.nil? ? ENV.delete("DEBUG") : ENV["DEBUG"] = value
        yield
      ensure
        previous.nil? ? ENV.delete("DEBUG") : ENV["DEBUG"] = previous
      end

      # A stack trace on every bad call buried the one line that said what
      # failed; DEBUG is where every other backtrace this gem prints lives.
      it "names a genuine internal error in one line, pointing at DEBUG for the backtrace" do
        expect($stderr).to receive(:puts).once.with(
          "[rails-ai-context] unhandled exception: RuntimeError: boom (DEBUG=1 prints the backtrace)"
        )
        with_debug(nil) { reporter.call(raised(RuntimeError.new("boom\nsecond line")), {}) }
      end

      it "logs genuine internal errors with the backtrace under DEBUG" do
        expect($stderr).to receive(:puts).with(/unhandled exception: RuntimeError: boom/)
        expect($stderr).to receive(:puts).with(/^    /).at_least(:once)
        with_debug("1") { reporter.call(raised(RuntimeError.new("boom")), {}) }
      end

      it "logs a RequestHandlerError whose error_type is :internal_error as an internal error" do
        error = raised(MCP::Server::RequestHandlerError.new(
          "Internal error handling tools/call request", {}, error_type: :internal_error
        ))
        expect($stderr).to receive(:puts).once.with(/unhandled exception: MCP::Server::RequestHandlerError/)
        with_debug(nil) { reporter.call(error, {}) }
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
      expect(options_for(resolved_handler)).to eq(
        Host: config.http_bind, Port: config.http_port, workers: 0, config_files: [ "-" ],
        force_shutdown_after: described_class::SHUTDOWN_TIMEOUT
      )
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

    describe "stopping" do
      let(:handler) { double("handler") }
      let(:transport) { instance_double(MCP::Server::Transports::StreamableHTTPTransport, close: nil) }

      before do
        allow(s).to receive_messages(default_rack_handler: handler, rack_handler_options: {}, tool_banner: "")
        allow(s).to receive(:maybe_start_live_reload)
        allow(MCP::Server::Transports::StreamableHTTPTransport).to receive(:new).and_return(transport)
      end

      # Puma finishes a graceful stop on SIGTERM and then raises it, which
      # rake reported as "bin/rails aborted! SignalException: SIGTERM".
      it "returns quietly when a stop signal ends the server" do
        allow(handler).to receive(:run).and_raise(SignalException, "TERM")

        expect { s.send(:start_http, instance_double(MCP::Server)) }.not_to raise_error
      end

      it "lets any other signal through" do
        allow(handler).to receive(:run).and_raise(SignalException, "HUP")

        expect { s.send(:start_http, instance_double(MCP::Server)) }.to raise_error(SignalException)
      end

      it "closes the transport, so a connected client sees the server go" do
        allow(handler).to receive(:run)

        s.send(:start_http, instance_double(MCP::Server))

        expect(transport).to have_received(:close)
      end
    end

    # Puma ran a SIGTERM stop inside the signal handler, where Ruby can
    # deadlock it against the server thread closing Puma's wake-up pipe: the
    # server printed "Gracefully stopping" and hung until SIGKILL.
    describe "a stop signal" do
      let(:launcher_class) do
        Class.new do
          attr_reader :events, :stops

          def initialize
            @stops = 0
            @booted = []
            @events = Object.new.tap do |events|
              booted = @booted
              events.define_singleton_method(:after_booted) { |&block| booted << block }
            end
          end

          def stop = @stops += 1
          def boot! = @booted.each(&:call)

          private

          def setup_signals = Signal.trap("TERM") { :pumas_own_stop }
        end
      end

      around do |example|
        saved = %w[TERM INT].to_h { |name| [ name, Signal.trap(name, "DEFAULT") ] }
        example.run
      ensure
        saved.each { |name, handler| Signal.trap(name, handler || "DEFAULT") }
      end

      let(:exits) { [] }

      before do
        allow(s).to receive(:sleep)
        allow(s).to receive(:exit!) { |status| exits << status }
      end

      def wait_for
        deadline = Time.now + 5
        sleep 0.01 until yield || Time.now > deadline
      end

      it "only queues the stop, and a thread asks Puma for it once Puma has booted" do
        launcher = launcher_class.new
        s.send(:stop_outside_signal_handler, launcher)
        launcher.send(:setup_signals)
        handler = Signal.trap("TERM", "DEFAULT")

        handler.call
        sleep 0.05
        expect(launcher.stops).to eq(0)

        launcher.boot!
        wait_for { launcher.stops == 1 }
        expect(launcher.stops).to eq(1)
      end

      it "ends the process when the stop never finishes" do
        launcher = launcher_class.new
        s.send(:stop_outside_signal_handler, launcher)
        launcher.send(:setup_signals)
        launcher.boot!

        Signal.trap("INT", "DEFAULT").call
        wait_for { exits.any? }

        expect(launcher.stops).to eq(1)
        expect(exits).to eq([ 1 ])
      end
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

      # Puma's own default waits for requests in flight forever, so one that
      # never finished kept a stopped server running until SIGKILL.
      it "bounds how long a stop waits for requests in flight" do
        expect(resolved(options_for(resolved_handler))[:force_shutdown_after]).to eq(described_class::SHUTDOWN_TIMEOUT)
      end
    end
  end

  # The old warning said a non-loopback bind served the network. With the
  # SDK's Host check a client addressing the machine by IP is refused, and a
  # client sending `Host: localhost` is not, so it was true of neither.
  describe "the warning for a bind beyond loopback" do
    let(:s) { described_class.new(app, transport: :http) }

    # mcp 1.x's transport takes allowed_hosts and refuses a foreign Host; the
    # 0.13 floor the gemspec allows has no such check.
    it "knows whether the SDK in this bundle checks the Host header" do
      takes_hosts = MCP::Server::Transports::StreamableHTTPTransport.instance_method(:initialize)
        .parameters.any? { |_, name| name == :allowed_hosts }
      expect(s.send(:host_checked?)).to be(takes_hosts)
      expect(s.send(:host_checked?)).to be(true) if Gem::Version.new(MCP::VERSION) >= Gem::Version.new("1.7")
    end

    it "says who the SDK refuses and who it serves" do
      allow(s).to receive(:host_checked?).and_return(true)
      warning = s.send(:bind_warning, "0.0.0.0")

      expect(warning).to include("0.0.0.0", %(403 "Invalid Host header"), "Host: localhost", "no authentication")
    end

    it "says every tool answers where the SDK has no Host check" do
      allow(s).to receive(:host_checked?).and_return(false)

      expect(s.send(:bind_warning, "0.0.0.0")).to include("Every tool answers whoever reaches it")
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

    # The SDK ended the connection on a frame past its 4 MiB limit and
    # reported it only through MCP.configuration's reporter, which nothing
    # set: no answer, nothing on stderr, exit 0.
    it "answers a frame past the size limit with a JSON-RPC error, names it on stderr and ends in failure" do
      require "open3"

      Dir.mktmpdir do |dir|
        script = File.join(dir, "serve.rb")
        File.write(script, <<~RUBY)
          $LOAD_PATH.unshift(#{File.expand_path("../../../lib", __dir__).inspect})
          require "rails_ai_context"
          require "mcp"

          begin
            RailsAiContext::Server.new(RailsAiContext::StaticApp.new(#{dir.inspect}), transport: :stdio).start
          rescue RailsAiContext::Error => e
            $stderr.puts "Error: \#{e.message}"
            exit 1
          end
        RUBY
        initialize = JSON.generate(jsonrpc: "2.0", id: 1, method: "initialize",
                                   params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } })
        frame = "#{initialize}\n#{"x" * (5 * 1024 * 1024)}\n"

        out, err, status = Open3.capture3(RbConfig.ruby, script, stdin_data: frame, chdir: dir)

        messages = out.lines.map { |line| JSON.parse(line) }
        expect(messages.first["id"]).to eq(1)
        expect(messages.last).to include("id" => nil, "error" => a_hash_including("code" => -32600, "message" => /exceeds 4194304 bytes/))
        expect(err).to include("[rails-ai-context] unhandled exception: MCP::Server::RequestHandlerError: stdio frame exceeds 4194304 bytes")
        expect(err).to include("Error: MCP stdio connection closed: stdio frame exceeds 4194304 bytes")
        expect(status.exitstatus).to eq(1)
      end
    end
  end
end
