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
end
