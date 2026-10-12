# frozen_string_literal: true

require "spec_helper"

# rails_query and rails_runtime_info against an app database other than the primary.
RSpec.describe "the database argument" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    ensure
      FileUtils.rm_rf(@migrate) if @migrate
    end
  end

  before do
    RailsAiContext::Tools::Query.reset_cache!
    RailsAiContext.configuration.query_allowed_columns = []
    @path = path = File.join(@dir, "queue.sqlite3")
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE jobs (name text, api_key text)")
    db.execute("INSERT INTO jobs VALUES ('mail', 'k-123')")
    db.close
    # Rails reads migrations only from inside the app.
    @migrate = Rails.root.join("db/queue_migrate").to_s
    configurations = ActiveRecord::DatabaseConfigurations.new(
      Rails.env => { "primary" => ActiveRecord::Base.connection_db_config.configuration_hash,
                     "queue" => { adapter: "sqlite3", database: path, migrations_paths: @migrate } },
      "production" => { "primary" => { adapter: "sqlite3", database: File.join(@dir, "production.sqlite3") },
                        "cache" => { adapter: "sqlite3", database: File.join(@dir, "cache.sqlite3") } }
    )
    allow(ActiveRecord::Base).to receive(:configurations).and_return(configurations)
  end

  def query(**args)
    RailsAiContext::Tools::Query.call(**args)
  end

  def text(response)
    response.content.first[:text]
  end

  def missing_primary
    config = ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, "primary", adapter: "sqlite3", database: File.join(@dir, "primary.sqlite3"))
    allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(config)
  end

  describe "rails_query" do
    it "reads the named database, and the primary with none named" do
      expect(text(query(sql: "SELECT name FROM jobs", database: "queue"))).to include("| mail |")
      expect(text(query(sql: "SELECT name FROM jobs"))).to include("no such table: jobs")
    end

    it "applies the secret column rule to the named database's columns" do
      answer = text(query(sql: "SELECT * FROM jobs", database: "queue"))

      expect(answer).to include("[FILTERED]")
      expect(answer).not_to include("k-123")
    end

    it "answers a misspelled name with the closest one and the names the app has" do
      response = query(sql: "SELECT 1", database: "qeue")

      expect(response.error?).to be(true)
      expect(text(response)).to include("No database named qeue. Did you mean queue?", "primary, queue, cache")
    end

    it "says a database only another environment configures is configured there" do
      response = query(sql: "SELECT 1", database: "cache")

      expect(response.error?).to be(true)
      expect(text(response)).to include("The cache database is configured in production, not in #{Rails.env}")
    end

    it "refuses a named SQLite database whose file is not there, by name, and creates nothing" do
      File.delete(@path)

      response = query(sql: "SELECT 1", database: "queue")

      expect(response.error?).to be(true)
      expect(text(response)).to include("The queue database does not exist yet", @path, "db:prepare")
      expect(text(response)).not_to include("Database unavailable")
      expect(File.exist?(@path)).to be(false)
    end

    it "refuses the primary the same way with no database named, without connecting" do
      missing_primary
      expect(ActiveRecord::Base).not_to receive(:connection)

      response = query(sql: "SELECT 1")

      expect(response.error?).to be(true)
      expect(text(response)).to include("The primary database does not exist yet", "db:prepare")
      expect(File.exist?(File.join(@dir, "primary.sqlite3"))).to be(false)
    end

    it "names the database that holds a table the query did not find" do
      allow(RailsAiContext::Tools::Query).to receive(:cached_context)
        .and_return(schema: { tables: { "users" => {} }, secondary_databases: { "queue" => { tables: { "jobs" => {} } } } })

      response = query(sql: "SELECT name FROM jobs")

      expect(response.error?).to be(true)
      expect(text(response)).to include("no such table: jobs", 'The jobs table is on the queue database: run the query again with database: "queue".')
      expect(text(query(sql: "SELECT id FROM users", database: "queue")))
        .to include('The users table is on the primary database: run the query again with database: "primary".')
    end

    it "answers a named database whose server cannot be reached as an error that names it" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
        .and_raise(ActiveRecord::ConnectionNotEstablished, "connection refused")

      response = query(sql: "SELECT 1", database: "queue")

      expect(response.error?).to be(true)
      expect(text(response)).to start_with("The queue database cannot be reached: connection refused").and include("the `queue` entry")
      expect(text(response)).not_to include("RAILS_ENV=test")
    end

    it "answers a named database its server does not have as an error that names it" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
        .and_raise(ActiveRecord::NoDatabaseError, "Unknown database 'app_queue'")

      response = query(sql: "SELECT 1", database: "queue")

      expect(response.error?).to be(true)
      expect(text(response)).to start_with("The queue database was not found on its server: Unknown database 'app_queue'")
      expect(text(response)).to include("`bin/rails db:create`", "the `queue` entry")
      expect(text(response)).not_to include("RAILS_ENV=test")
    end
  end

  describe "rails_runtime_info" do
    def runtime(**args)
      RailsAiContext::Tools::RuntimeInfo.call(**args)
    end

    it "reports the named database's tables" do
      answer = text(runtime(section: "database", database: "queue"))

      expect(answer).to include("## Database: queue", "| jobs |")
      expect(answer).not_to include("| users |")
    end

    it "reports pending migrations in every database configured here" do
      FileUtils.mkdir_p(@migrate)
      File.write(File.join(@migrate, "20240101000000_create_jobs.rb"), "class CreateJobs < ActiveRecord::Migration[7.1]\nend\n")

      answer = text(runtime(section: "database"))

      expect(answer).to include("**Pending migrations:** 1 in queue", "- 20240101000000 CreateJobs (queue)")
      expect(answer).not_to include("all up to date")
    end

    it "says the primary's SQLite file is not there in the database section, creates nothing, and still answers the other sections" do
      missing_primary

      response = runtime
      answer = text(response)

      expect(response.error?).to be(false)
      expect(answer).to include("## Database", "The primary database does not exist yet", "## Cache")
      expect(File.exist?(File.join(@dir, "primary.sqlite3"))).to be(false)
    end

    it "refuses a named SQLite database whose file is not there, whatever the section, and creates nothing" do
      File.delete(@path)

      [ nil, "database", "cache" ].each do |section|
        response = runtime(section: section, database: "queue")

        expect(response.error?).to be(true), section.inspect
        expect(text(response)).to include("The queue database does not exist yet", @path)
        expect(text(response)).not_to include("# Runtime Info")
        expect(File.exist?(@path)).to be(false)
      end
    end

    it "refuses a name another environment configures, whatever the section" do
      %w[cache jobs connections database].each do |section|
        response = runtime(section: section, database: "cache")

        expect(response.error?).to be(true), section
        expect(text(response)).to include("The cache database is configured in production, not in #{Rails.env}")
      end
    end

    it "says a section that does not read the database argument left it unused" do
      answer = text(runtime(section: "cache", database: "queue"))

      expect(answer).to include("## Cache", "_The cache section does not read `database`, so queue was not used._")
      expect(text(runtime(section: "database", database: "queue"))).not_to include("does not read `database`")
      expect(text(runtime(database: "queue"))).not_to include("does not read `database`")
    end

    it "answers a name the app does not have with the names it has" do
      response = runtime(database: "qeue")

      expect(response.error?).to be(true)
      expect(text(response)).to include("Did you mean queue?")
    end
  end
end
