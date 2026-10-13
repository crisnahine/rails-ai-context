# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::AppDatabases::Database do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def sqlite_file(name, marker: name)
    path = File.join(@dir, "#{name}.sqlite3")
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE marker (name text)")
    db.execute("INSERT INTO marker VALUES (?)", [ marker ])
    path
  ensure
    db&.close
  end

  def config(env, name, database)
    ActiveRecord::DatabaseConfigurations::HashConfig.new(env, name, { adapter: "sqlite3", database: database })
  end

  def databases(extra = {}, elsewhere = {})
    env = Rails.env
    environments = { env => { "primary" => ActiveRecord::Base.connection_db_config }.merge(extra) }
    environments["production"] = elsewhere if elsewhere.any?
    RailsAiContext::AppDatabases.build(environments: environments, current: env, root: @dir, dumps: [])
  end

  def global_pools
    ActiveRecord::Base.connection_handler.connection_pool_list.map { |pool| pool.db_config.name }
  end

  describe "#with_connection" do
    it "reads a database configured here other than the primary, and leaves the app's pools as they were" do
      list = databases("queue" => config(Rails.env, "queue", sqlite_file("queue")))
      before = global_pools

      expect(list.fetch("queue").with_connection { |conn| conn.select_value("SELECT name FROM marker") }).to eq("queue")
      expect(global_pools).to eq(before)
    end

    it "closes the connection it opened to another database once the block returns" do
      list = databases("queue" => config(Rails.env, "queue", sqlite_file("queue")))
      pool = nil
      handler = nil
      allow(ActiveRecord::ConnectionAdapters::ConnectionHandler).to receive(:new).and_wrap_original { |build| handler = build.call }

      list.fetch("queue").with_connection { |conn| pool = conn.pool }

      expect(pool.stat[:connections]).to eq(0)
      expect(handler.connection_pool_list).to be_empty
    end

    it "closes the connection it opened to another database when the block raises" do
      list = databases("queue" => config(Rails.env, "queue", sqlite_file("queue")))
      pool = nil

      expect { list.fetch("queue").with_connection { |conn| raise((pool = conn.pool).stat[:connections].to_s) } }.to raise_error("1")
      expect(pool.stat[:connections]).to eq(0)
    end

    it "reads the primary through the app's own pool" do
      list = databases

      list.fetch(nil).with_connection { |conn| expect(conn.pool).to equal(ActiveRecord::Base.connection_pool) }
    end

    it "gives two threads leasing two databases at once each its own answer, and leaves the app's pools as they were" do
      list = databases("queue" => config(Rails.env, "queue", sqlite_file("queue")),
                       "cache" => config(Rails.env, "cache", sqlite_file("cache")))
      before = global_pools

      threads = %w[queue cache queue cache].map do |name|
        Thread.new { Array.new(10) { list.fetch(name).with_connection { |conn| conn.select_value("SELECT name FROM marker") } }.uniq }
      end
      # Bounded, so leases that block each other fail here within 30 seconds.
      answers = threads.map { |thread| thread.join(30)&.value }
      threads.each(&:kill)

      expect(answers).to eq([ [ "queue" ], [ "cache" ], [ "queue" ], [ "cache" ] ])
      expect(global_pools).to eq(before)
    end

    it "refuses a database only other environments configure, naming each of them" do
      cache = { "primary" => config("production", "primary", File.join(@dir, "app.sqlite3")),
                "cache" => config("production", "cache", File.join(@dir, "cache.sqlite3")) }
      list = RailsAiContext::AppDatabases.build(
        environments: { Rails.env => { "primary" => ActiveRecord::Base.connection_db_config }, "staging" => cache, "production" => cache },
        current: Rails.env, root: @dir, dumps: []
      )

      expect(list.fetch("cache").environments).to eq(%w[staging production])
      expect { list.fetch("cache").with_connection { nil } }
        .to raise_error(RailsAiContext::AppDatabases::NotHere, "The cache database is configured in staging and production. " \
                                                               "This process runs in #{Rails.env}, so it cannot be reached from here.")
    end

    it "refuses a database other than the primary that lives in memory, by name" do
      allow(RailsAiContext::DatabaseFile).to receive(:sqlite_reads_uris?).and_return(true)
      [ ":memory:", "file:queue?mode=memory&cache=shared", "file::memory:?cache=shared" ].each do |database|
        list = databases("queue" => config(Rails.env, "queue", database))

        expect { list.fetch("queue").with_connection { nil } }
          .to raise_error(RailsAiContext::AppDatabases::InMemory, /\AThe queue database lives in memory/), database
        expect(list.fetch("queue").pending_migrations[:error]).to be_a(RailsAiContext::AppDatabases::InMemory)
      end
    end

    it "says the SQLite file a file: URI names is missing, without creating it" do
      path = File.join(@dir, "queue.sqlite3")
      list = databases("queue" => config(Rails.env, "queue", "file:#{path}?mode=rwc"))

      expect { list.fetch("queue").with_connection { nil } }.to raise_error(RailsAiContext::AppDatabases::Missing, /queue database does not exist yet/)
      expect(list.fetch("queue").pending_migrations[:error]).to be_a(RailsAiContext::AppDatabases::Missing)
      expect(File.exist?(path)).to be(false)
    end

    it "reads the SQLite file a file: URI names when it is there" do
      skip "this SQLite reads no URIs" unless RailsAiContext::DatabaseFile.sqlite_reads_uris?

      list = databases("queue" => config(Rails.env, "queue", "file:#{sqlite_file("queue")}?mode=rw"))

      expect(list.fetch("queue").with_connection { |conn| conn.select_value("SELECT name FROM marker") }).to eq("queue")
    end

    it "names a database no connection reaches, and says what stopped it" do
      list = databases("queue" => config(Rails.env, "queue", @dir))

      expect { list.fetch("queue").with_connection { raise "the block ran" } }
        .to raise_error(RailsAiContext::AppDatabases::Unreachable,
                        /\AThe queue database cannot be reached: .*unable to open database file.*\. Check the file its config\/database.yml entry names\.\z/i)
    end

    it "answers a database whose adapter gem is not in the bundle as one that cannot be reached, naming the gem to add" do
      server = ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, "queue", { adapter: "sqlserver", database: "shop_queue" })
      queue = databases("queue" => server).fetch("queue")
      said = "The queue database cannot be reached: its sqlserver adapter did not load. " \
             "Add the gem that provides the sqlserver adapter to the Gemfile and run `bundle install`."

      expect { queue.with_connection { raise "the block ran" } }.to raise_error(RailsAiContext::AppDatabases::Unreachable, said)
      expect(queue.pending_migrations[:error]).to be_a(RailsAiContext::AppDatabases::AdapterMissing)
    end

    it "names the primary when the app's own connection does not answer, with or without its name" do
      # The suite's own connection always answers, so this one refusal is stubbed.
      allow(ActiveRecord::Base.connection).to receive(:verify!).and_raise(ActiveRecord::ConnectionNotEstablished.new("refused"))
      allow(RailsAiContext::AppDatabases).to receive(:for).and_return(databases)

      [ nil, "primary" ].each do |name|
        expect { RailsAiContext::AppDatabases.lease(@dir, name) { raise "the block ran" } }
          .to raise_error(RailsAiContext::AppDatabases::Unreachable, /\AThe primary database cannot be reached: refused\. /), name.inspect
      end
    end

    # The limits a lease connects with, read from the pool it leased. No server adapter is in this
    # bundle, so a SQLite file stands under each family.
    def limits(family, entry)
      database = described_class.new(**databases("leased" => entry).fetch("leased").to_h, family: family)
      database.with_connection { |conn| conn.pool.db_config.configuration_hash.slice(:connect_timeout, :read_timeout) }
    end

    def entry(extra = {})
      ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, "leased", { adapter: "sqlite3", database: (@leased ||= sqlite_file("leased")) }.merge(extra))
    end

    it "gives a leased server connection query_timeout to connect in, a MySQL one a read limit above twice that, and SQLite neither" do
      RailsAiContext.configuration.query_timeout = 2.5

      expect(limits(RailsAiContext::DatabaseFamily::MYSQL, entry)).to eq(connect_timeout: 3, read_timeout: 10)
      expect(limits(RailsAiContext::DatabaseFamily::POSTGRESQL, entry)).to eq(connect_timeout: 3)
      expect(limits(RailsAiContext::DatabaseFamily::SQLITE, entry)).to eq({})
    ensure
      RailsAiContext.configuration.query_timeout = 5
    end

    it "keeps each limit an entry sets for itself" do
      RailsAiContext.configuration.query_timeout = 5

      expect(limits(RailsAiContext::DatabaseFamily::MYSQL, entry(connect_timeout: 9))).to eq(connect_timeout: 9, read_timeout: 15)
      expect(limits(RailsAiContext::DatabaseFamily::MYSQL, entry(read_timeout: 1))).to eq(connect_timeout: 5, read_timeout: 1)
    end

    it "hands an error the block raises back as it is" do
      list = databases("queue" => config(Rails.env, "queue", sqlite_file("queue")))

      expect { list.fetch("queue").with_connection { |conn| conn.select_value("SELECT nope FROM marker") } }.to raise_error(ActiveRecord::StatementInvalid)
      expect { RailsAiContext::AppDatabases.lease(@dir, nil) { raise ActiveRecord::ConnectionNotEstablished, "mid-query" } }
        .to raise_error(ActiveRecord::ConnectionNotEstablished, "mid-query")
    end

    it "refuses a database only a committed dump names" do
      list = RailsAiContext::AppDatabases.build(environments: { Rails.env => { "primary" => ActiveRecord::Base.connection_db_config } },
                                                current: Rails.env, root: @dir, dumps: [ [ :ruby, File.join(@dir, "db/archive_schema.rb") ] ])

      expect { list.fetch("archive").with_connection { nil } }.to raise_error(RailsAiContext::AppDatabases::NotHere, /only a committed dump/)
    end

    it "refuses to connect on the static tier" do
      list = databases("queue" => { "adapter" => "sqlite3", "database" => sqlite_file("queue") })

      expect { list.fetch("queue").with_connection { nil } }.to raise_error(RailsAiContext::AppDatabases::NotBooted, /static tier/)
    end

    it "says a SQLite file that is not there is missing, without creating it" do
      path = File.join(@dir, "queue.sqlite3")
      list = databases("queue" => config(Rails.env, "queue", path))

      expect { list.fetch("queue").with_connection { nil } }.to raise_error(RailsAiContext::AppDatabases::Missing, /queue database does not exist yet.*#{Regexp.escape(path)}/)
      expect(File.exist?(path)).to be(false)
    end

    it "suggests the closest name for a misspelled one, and every error is the gem's own" do
      list = databases("queue" => config(Rails.env, "queue", sqlite_file("queue")))

      expect { list.fetch("qeueu") }.to raise_error(RailsAiContext::AppDatabases::UnknownDatabase, /Did you mean queue\?.*primary, queue/)
      expect(RailsAiContext::AppDatabases::UnknownDatabase.ancestors).to include(RailsAiContext::Error)
    end
  end

  describe ".unreachable" do
    def said(adapter, error)
      RailsAiContext::AppDatabases.unreachable("queue", adapter, error).message
    end

    it "says to start the server of a database nothing answers for" do
      refused = ActiveRecord::ConnectionNotEstablished.new("connection to server at \"127.0.0.1\", port 5999 failed: Connection refused\n\tIs the server running?")

      expect(said("postgresql", refused)).to eq(
        'The queue database cannot be reached: connection to server at "127.0.0.1", port 5999 failed: Connection refused. ' \
        "Start its server, or fix its settings in config/database.yml."
      )
    end

    it "says to create a database its server does not hold" do
      expect(said("trilogy", ActiveRecord::NoDatabaseError.new("We could not find your database: shop_queue."))).to eq(
        "The queue database cannot be reached: We could not find your database: shop_queue. " \
        "Run `bin/rails db:create` or `bin/rails db:prepare` to create it."
      )
    end

    it "names the gem of each adapter Rails ships, and of any other adapter says a gem provides it" do
      missing = LoadError.new("Error loading the adapter")

      expect(said("mysql2", missing)).to end_with("its mysql2 adapter did not load. Add the mysql2 gem to the Gemfile and run `bundle install`.")
      expect(said("postgis", missing)).to include("Add the activerecord-postgis-adapter gem to the Gemfile")
      expect(said("sqlserver", ActiveRecord::AdapterNotFound.new("nonexistent 'sqlserver' adapter")))
        .to end_with("its sqlserver adapter did not load. Add the gem that provides the sqlserver adapter to the Gemfile and run `bundle install`.")
    end
  end

  # A database keeps its own schema_migrations, which only a connection to it can read.
  describe "#pending_migrations" do
    def migrations_dir
      dir = File.join(@dir, "analytics_migrate")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "20240101000000_create_events.rb"), "class CreateEvents < ActiveRecord::Migration[7.1]\nend\n")
      dir
    end

    def analytics(path)
      databases("analytics" => config(Rails.env, "analytics", path)).fetch("analytics")
    end

    def tables_in(path)
      db = SQLite3::Database.new(path, readonly: true)
      db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten
    ensure
      db&.close
    end

    # Building a Migrator creates schema_migrations and ar_internal_metadata
    # in a database that lacks them; reading what is pending writes nothing.
    it "reads a database that was never migrated through the lease, writing nothing to it and leaving the app's pools" do
      path = File.join(@dir, "analytics.sqlite3")
      FileUtils.touch(path)
      before = global_pools

      expect(analytics(path).pending_migrations(migrations_dir)).to eq(pending: [ { version: "20240101000000", name: "CreateEvents" } ])
      expect(tables_in(path)).to eq([])
      expect(global_pools).to eq(before)
    end

    it "answers nothing pending for a database with no migrations, once it has connected" do
      path = File.join(@dir, "analytics.sqlite3")
      FileUtils.touch(path)

      expect(analytics(path).pending_migrations(File.join(@dir, "none"))).to eq(pending: [])
    end

    it "says a SQLite database whose file is not there does not exist, without creating it" do
      path = File.join(@dir, "analytics.sqlite3")

      state = analytics(path).pending_migrations(migrations_dir)

      expect(state[:error]).to be_a(RailsAiContext::AppDatabases::Missing)
      expect(File.exist?(path)).to be(false)
    end

    # A server answers a database it does not hold with ActiveRecord::NoDatabaseError.
    it "says a database its server does not hold is missing, as a SQLite file that is not there is" do
      path = File.join(@dir, "analytics.sqlite3")
      FileUtils.touch(path)
      allow(RailsAiContext::MigrationStatus).to receive(:pending_on).and_raise(ActiveRecord::NoDatabaseError.new("no such database"))

      state = analytics(path).pending_migrations(migrations_dir)

      expect(state[:error]).to be_a(RailsAiContext::AppDatabases::Missing)
      expect(state[:error].message).to eq("no such database")
    end

    # Rails 7.1+ wraps the driver's error; Rails 7.0's sqlite3 adapter hands
    # back SQLite3::CantOpenException itself.
    it "hands back what stopped the connection" do
      state = analytics(@dir).pending_migrations(@dir)

      expect(state.keys).to eq([ :error ])
      expect(state[:error].message).to match(/unable to open database file/i)
    end
  end
end
