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
    path = File.join(@dir, "queue.sqlite3")
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

    it "names the database that holds a table the query did not find" do
      allow(RailsAiContext::Tools::Query).to receive(:cached_context)
        .and_return(schema: { tables: { "users" => {} }, secondary_databases: { "queue" => { tables: { "jobs" => {} } } } })

      response = query(sql: "SELECT name FROM jobs")

      expect(response.error?).to be(true)
      expect(text(response)).to include("no such table: jobs", 'The jobs table is on the queue database: run the query again with database: "queue".')
      expect(text(query(sql: "SELECT id FROM users", database: "queue")))
        .to include('The users table is on the primary database: run the query again with database: "primary".')
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

    it "answers a name the app does not have with the names it has" do
      response = runtime(database: "qeue")

      expect(response.error?).to be(true)
      expect(text(response)).to include("Did you mean queue?")
    end
  end
end
