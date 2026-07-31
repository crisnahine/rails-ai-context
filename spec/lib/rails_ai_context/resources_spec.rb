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
      expect(result.first[:mimeType]).to eq("application/json")
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

    it "raises a not-found error for a completely unknown URI" do
      # On mcp >= 0.20 the handler re-raises internal RailsAiContext::Error as the
      # SDK's ResourceNotFoundError so clients get a proper "-32602 Resource not
      # found: <uri>" instead of a generic "Internal error" with the URI stripped.
      # On older but still-supported mcp the original error propagates unchanged.
      if defined?(MCP::Server::ResourceNotFoundError)
        expect { read_handler.call(uri: "rails://unknown_resource") }
          .to raise_error(MCP::Server::ResourceNotFoundError, %r{Resource not found: rails://unknown_resource})
      else
        expect { read_handler.call(uri: "rails://unknown_resource") }
          .to raise_error(RailsAiContext::Error, /Unknown resource/)
      end
    end

    it "delegates rails-ai-context:// URIs to VFS" do
      vfs_result = [ { uri: "rails-ai-context://models/User", mimeType: "application/json", text: '{"ok":true}' } ]
      allow(RailsAiContext::VFS).to receive(:resolve).and_return(vfs_result)

      result = read_handler.call(uri: "rails-ai-context://models/User")
      expect(result).to eq(vfs_result)
      expect(RailsAiContext::VFS).to have_received(:resolve).with("rails-ai-context://models/User")
    end

    it "still handles legacy rails:// URIs" do
      result = read_handler.call(uri: "rails://schema")
      expect(result.first[:uri]).to eq("rails://schema")
    end

    it "truncates payloads beyond max_tool_response_chars" do
      # Below the compact size of the fixture, so the reducer runs rather than
      # the payload simply fitting once its indentation is dropped.
      allow(RailsAiContext.configuration).to receive(:max_tool_response_chars).and_return(10)

      result = read_handler.call(uri: "rails://schema")
      text = result.first[:text]
      expect(text.length).to be <= 150
      expect(text).to include("truncated")
      # A cap this low leaves room for the marker and nothing else, but the
      # body still has to parse under the application/json label it carries.
      expect(result.first[:mimeType]).to eq("application/json")
      expect { JSON.parse(text) }.not_to raise_error
    end

    it "keeps a truncated model payload parseable" do
      allow(RailsAiContext.configuration).to receive(:max_tool_response_chars).and_return(10)

      result = read_handler.call(uri: "rails://models/User")
      expect(result.first[:mimeType]).to eq("application/json")
      expect { JSON.parse(result.first[:text]) }.not_to raise_error
    end

    it "leaves payloads under the cap untouched" do
      allow(RailsAiContext.configuration).to receive(:max_tool_response_chars).and_return(200_000)

      result = read_handler.call(uri: "rails://schema")
      expect(result.first[:mimeType]).to eq("application/json")
      expect(result.first[:text]).not_to include("truncated")
      expect(JSON.parse(result.first[:text])).to eq({ "tables" => [ "users" ] })
    end
  end

  describe ".bounded_json" do
    def cap(chars)
      allow(RailsAiContext.configuration).to receive(:max_tool_response_chars).and_return(chars)
    end

    # Mirrors SchemaIntrospector#call: scalars and one dominant :tables hash,
    # with two of the scalars sitting after it in insertion order.
    let(:schema) do
      {
        adapter: "postgresql",
        tables: 40.times.to_h { |t|
          [ "table_#{t}", { columns: 10.times.map { |c| { name: "col_#{c}", type: "string", null: false } },
                            primary_key: "id" } ]
        },
        total_tables: 40,
        schema_version: "20260731120000"
      }
    end

    it "pretty-prints a payload that fits" do
      cap(200_000)
      expect(described_class.bounded_json({ a: 1 })).to eq(JSON.pretty_generate({ a: 1 }))
    end

    it "returns parseable JSON that fits the cap" do
      cap(4_000)
      text = described_class.bounded_json(schema)

      expect(text.length).to be <= 4_000
      expect { JSON.parse(text) }.not_to raise_error
    end

    it "keeps every surviving element whole" do
      cap(4_000)
      kept = JSON.parse(described_class.bounded_json(schema))["tables"]

      expect(kept.size).to be_between(1, 39)
      kept.each_value do |table|
        expect(table["primary_key"]).to eq("id")
        expect(table["columns"].size).to eq(10)
      end
    end

    it "keeps the scalar keys that say how much is missing" do
      cap(4_000)
      parsed = JSON.parse(described_class.bounded_json(schema))

      # total_tables and schema_version sit AFTER the dominant :tables hash;
      # without hoisting they would be the first things dropped.
      expect(parsed["adapter"]).to eq("postgresql")
      expect(parsed["total_tables"]).to eq(40)
      expect(parsed["schema_version"]).to eq("20260731120000")
    end

    it "reports what it dropped" do
      cap(4_000)
      note = JSON.parse(described_class.bounded_json(schema))["_truncated"]

      expect(note["reason"]).to eq("response_size_cap")
      expect(note["max_chars"]).to eq(4_000)
      expect(note["original_chars"]).to eq(JSON.pretty_generate(schema).length)
      expect(note["hint"]).to include("rails_get_*")
      expect(note["clipped"]).to include(hash_including("path" => "tables", "total" => 40))
    end

    it "spends the budget on the collection that dominates" do
      cap(1_500)
      data = { filtered_by: "posts", total_routes: 300,
               routes: 300.times.map { |i| { verb: "GET", path: "/posts/#{i}" } } }
      parsed = JSON.parse(described_class.bounded_json(data))

      expect(parsed["filtered_by"]).to eq("posts")
      expect(parsed["total_routes"]).to eq(300)
      expect(parsed["routes"].size).to be_between(1, 299)
      expect(parsed["routes"]).to all(include("verb" => "GET"))
    end

    it "moves a non-object payload under a data key" do
      cap(600)
      parsed = JSON.parse(described_class.bounded_json(200.times.map { |i| { id: i } }))

      expect(parsed["data"].first).to eq({ "id" => 0 })
      expect(parsed["_truncated"]["reason"]).to eq("response_size_cap")
    end

    it "cuts an oversized string value in place with a marker" do
      cap(600)
      parsed = JSON.parse(described_class.bounded_json({ source: "x" * 5_000 }))

      expect(parsed["source"]).to end_with("... (truncated)")
      expect(parsed["source"].length).to be < 5_000
    end

    # Two things make this the case that bites: a SYMBOL key, since Hash#merge
    # would already replace a string one, and an assertion on the emitted text,
    # since JSON.parse silently keeps the last of two identical keys and would
    # hide the duplicate entirely.
    it "does not emit a duplicate key when the payload owns _truncated" do
      cap(600)
      text = described_class.bounded_json({ _truncated: "mine", rows: (1..500).to_a })

      expect(text.scan('"_truncated"').size).to eq(1)
      expect(JSON.parse(text)["_truncated"]["reason"]).to eq("response_size_cap")
    end

    # A cap just above the dominant collection's own encoded size used to make
    # the reducer drop it whole and return a report with no data at all.
    it "never trades the whole payload for its own truncation report" do
      data = { routes: 300.times.map { |i| { verb: "GET", path: "/p/#{i}", name: "n#{i}" } } }
      pretty = JSON.pretty_generate(data).length

      (1_000..pretty).step(7) do |chars|
        cap(chars)
        parsed = JSON.parse(described_class.bounded_json(data))
        expect(parsed["routes"]).to be_present, "cap #{chars} returned no routes"
      end
    end

    it "drops the indentation before it drops data" do
      data = { rows: 400.times.map { |i| { id: i, name: "row_#{i}" } } }
      # A cap between the compact and pretty sizes is satisfied by compact
      # output alone, so nothing is lost and nothing is reported as lost.
      cap(JSON.generate(data).length + 10)
      parsed = JSON.parse(described_class.bounded_json(data))

      expect(parsed["rows"].size).to eq(400)
      expect(parsed).not_to have_key("_truncated")
    end

    it "labels clip counts with their unit" do
      cap(600)
      note = JSON.parse(described_class.bounded_json({ source: "x" * 5_000 }))["_truncated"]

      expect(note["clipped"]).to include(hash_including("path" => "source", "unit" => "chars"))
      expect(note["hint"]).to include("... (truncated)")
    end

    it "still parses when the cap is too small for any payload" do
      cap(20)
      expect(JSON.parse(described_class.bounded_json(schema))).to eq({ "_truncated" => true })
    end
  end
end
