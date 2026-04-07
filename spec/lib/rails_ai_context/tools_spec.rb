# frozen_string_literal: true

require "spec_helper"

RSpec.describe "MCP Tool Integration" do
  describe "tool definitions" do
    RailsAiContext::Server::TOOLS.each do |tool_class|
      describe tool_class.tool_name do
        it "has a valid MCP tool definition" do
          h = tool_class.to_h
          expect(h[:name]).to be_a(String)
          expect(h[:name]).not_to be_empty
          expect(h[:description]).to be_a(String)
          expect(h[:inputSchema]).to be_a(Hash)
        end

        it "has read-only annotations" do
          annotations = tool_class.annotations_value
          expect(annotations).not_to be_nil
          expect(annotations.read_only_hint).to eq(true)
          expect(annotations.destructive_hint).to eq(false)
        end

        it "has an output_schema defined" do
          schema = tool_class.instance_variable_get(:@output_schema_value)
          expect(schema).not_to be_nil
          expect(schema).to be_a(MCP::Tool::OutputSchema)

          h = tool_class.to_h
          expect(h).to have_key(:outputSchema)
        end
      end
    end
  end

  describe "MCP::Server" do
    let(:server) { RailsAiContext::Server.new(Rails.application).build }

    it "builds with all tools registered" do
      expect(server.tools.size).to eq(38)
      expect(server.tools.keys).to contain_exactly(
        "rails_get_schema",
        "rails_get_routes",
        "rails_get_model_details",
        "rails_get_gems",
        "rails_search_code",
        "rails_get_conventions",
        "rails_get_controllers",
        "rails_get_config",
        "rails_get_test_info",
        "rails_get_view",
        "rails_get_stimulus",
        "rails_get_edit_context",
        "rails_validate",
        "rails_analyze_feature",
        "rails_security_scan",
        "rails_get_concern",
        "rails_get_callbacks",
        "rails_get_helper_methods",
        "rails_get_service_pattern",
        "rails_get_job_pattern",
        "rails_get_env",
        "rails_get_partial_interface",
        "rails_get_turbo_map",
        "rails_get_context",
        "rails_get_component_catalog",
        "rails_performance_check",
        "rails_dependency_graph",
        "rails_migration_advisor",
        "rails_get_frontend_stack",
        "rails_search_docs",
        "rails_query",
        "rails_read_logs",
        "rails_generate_test",
        "rails_diagnose",
        "rails_review_changes",
        "rails_onboard",
        "rails_runtime_info",
        "rails_session_context"
      )
    end

    it "registers static resources" do
      uris = server.resources.map(&:uri)
      expect(uris).to contain_exactly(
        "rails://schema",
        "rails://routes",
        "rails://conventions",
        "rails://gems",
        "rails://controllers",
        "rails://config",
        "rails://tests",
        "rails://migrations",
        "rails://engines"
      )
    end
  end

  describe "custom_tools" do
    let(:fake_tool) do
      Class.new(MCP::Tool) do
        tool_name "my_custom_tool"
        description "A custom tool for testing"
        input_schema(properties: {})
        annotations(read_only_hint: true, destructive_hint: false)

        def self.call(server_context: nil)
          MCP::Tool::Response.new([ { type: "text", text: "hello" } ])
        end
      end
    end

    it "includes custom tools in the MCP server" do
      RailsAiContext.configuration.custom_tools = [ fake_tool ]

      server = RailsAiContext::Server.new(Rails.application).build

      expect(server.tools.keys).to include("my_custom_tool")
      expect(server.tools.size).to eq(39)
    ensure
      RailsAiContext.configuration.custom_tools = []
    end

    it "defaults to no custom tools" do
      server = RailsAiContext::Server.new(Rails.application).build

      expect(server.tools.size).to eq(38)
    end

    it "rejects non-MCP::Tool classes with a warning" do
      RailsAiContext.configuration.custom_tools = [ String, 42, "not_a_tool" ]

      expect($stderr).to receive(:puts).with(a_string_matching(/WARNING.*Skipping invalid custom_tool/)).exactly(3).times

      server = RailsAiContext::Server.new(Rails.application).build
      expect(server.tools.size).to eq(38)
    ensure
      RailsAiContext.configuration.custom_tools = []
    end

    it "accepts valid tools and rejects invalid entries in the same array" do
      RailsAiContext.configuration.custom_tools = [ fake_tool, "bad" ]
      allow($stderr).to receive(:puts)

      server = RailsAiContext::Server.new(Rails.application).build
      expect(server.tools.keys).to include("my_custom_tool")
      expect(server.tools.size).to eq(39)
    ensure
      RailsAiContext.configuration.custom_tools = []
    end
  end

  describe "skip_tools" do
    after { RailsAiContext.configuration.skip_tools = [] }

    it "excludes tools by name" do
      RailsAiContext.configuration.skip_tools = %w[rails_security_scan rails_query]

      server = RailsAiContext::Server.new(Rails.application).build

      expect(server.tools.keys).not_to include("rails_security_scan")
      expect(server.tools.keys).not_to include("rails_query")
      expect(server.tools.size).to eq(36)
    end

    it "defaults to no skipped tools" do
      server = RailsAiContext::Server.new(Rails.application).build

      expect(server.tools.size).to eq(38)
    end
  end

  describe "maybe_start_live_reload" do
    let(:server_wrapper) { RailsAiContext::Server.new(Rails.application) }
    let(:mcp_server) { server_wrapper.build }

    before { allow($stderr).to receive(:puts) }

    after { RailsAiContext.configuration.live_reload = :auto }

    context "when live_reload is false" do
      it "skips entirely" do
        RailsAiContext.configuration.live_reload = false

        expect(RailsAiContext::LiveReload).not_to receive(:new)
        server_wrapper.send(:maybe_start_live_reload, mcp_server)
      end
    end

    context "when live_reload is :auto and listen is available" do
      it "creates and starts LiveReload" do
        RailsAiContext.configuration.live_reload = :auto
        live_reload = instance_double(RailsAiContext::LiveReload)
        allow(RailsAiContext::LiveReload).to receive(:new).and_return(live_reload)
        allow(live_reload).to receive(:start)

        server_wrapper.send(:maybe_start_live_reload, mcp_server)

        expect(live_reload).to have_received(:start)
      end
    end

    context "when live_reload is :auto and listen is missing" do
      it "logs a tip and continues" do
        RailsAiContext.configuration.live_reload = :auto
        allow(RailsAiContext::LiveReload).to receive(:new).and_raise(LoadError, "cannot load such file -- listen")

        expect { server_wrapper.send(:maybe_start_live_reload, mcp_server) }.not_to raise_error
        expect($stderr).to have_received(:puts).with(a_string_matching(/Live reload unavailable/))
      end
    end

    context "when live_reload is true and listen is missing" do
      it "raises LoadError with install instructions" do
        RailsAiContext.configuration.live_reload = true
        allow(RailsAiContext::LiveReload).to receive(:new).and_raise(LoadError, "cannot load such file -- listen")

        expect { server_wrapper.send(:maybe_start_live_reload, mcp_server) }.to raise_error(LoadError, /listen/)
      end
    end
  end
end
