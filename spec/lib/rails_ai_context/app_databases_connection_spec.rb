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
      # Bounded, so leases that block each other fail here rather than hang the suite.
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
        .to raise_error(RailsAiContext::AppDatabases::NotHere, "The cache database is configured in staging and production, " \
                                                               "not in #{Rails.env}, so it cannot be reached from here.")
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

      expect { list.fetch("queue").with_connection { nil } }.to raise_error(ActiveRecord::NoDatabaseError, /#{Regexp.escape(path)}/)
      expect(File.exist?(path)).to be(false)
    end

    it "suggests the closest name for a misspelled one, and every error is the gem's own" do
      list = databases("queue" => config(Rails.env, "queue", sqlite_file("queue")))

      expect { list.fetch("qeueu") }.to raise_error(RailsAiContext::AppDatabases::UnknownDatabase, /Did you mean queue\?.*primary, queue/)
      expect(RailsAiContext::AppDatabases::UnknownDatabase.ancestors).to include(RailsAiContext::Error)
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

      expect(state[:error]).to be_a(ActiveRecord::NoDatabaseError)
      expect(File.exist?(path)).to be(false)
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
