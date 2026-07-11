# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::SearchDocs do
  before do
    described_class.instance_variable_set(:@docs_index, nil)
  end

  let(:mock_index) do
    {
      "topics" => [
        {
          "id" => "active_record_basics",
          "title" => "Active Record Basics",
          "summary" => "Learn how Active Record maps database tables to Ruby classes.",
          "source" => "rails",
          "keywords" => %w[orm database model migration]
        },
        {
          "id" => "active_record_validations",
          "title" => "Active Record Validations",
          "summary" => "Ensure data integrity with built-in and custom validations.",
          "source" => "rails",
          "keywords" => %w[validates presence uniqueness format]
        },
        {
          "id" => "active_record_callbacks",
          "title" => "Active Record Callbacks",
          "summary" => "Hook into the object lifecycle with before_save, after_create, and more.",
          "source" => "rails",
          "keywords" => %w[callbacks before_save after_create lifecycle hooks]
        },
        {
          "id" => "turbo_handbook_streams",
          "title" => "Turbo Streams",
          "summary" => "Deliver page changes over WebSocket or in response to form submissions.",
          "source" => "turbo",
          "keywords" => %w[turbo streams websocket broadcast hotwire],
          "path" => "_source/handbook/05_streams.md"
        },
        {
          "id" => "stimulus_handbook_introduction",
          "title" => "Stimulus Handbook",
          "summary" => "A modest JavaScript framework for the HTML you already have.",
          "source" => "stimulus",
          "keywords" => %w[stimulus controllers targets values actions javascript],
          "path" => "docs/handbook/01_introduction.md"
        },
        {
          "id" => "action_cable_overview",
          "title" => "Action Cable Overview",
          "summary" => "Integrate WebSockets with the rest of your Rails application.",
          "source" => "rails",
          "keywords" => %w[websocket cable channels subscriptions realtime]
        },
        {
          "id" => "routing",
          "title" => "Rails Routing from the Outside In",
          "summary" => "Understand how URLs map to controller actions using the Rails router.",
          "source" => "rails",
          "keywords" => %w[routes resources namespace scope constraints]
        }
      ]
    }
  end

  let(:mock_index_json) { JSON.generate(mock_index) }

  before do
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(described_class::INDEX_PATH).and_return(true)
    allow(File).to receive(:file?).and_call_original
    allow(File).to receive(:file?).with(described_class::INDEX_PATH).and_return(true)
    allow(RailsAiContext::SafeFile).to receive(:read).and_call_original
    allow(RailsAiContext::SafeFile).to receive(:read).with(described_class::INDEX_PATH).and_return(mock_index_json)

    # Mock Gemfile.lock for Rails version detection
    gemfile_lock_path = Rails.root.join("Gemfile.lock").to_s
    allow(File).to receive(:exist?).with(gemfile_lock_path).and_return(true)
    allow(File).to receive(:file?).with(gemfile_lock_path).and_return(true)
    allow(RailsAiContext::SafeFile).to receive(:read).with(gemfile_lock_path).and_return("    railties (8.0.1)\n")
  end

  describe ".call" do
    it "returns results for 'active record'" do
      result = described_class.call(query: "active record")
      text = result.content.first[:text]

      expect(text).to include("Rails Documentation Search: \"active record\"")
      expect(text).to include("Active Record Basics")
      expect(text).to include("Active Record Validations")
      expect(text).to include("Active Record Callbacks")
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "returns results for 'turbo streams'" do
      result = described_class.call(query: "turbo streams")
      text = result.content.first[:text]

      expect(text).to include("Turbo Streams")
      expect(text).to include("Deliver page changes over WebSocket")
      # Turbo URLs use main branch (no version branches), not the Rails branch
      expect(text).to include("hotwired/turbo-site/main")
    end

    it "filters by source: stimulus" do
      result = described_class.call(query: "javascript", source: "stimulus")
      text = result.content.first[:text]

      expect(text).to include("Stimulus Handbook")
      expect(text).not_to include("Active Record")
      expect(text).not_to include("Turbo Streams")
    end

    it "respects limit parameter" do
      result = described_class.call(query: "active record", limit: 1)
      text = result.content.first[:text]

      expect(text).to include("Found 1 result")
      # Should only show the highest-scored result
      expect(text).to include("Active Record")
    end

    it "returns 'no results' for nonsense query" do
      result = described_class.call(query: "zzz_xylophone_quantum_99")
      text = result.content.first[:text]

      expect(text).to include("No documentation found for 'zzz_xylophone_quantum_99'")
      expect(text).to include("Try broader terms")
    end

    it "returns error for empty query" do
      result = described_class.call(query: "")
      text = result.content.first[:text]

      expect(text).to include("Query is required")
    end

    it "returns error for whitespace-only query" do
      result = described_class.call(query: "   ")
      text = result.content.first[:text]

      expect(text).to include("Query is required")
    end

    it "returns error for invalid source" do
      result = described_class.call(query: "active record", source: "wikipedia")
      text = result.content.first[:text]

      expect(text).to include("Invalid source: 'wikipedia'")
      expect(text).to include("Valid values:")
      expect(text).to include("guides")
    end

    it "handles missing index file gracefully" do
      described_class.instance_variable_set(:@docs_index, nil)
      allow(File).to receive(:exist?).with(described_class::INDEX_PATH).and_return(false)

      result = described_class.call(query: "active record")
      text = result.content.first[:text]

      expect(text).to include("Documentation index not found")
      expect(text).to include("reinstall rails-ai-context")
    end

    it "handles malformed JSON index gracefully" do
      described_class.instance_variable_set(:@docs_index, nil)
      allow(RailsAiContext::SafeFile).to receive(:read).with(described_class::INDEX_PATH).and_return("not valid json{{{")

      result = described_class.call(query: "active record")
      text = result.content.first[:text]

      expect(text).to include("Failed to parse documentation index")
    end

    context "with fetch: true" do
      let(:mock_response) do
        response = instance_double(Net::HTTPSuccess, body: "# Active Record Basics\n\nFull guide content here...", code: "200")
        allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        response
      end

      before do
        cache_dir = Rails.root.join("tmp", "rails-ai-context", "docs")
        allow(FileUtils).to receive(:mkdir_p).with(cache_dir)
        allow(File).to receive(:exist?).with(cache_dir.join("active_record_basics_8-0-stable.md")).and_return(false)
        allow(File).to receive(:write)

        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(mock_response)
      end

      it "fetches and returns full content" do
        result = described_class.call(query: "active record basics", fetch: true)
        text = result.content.first[:text]

        expect(text).to include("(fetched)")
        expect(text).to include("Active Record Basics")
        expect(text).to include("Full guide content here")
      end
    end

    context "with fetch: true and network failure" do
      before do
        cache_dir = Rails.root.join("tmp", "rails-ai-context", "docs")
        allow(FileUtils).to receive(:mkdir_p).with(cache_dir)
        allow(File).to receive(:exist?).with(cache_dir.join("active_record_basics_8-0-stable.md")).and_return(false)

        allow(Net::HTTP).to receive(:new).and_raise(SocketError.new("getaddrinfo: Name or service not known"))
      end

      it "degrades to summary with error message" do
        result = described_class.call(query: "active record basics", fetch: true)
        text = result.content.first[:text]

        expect(text).to include("Active Record Basics")
        expect(text).to include("fetch failed")
        expect(text).to include("Name or service not known")
      end
    end

    it "defaults negative limit to 5" do
      result = described_class.call(query: "active record", limit: -3)
      text = result.content.first[:text]

      expect(text).to include("Found")
      expect(text).to include("Active Record")
    end

    it "caps limit at 20" do
      result = described_class.call(query: "active record", limit: 100)
      text = result.content.first[:text]

      # Should not error; results are just capped at available count
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "resolves {branch} in URLs with detected Rails version" do
      result = described_class.call(query: "routing")
      text = result.content.first[:text]

      expect(text).to include("8-0-stable")
      expect(text).not_to include("{branch}")
    end

    it "scores title matches higher than keyword matches" do
      result = described_class.call(query: "callbacks", limit: 1)
      text = result.content.first[:text]

      # "Active Record Callbacks" has "callbacks" in the title (10 pts)
      # vs other topics that might only have it as a keyword (1 pt)
      expect(text).to include("Active Record Callbacks")
    end

    it "retries after transient index load failure" do
      # First call: simulate a parse error
      described_class.instance_variable_set(:@docs_index, nil)
      allow(RailsAiContext::SafeFile).to receive(:read).with(described_class::INDEX_PATH).and_return("invalid json{{{")

      result1 = described_class.call(query: "active record")
      expect(result1.content.first[:text]).to include("Failed to parse")

      # Second call: fix the index - should retry since error wasn't memoized
      allow(RailsAiContext::SafeFile).to receive(:read).with(described_class::INDEX_PATH).and_return(mock_index_json)

      result2 = described_class.call(query: "active record")
      expect(result2.content.first[:text]).to include("Active Record Basics")
    end
  end
end
