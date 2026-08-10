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

      it "includes all tools when skip_tools is empty" do
        RailsAiContext.configuration.skip_tools = []
        mcp_server = server.build
        described_class.builtin_tools.each do |tool|
          expect(mcp_server.tools.values).to include(tool)
        end
      end
    end
  end

  describe "#start" do
    it "raises ConfigurationError for unknown transport" do
      s = described_class.new(app, transport: :unknown)
      expect { s.start }.to raise_error(RailsAiContext::ConfigurationError, /Unknown transport/)
    end
  end

  describe "#build_rack_app" do
    let(:s) { described_class.new(app, transport: :http) }
    let(:mcp_path) { RailsAiContext.configuration.http_path }

    def call_rack_app(transport, path_info)
      rack_app = s.send(:build_rack_app, transport, mcp_path)
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

        expected_status, expected_headers, expected_body =
          RailsAiContext::McpEdge.internal_error_response(RuntimeError.new("transport exploded"))

        expect([ status, headers, body.join ])
          .to eq([ expected_status, expected_headers, expected_body.join ])
      end

      it "logs the failure" do
        call_rack_app(transport, mcp_path)
        expect(RailsAiContext).to have_received(:log_warn).with(a_string_matching("transport exploded"))
      end
    end
  end
end
