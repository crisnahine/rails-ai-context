# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "active_support/number_helper"

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

    it "names a Trilogy connection MySQL" do
      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("Trilogy")

      expect(described_class.call(section: "database").content.first[:text]).to include("**Adapter:** MySQL")
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

    context "when Sidekiq is loaded" do
      let(:stats) do
        double(enqueued: 12, processed: 3400, failed: 7, scheduled_size: 0, retry_size: 0, dead_size: 0)
      end

      before do
        stub_const("Sidekiq::Stats", class_double("Sidekiq::Stats", new: stats))
        allow(described_class).to receive(:require).with("sidekiq/api").and_return(true)
      end

      def jobs_text(adapter, workers: [])
        allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return(adapter)
        allow(described_class).to receive(:cached_context).and_return({ jobs: { workers: workers } })
        described_class.call(section: "jobs").content.first[:text]
      end

      it "shows Sidekiq's counts when Sidekiq is the adapter" do
        expect(jobs_text("sidekiq")).to include("**Adapter:** sidekiq", "**Enqueued:** 12")
      end

      it "shows no Sidekiq counts under another adapter" do
        text = jobs_text("async")
        expect(text).to include("this app uses the async adapter")
        expect(text).not_to include("Enqueued")
      end

      it "names Sidekiq's counts as its own workers' under another adapter" do
        text = jobs_text("async", workers: [ { name: "HardWorker" } ])
        expect(text).to include("this app uses the async adapter", "### Sidekiq", "**Enqueued:** 12")
      end
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

    # Solid Cache answers #stats from its database, and SQLite creates the file a connection asks for.
    describe "a Solid Cache store whose SQLite file is missing" do
      around do |example|
        Dir.mktmpdir do |dir|
          @file = File.join(dir, "production_cache.sqlite3")
          example.run
        end
      end

      before do
        record = Class.new(ActiveRecord::Base) { self.abstract_class = true }
        stub_const("SolidCache::Record", record)
        record.establish_connection(ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "cache", adapter: "sqlite3", database: @file))
        store = Class.new do
          def with_each_connection = yield
          def stats = { entries: SolidCache::Record.connection_pool.with_connection { |c| c.select_value("SELECT 1") } }
        end
        stub_const("SolidCache::Store", store)
        allow(Rails).to receive(:cache).and_return(store.new)
      end

      after { ActiveRecord::Base.connection_handler.remove_connection_pool("SolidCache::Record") }

      it "says the database does not exist yet and creates nothing" do
        text = described_class.call(section: "cache").content.first[:text]

        expect(File.exist?(@file)).to be(false)
        expect(text).to include("**Store:** SolidCache::Store, this MCP server process's `Rails.cache`")
        expect(text).to include("The cache database does not exist yet: its SQLite file #{@file} is not there, and nothing was created.")
      end

      it "reads the stats once the file is there" do
        File.write(@file, "")

        expect(described_class.call(section: "cache").content.first[:text]).to include("entries: 1")
      end
    end
  end

  describe "table sizes" do
    def database_section
      described_class.call(section: "database").content.first[:text]
    end

    it "shows the family's table sizes in its order" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:table_sizes)
        .and_return([ { name: "users", bytes: 16384 }, { name: "comments", bytes: 8192 }, { name: "posts", bytes: 8192 } ])

      expect(database_section.scan(/^\| (\w+) \|/).flatten).to eq(%w[Table users comments posts])
    end

    it "reads table sizes, index usage and pending migrations under the family's limit, at query_timeout" do
      RailsAiContext.configuration.query_timeout = 3
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:bounded).and_call_original

      described_class.call(section: "database", detail: "full")

      expect(RailsAiContext::DatabaseFamily::SqliteRuntime).to have_received(:bounded).with(ActiveRecord::Base.connection, 3).at_least(3).times
    ensure
      RailsAiContext.configuration.query_timeout = 5
    end

    it "says the table sizes were not read when their read times out, and still answers" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:table_sizes).and_raise(ActiveRecord::QueryCanceled, "stopped")

      expect(database_section).to include("**Adapter:** SQLite\n\n_Table sizes were not read: the read failed or took longer than query_timeout._\n")
      expect(database_section).not_to include("### Table Sizes", "stopped")
    end

    it "says nothing of table sizes where the database has no table" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:table_sizes).and_return([])

      expect(database_section).not_to include("Table sizes", "Table Sizes")
    end

    it "asks the MySQL family on a Trilogy connection" do
      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("Trilogy")
      allow(RailsAiContext::DatabaseFamily::MysqlRuntime).to receive(:table_sizes).and_return([ { name: "products", bytes: 1024 } ])
      allow(RailsAiContext::DatabaseFamily::MysqlRuntime).to receive(:bounded) { |_connection, _timeout, &reads| reads.call }

      expect(database_section).to include("| products | 1 KB |")
    end

    it "says index usage is not available where the database family keeps none" do
      expect(described_class.call(section: "database", detail: "full").content.first[:text])
        .to include("_Index usage is not available for the SQLite database family._")

      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("Trilogy")
      allow(RailsAiContext::DatabaseFamily::MysqlRuntime).to receive(:table_sizes).and_return([])
      allow(RailsAiContext::DatabaseFamily::MysqlRuntime).to receive(:bounded) { |_connection, _timeout, &reads| reads.call }

      expect(described_class.call(section: "database", detail: "full").content.first[:text])
        .to include("_Index usage is not available for the MySQL database family._")
      expect(database_section).not_to include("Index usage")
    end

    it "says index usage was not read when reading it failed" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:index_usage).and_raise(ActiveRecord::StatementInvalid, "boom")

      text = described_class.call(section: "database", detail: "full").content.first[:text]

      expect(text).to include("\n_Index usage was not read: the read failed or took longer than query_timeout._\n")
      expect(text).not_to include("Index Usage", "boom", "Index usage is not available")
    end

    it "says nothing of index usage where the database has no index" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:index_usage).and_return([])

      expect(described_class.call(section: "database", detail: "full").content.first[:text]).not_to include("Index usage", "Index Usage")
    end

    it "says table sizes and index usage are not available on an adapter with no family" do
      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("SQLServer")

      text = described_class.call(section: "database", detail: "full").content.first[:text]

      expect(text).to include("**Adapter:** SQLServer")
      expect(text).to include("Table sizes and index usage are not available for the SQLServer adapter")
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

      expect(RailsAiContext::DatabaseFamily::POSTGRESQL.index_usage(conn).map { |i| i[:index] })
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

    # human_size reimplements this without I18n, so the two must not drift.
    [
      0, 1, 2, 1023, 1024, 1025, 1536, 10_239, 12_600,
      1_048_575, 1_048_576, 1_500_000,
      1024**3 - 1, 1024**3, 5 * 1024**3 + 123_456_789,
      1024**4 - 1, 1024**4, 7 * 1024**4,
      1024**6, 5 * 1024**6 + 987_654_321
    ].each do |bytes|
      it "labels #{bytes} bytes as number_to_human_size does" do
        expect(described_class.send(:human_size, bytes))
          .to eq(ActiveSupport::NumberHelper.number_to_human_size(bytes, locale: :en))
      end
    end

    # Rails 7.0's converter stops at EB, so the ZB range is pinned to what 7.1 and later print.
    it "labels a zettabyte and more in ZB" do
      expect(described_class.send(:human_size, 1024**7)).to eq("1 ZB")
      expect(described_class.send(:human_size, 3 * 1024**8 + 12_345)).to eq("3070 ZB")
      expect(described_class.send(:human_size, 1024**9 * 3)).to eq("3150000 ZB")
    end
  end
end
