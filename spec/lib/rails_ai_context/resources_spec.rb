# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Resources do
  describe "STATIC_RESOURCES" do
    it "is a frozen hash" do
      expect(described_class::STATIC_RESOURCES).to be_frozen
      expect(described_class::STATIC_RESOURCES).to be_a(Hash)
    end

    it "contains known resource URIs" do
      uris = described_class::STATIC_RESOURCES.keys
      expect(uris).to include("rails://schema")
      expect(uris).to include("rails://routes")
      expect(uris).to include("rails://conventions")
      expect(uris).to include("rails://gems")
      expect(uris).to include("rails://controllers")
    end

    it "defines name, description, mime_type, and key for each resource" do
      described_class::STATIC_RESOURCES.each do |uri, meta|
        expect(meta).to have_key(:name), "#{uri} missing :name"
        expect(meta).to have_key(:description), "#{uri} missing :description"
        expect(meta).to have_key(:mime_type), "#{uri} missing :mime_type"
        expect(meta).to have_key(:key), "#{uri} missing :key"
        expect(meta[:mime_type]).to eq("application/json")
      end
    end
  end

  describe "MODEL_TEMPLATE" do
    it "is an MCP::ResourceTemplate" do
      expect(described_class::MODEL_TEMPLATE).to be_a(MCP::ResourceTemplate)
    end

    it "is frozen" do
      expect(described_class::MODEL_TEMPLATE).to be_frozen
    end

    it "has a URI template for models" do
      expect(described_class::MODEL_TEMPLATE.uri_template).to eq("rails://models/{name}")
    end
  end

  describe ".static_resources" do
    it "returns an array of MCP::Resource objects" do
      resources = described_class.static_resources
      expect(resources).to be_an(Array)
      resources.each do |resource|
        expect(resource).to be_a(MCP::Resource)
      end
    end

    it "returns one resource per STATIC_RESOURCES entry" do
      expect(described_class.static_resources.size).to eq(described_class::STATIC_RESOURCES.size)
    end
  end

  describe "CONTROLLER_TEMPLATE" do
    it "is a frozen MCP::ResourceTemplate" do
      expect(described_class::CONTROLLER_TEMPLATE).to be_a(MCP::ResourceTemplate)
      expect(described_class::CONTROLLER_TEMPLATE).to be_frozen
    end

    it "has a URI template for controllers" do
      expect(described_class::CONTROLLER_TEMPLATE.uri_template).to eq("rails-ai-context://controllers/{name}")
    end
  end

  describe "CONTROLLER_ACTION_TEMPLATE" do
    it "has a URI template for controller actions" do
      expect(described_class::CONTROLLER_ACTION_TEMPLATE.uri_template).to eq("rails-ai-context://controllers/{name}/{action}")
    end
  end

  describe "VIEW_TEMPLATE" do
    it "has a URI template for views" do
      expect(described_class::VIEW_TEMPLATE.uri_template).to eq("rails-ai-context://views/{path}")
    end
  end

  describe "ROUTES_TEMPLATE" do
    it "has a URI template for routes with controller variable" do
      expect(described_class::ROUTES_TEMPLATE.uri_template).to eq("rails-ai-context://routes/{controller}")
    end
  end

  describe ".resource_templates" do
    it "returns 5 templates" do
      templates = described_class.resource_templates
      expect(templates.size).to eq(5)
      expect(templates).to include(described_class::MODEL_TEMPLATE)
      expect(templates).to include(described_class::CONTROLLER_TEMPLATE)
      expect(templates).to include(described_class::VIEW_TEMPLATE)
      expect(templates).to include(described_class::ROUTES_TEMPLATE)
    end
  end

  describe ".register" do
    let(:mock_server) do
      instance_double("MCP::Server").tap do |s|
        allow(s).to receive(:resources=)
        allow(s).to receive(:resources_read_handler)
      end
    end

    it "sets resources on the server" do
      described_class.register(mock_server)
      expect(mock_server).to have_received(:resources=).with(an_instance_of(Array))
    end

    it "registers a resources_read_handler" do
      described_class.register(mock_server)
      expect(mock_server).to have_received(:resources_read_handler)
    end
  end

  describe "handle_read (via register)" do
    let(:fake_context) do
      {
        schema: { tables: [ "users" ] },
        routes: { total: 10 },
        models: { "User" => { columns: [ "id", "name" ] } }
      }
    end

    before do
      allow(RailsAiContext).to receive(:introspect).and_return(fake_context)
    end

    # We test handle_read indirectly by capturing the block passed to resources_read_handler
    let(:read_handler) do
      captured_block = nil
      mock_server = instance_double("MCP::Server")
      allow(mock_server).to receive(:resources=)
      allow(mock_server).to receive(:resources_read_handler) { |&block| captured_block = block }
      described_class.register(mock_server)
      captured_block
    end

    it "returns JSON content for a static resource URI" do
      result = read_handler.call(uri: "rails://schema")
      expect(result).to be_an(Array)
      expect(result.first[:uri]).to eq("rails://schema")
      expect(result.first[:mime_type]).to eq("application/json")
      parsed = JSON.parse(result.first[:text])
      expect(parsed).to eq({ "tables" => [ "users" ] })
    end

    it "returns model data for a model URI" do
      result = read_handler.call(uri: "rails://models/User")
      expect(result).to be_an(Array)
      expect(result.first[:uri]).to eq("rails://models/User")
      parsed = JSON.parse(result.first[:text])
      expect(parsed["columns"]).to eq([ "id", "name" ])
    end

    it "returns error for an unknown model" do
      result = read_handler.call(uri: "rails://models/NonExistent")
      parsed = JSON.parse(result.first[:text])
      expect(parsed["error"]).to match(/not found/)
    end

    it "raises for a completely unknown URI" do
      expect { read_handler.call(uri: "rails://unknown_resource") }.to raise_error(/Unknown resource/)
    end

    it "delegates rails-ai-context:// URIs to VFS" do
      vfs_result = [ { uri: "rails-ai-context://models/User", mime_type: "application/json", text: '{"ok":true}' } ]
      allow(RailsAiContext::VFS).to receive(:resolve).and_return(vfs_result)

      result = read_handler.call(uri: "rails-ai-context://models/User")
      expect(result).to eq(vfs_result)
      expect(RailsAiContext::VFS).to have_received(:resolve).with("rails-ai-context://models/User")
    end

    it "still handles legacy rails:// URIs" do
      result = read_handler.call(uri: "rails://schema")
      expect(result.first[:uri]).to eq("rails://schema")
    end
  end
end
