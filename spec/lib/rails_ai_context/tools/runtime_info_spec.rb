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

    # PendingMigrations.live is stubbed here: the suite's own database has no
    # pending migrations, so the rendering is otherwise unreachable.
    it "renders each pending migration as a version and a name" do
      allow(RailsAiContext::PendingMigrations).to receive(:live)
        .and_return([ { version: "20240201000000", name: "AddIndex" } ])

      text = described_class.call(section: "database").content.first[:text]

      expect(text).to include("**Pending migrations:** 1")
      expect(text).to include("- 20240201000000 AddIndex")
    end

    it "names the adapter as every other surface does" do
      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("PostGIS")

      text = described_class.call(section: "database").content.first[:text]

      expect(text).to include("**Adapter:** PostgreSQL")
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

      # 0 entries in the MCP server's own MemoryStore read as the app's cache
      # being empty, and 0 connections as the app holding none.
      it "says the store and the pool are this MCP server process's own" do
        allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

        cache = described_class.call(section: "cache").content.first[:text]
        pool = described_class.call(section: "connections").content.first[:text]

        expect(cache).to include("**Store:** MemoryStore, this MCP server process's `Rails.cache`")
        expect(cache).to include("A MemoryStore lives inside one process, so these numbers are this MCP server's own.")
        expect(pool).to include("_This MCP server process's pool: the counts are its own connections.")
      end

      it "names the shared store another environment keeps the app's cache in" do
        allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
        allow(described_class).to receive(:rails_env_name).and_return("development")
        allow(described_class).to receive(:cached_context).and_return(env_config: { environments: [
          { name: "development", file: "config/environments/development.rb", notable: { "cache_store" => ":memory_store" } },
          { name: "production", file: "config/environments/production.rb",
            notable: { "cache_store" => ':redis_cache_store, { url: ENV.fetch("REDIS_URL") { "redi...' } },
          { name: "test", file: "config/environments/test.rb", notable: { "cache_store" => ":null_store" } }
        ] })

        text = described_class.call(section: "cache").content.first[:text]

        expect(text).to include("**The app's cache in other environments:**\n- production: `:redis_cache_store` (`config/environments/production.rb`)\n")
        expect(text).not_to include("null_store")
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

    it "reads PostgreSQL's table sizes for the PostGIS adapter" do
      conn = double("connection")
      allow(RailsAiContext::Introspectors::PgPartitions).to receive(:table_bytes).with(conn)
        .and_return([ { name: "parcels", bytes: 8192 } ])

      expect(described_class.send(:gather_table_sizes, conn, "postgis")).to eq([ { name: "parcels", bytes: 8192 } ])
    end

    it "lists equally large PostgreSQL tables by name" do
      conn = double("connection")
      allow(RailsAiContext::Introspectors::PgPartitions).to receive(:table_bytes).with(conn)
        .and_return([ { name: "posts", bytes: 8192 }, { name: "comments", bytes: 8192 }, { name: "users", bytes: 16384 } ])

      expect(described_class.send(:gather_table_sizes, conn, "postgresql").map { |r| r[:name] }).to eq(%w[users comments posts])
    end
  end
  # SQLite reports no table sizes, so this is the only reachable seam for the
  # byte labels the database section prints.
  describe "index usage" do
    it "orders PostgreSQL's least used indexes by table and index name" do
      conn = double("connection")
      allow(RailsAiContext::Introspectors::PgPartitions).to receive(:index_stats).with(conn).and_return([
        { table: "posts", index: "index_posts_on_title", scans: 0 },
        { table: "comments", index: "index_comments_on_post_id", scans: 0 },
        { table: "posts", index: "index_posts_on_slug", scans: 0 }
      ])

      expect(described_class.send(:gather_index_usage, conn, "postgresql").map { |i| i[:index] })
        .to eq(%w[index_comments_on_post_id index_posts_on_slug index_posts_on_title])
    end

    it "lists equally used indexes by table and index name" do
      allow(described_class).to receive(:gather_index_usage).and_return([
        { table: "posts", index: "index_posts_on_title", scans: 4 },
        { table: "posts", index: "index_posts_on_slug", scans: 4 },
        { table: "comments", index: "index_comments_on_post_id", scans: 4 }
      ])

      text = described_class.call(section: "database", detail: "full").content.first[:text]
      most_used = text[/\*\*Most used indexes:\*\*\n(.*)/m, 1].lines.grep(/\A- /)

      expect(most_used.map { |line| line[/`([^`]+)`/, 1] })
        .to eq(%w[index_comments_on_post_id index_posts_on_slug index_posts_on_title])
    end

    it "says how many unused indexes it left out" do
      allow(described_class).to receive(:gather_index_usage).and_return(
        (1..12).map { |n| { table: "t#{n}", index: "index_t#{n}_on_x", scans: 0 } }
      )

      text = described_class.call(section: "database", detail: "full").content.first[:text]

      expect(text[/\*\*Unused indexes \(0 scans\):\*\*\n(.*?)\n\n/m, 1].lines.grep(/\A- /).size).to eq(10)
      expect(text).to include("_2 more unused indexes..._")
    end

    it "says how many tables the summary left out" do
      allow(described_class).to receive(:gather_table_sizes).and_return(
        (1..7).map { |n| { name: "t#{n}", bytes: 1024 * n } }
      )

      text = described_class.call(section: "database", detail: "summary").content.first[:text]

      expect(text).to include("_2 more tables..._")
    end
  end

  describe "byte labels" do
    it "labels sizes in English whatever the app's locale is" do
      with_comma_separator_locale do
        expect(described_class.send(:human_size, 1_500_000)).to eq("1.43 MB")
      end
    end

    it "still labels sizes when the app's locales leave out English" do
      with_german_only_locales do
        expect(described_class.send(:human_size, 1_500_000)).to eq("1.43 MB")
      end
    end

    it "labels sizes the way the rest of the gem does" do
      expect(described_class.send(:human_size, nil)).to eq("0 Bytes")
      expect(described_class.send(:human_size, 0)).to eq("0 Bytes")
      expect(described_class.send(:human_size, 1_048_576)).to eq("1 MB")
      expect(described_class.send(:human_size, 1_500_000)).to eq("1.43 MB")
    end
  end
end
