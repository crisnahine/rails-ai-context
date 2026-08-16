# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::RuntimeInfo do
  before { described_class.reset_cache! }

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "includes Runtime Info header" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Runtime Info")
    end

    it "shows connection pool stats" do
      result = described_class.call(section: "connections")
      text = result.content.first[:text]
      expect(text).to include("Connection Pool")
      expect(text).to include("Pool size")
    end

    it "shows database section" do
      result = described_class.call(section: "database")
      text = result.content.first[:text]
      expect(text).to include("Database")
    end

    it "shows cache section" do
      result = described_class.call(section: "cache")
      text = result.content.first[:text]
      expect(text).to include("Cache")
    end

    it "shows jobs section" do
      result = described_class.call(section: "jobs")
      text = result.content.first[:text]
      expect(text).to include("Background Jobs")
    end

    it "filters to a single section" do
      result = described_class.call(section: "connections")
      text = result.content.first[:text]
      expect(text).to include("Connection Pool")
      expect(text).not_to include("Background Jobs")
      expect(text).not_to include("## Cache")
    end

    it "standard detail shows all sections" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("Connection Pool")
      expect(text).to include("Database")
    end

    it "handles graceful degradation when Sidekiq not loaded" do
      result = described_class.call(section: "jobs")
      text = result.content.first[:text]
      expect(text).to match(/only implemented for Sidekiq|no queue adapter detected/)
    end

    context "when ActiveRecord is not defined" do
      before do
        @original_ar = ActiveRecord
        hide_const("ActiveRecord")
      end

      after do
        # ActiveRecord is restored automatically by hide_const
      end

      it "degrades gracefully for connection pool section" do
        result = described_class.call(section: "connections")
        text = result.content.first[:text]
        expect(text).to include("ActiveRecord not available")
        expect(text).not_to include("Pool size")
      end

      it "degrades gracefully for database section" do
        result = described_class.call(section: "database")
        text = result.content.first[:text]
        expect(text).to include("ActiveRecord not available")
      end

      it "still returns cache and jobs sections" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Runtime Info")
        expect(text).to include("Cache")
        expect(text).to include("Background Jobs")
      end
    end

    it "has read-only annotations" do
      annotations = described_class.annotations_value
      expect(annotations.read_only_hint).to eq(true)
      expect(annotations.destructive_hint).to eq(false)
    end

    describe "cache section coherence (MemoryStore)" do
      # MemoryStore has no #stats, and its own #inspect is where the entry
      # count and byte size live. Passing that string through put a raw
      # `#<ActiveSupport::Cache::MemoryStore ...>` into the answer - the shape
      # this gem has shipped as a defect before, when a Proc's address reached
      # a file an app commits.
      it "reports the numbers, not the object" do
        store = ActiveSupport::Cache::MemoryStore.new
        store.write("a", "1")
        allow(Rails).to receive(:cache).and_return(store)

        text = described_class.call(section: "cache").content.first[:text]

        expect(text).to include("MemoryStore")
        expect(text).to include("**Entries:** 1")
        expect(text).to match(/\*\*Size:\*\* \d+ bytes/)
        expect(text).not_to include("#<")
        expect(text).not_to include("Stats not available for MemoryStore")
      end

      # A store that does answer #stats returns a Hash, and Hash#inspect is
      # still an object dumped into prose.
      it "renders a stats hash as facts" do
        store = double("CacheStore", stats: { "curr_items" => 12, "bytes" => 3400 })
        allow(store).to receive(:is_a?).and_return(false)
        allow(Rails).to receive(:cache).and_return(store)

        text = described_class.call(section: "cache").content.first[:text]

        expect(text).to include("curr_items: 12")
        expect(text).not_to include("=>")
      end
    end
  end

  describe ".gather_table_sizes (private)" do
    # Rails 8's default MySQL adapter reports adapter_name "Trilogy", not
    # "Mysql2" - matching only /mysql/ here would silently drop table sizes
    # for every Trilogy app (returns nil instead of querying INFORMATION_SCHEMA).
    it "queries INFORMATION_SCHEMA.TABLES for the trilogy adapter" do
      conn = double("connection")
      allow(conn).to receive(:select_all)
        .with(a_string_matching(/INFORMATION_SCHEMA\.TABLES/))
        .and_return([ { "name" => "products", "bytes" => 1024 } ])

      result = described_class.send(:gather_table_sizes, conn, "trilogy")
      expect(result).to eq([ { name: "products", bytes: 1024 } ])
    end
  end
end
