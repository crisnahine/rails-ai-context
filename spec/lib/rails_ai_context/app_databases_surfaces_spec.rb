# frozen_string_literal: true

require "spec_helper"

# The default Rails 8 app: the running environment configures only the primary,
# production configures queue, cache and cable, and their dumps are committed.
RSpec.describe "the app databases on a Rails 8 app" do
  let(:root) { File.expand_path("../../fixtures/app_databases/rails8", __dir__) }
  let(:app) { RailsAiContext::StaticApp.new(root) }

  around do |example|
    previous = [ RailsAiContext.tier, ENV.fetch("RAILS_ENV", nil) ]
    RailsAiContext.tier = :static
    ENV["RAILS_ENV"] = "test"
    example.run
  ensure
    RailsAiContext.tier = previous.first
    ENV["RAILS_ENV"] = previous.last
  end

  it "names the same four databases in the schema, multi-database and model sections, and in migrations the one that has migration files" do
    schema = RailsAiContext::Introspectors::SchemaIntrospector.new(app).static_call
    multi = RailsAiContext::Introspectors::MultiDatabaseIntrospector.new(app).call
    models = RailsAiContext::Introspectors::ModelIntrospector.new(app).static_call
    migrations = RailsAiContext::Introspectors::MigrationIntrospector.new(app).call

    expect(schema[:secondary_databases].keys).to eq(%w[cache queue cable])
    expect(multi[:databases].map { |db| [ db[:name], db[:environments] ] })
      .to eq([ [ "primary", nil ], [ "cache", %w[production] ], [ "queue", %w[production] ], [ "cable", %w[production] ] ])
    expect(multi[:multi_db]).to be(true)
    expect(models["QueuedJob"]&.dig(:table_name)).to eq("solid_queue_jobs")
    expect(migrations[:secondary_databases]).to eq(
      "queue" => { total: 1, migrations_paths: %w[db/queue_migrate], pending: [] }
    )
  end

  it "says an adapter database.yml computes with a literal fallback is the default, in the schema answer too" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "db"))
      File.write(File.join(dir, "config/database.yml"), <<~YAML)
        test:
          adapter: <%= ENV["DB_ADAPTER"].presence || "postgresql" %>
          database: app_test
      YAML
      File.write(File.join(dir, "db/schema.rb"), "ActiveRecord::Schema[8.0].define(version: 1) do\n  create_table \"users\" do |t|\n  end\nend\n")
      static_app = RailsAiContext::StaticApp.new(dir)
      context = RailsAiContext::RunCache.around { RailsAiContext::Introspector.new(static_app).call }
      allow(RailsAiContext::Tools::GetSchema).to receive_messages(cached_context: context, rails_app: static_app)

      text = RailsAiContext::Tools::GetSchema.call(detail: "summary").content.first[:text]

      expect(text).to include("**Adapter:** PostgreSQL by database.yml default\n")
    end
  end
end

module AppDatabasesTiers
  # Runs the block against the fixture at `root` on one tier, in the test environment.
  def on_tier(tier, root, connected: nil)
    previous = [ RailsAiContext.tier, ENV.fetch("RAILS_ENV", nil) ]
    ENV["RAILS_ENV"] = "test"
    if tier == :static
      RailsAiContext.tier = :static
    else
      configurations = ActiveRecord::DatabaseConfigurations.new(YAML.safe_load_file(File.join(root, "config/database.yml"), aliases: true))
      own = configurations.configs_for(env_name: "test")
      allow(ActiveRecord::Base).to receive_messages(configurations: configurations,
                                                    connection_db_config: own.find { |config| config.name == connected } || own.first)
      allow(Rails).to receive(:root).and_return(Pathname.new(root))
    end
    RailsAiContext::RunCache.around { yield }
  ensure
    RailsAiContext.tier = previous.first
    ENV["RAILS_ENV"] = previous.last
  end
end

# Rails names db/schema.rb as the dump of the first database and of the one named primary.
RSpec.describe "an app whose first database is not the one named primary" do
  include AppDatabasesTiers

  let(:root) { File.expand_path("../../fixtures/app_databases/animals_first", __dir__) }
  let(:app) { RailsAiContext::StaticApp.new(root) }

  %i[booted static].each do |tier|
    it "counts each finding of the shared dump once in the performance check on the #{tier} tier" do
      on_tier(tier, root) do
        performance = RailsAiContext::Introspectors::PerformanceIntrospector.new(app).call

        expect(performance[:missing_fk_indexes]).to eq([ { table: "posts", column: "user_id", suggestion: "add_index :posts, :user_id" } ])
        expect(performance).not_to have_key(:unchecked_databases)
      end
    end

    it "says whose dump db/schema.rb is read as, and sends a migration to the database named primary, on the #{tier} tier" do
      on_tier(tier, root) do
        schema = RailsAiContext::Introspectors::SchemaIntrospector.new(app).static_call
        allow(RailsAiContext::Tools::MigrationAdvisor).to receive_messages(cached_context: { models: {}, schema: schema }, rails_app: app)
        advice = RailsAiContext::Tools::MigrationAdvisor.call(action: "add_column", table: "orders", column: "state", type: "string").content.first[:text]

        expect(schema[:secondary_databases].keys).to eq(%w[primary])
        expect(schema.dig(:secondary_databases, "primary", :note))
          .to eq("Reconstructed from the migrations in db/primary_migrate (no DB connection, db/schema.rb is read as the animals database's dump)")
        expect(advice).to include("`orders` is in primary: generate with `--database primary`",
                                  "**Run:** `bin/rails generate migration AddStateToOrders state:string --database primary`")
      end
    end

    it "advises on a table of the database named primary by that database's family and with no row count of the first database, on the #{tier} tier" do
      on_tier(tier, root) do
        schema = RailsAiContext::Introspectors::SchemaIntrospector.new(app).static_call
        context = { models: {}, schema: schema.merge(adapter: "postgresql"), database_stats: { tables: [ { table: "orders", approximate_rows: 5 } ] } }
        allow(RailsAiContext::Tools::MigrationAdvisor).to receive_messages(cached_context: context, rails_app: app)
        index = RailsAiContext::Tools::MigrationAdvisor.call(action: "add_index", table: "orders", column: "state").content.first[:text]
        column = RailsAiContext::Tools::MigrationAdvisor.call(action: "add_column", table: "orders", column: "state", type: "string", options: "null: false")
                                                        .content.first[:text]

        expect(index).to include("**Note:** MySQL/MariaDB add indexes to InnoDB tables via online DDL by default")
        expect(column).to include("`null: false` without a default fails if `orders` holds any rows")
      end
    end

    it "tells the generated files the first database's own name on the #{tier} tier" do
      on_tier(tier, root) do
        expect(RailsAiContext::Introspectors::MultiDatabaseIntrospector.new(app).call[:primary_name]).to eq("animals")
      end
    end
  end
end

# The sql format with a secondary whose only dump is queue_schema.rb, and a database_tasks: false entry with a committed dump.
RSpec.describe "a dump on disk under a database's name" do
  include AppDatabasesTiers

  let(:root) { File.expand_path("../../fixtures/app_databases/fallback_dump", __dir__) }
  let(:app) { RailsAiContext::StaticApp.new(root) }

  %i[booted static].each do |tier|
    it "is read by the schema section and rails_get_schema on the #{tier} tier" do
      on_tier(tier, root) do
        schema = RailsAiContext::Introspectors::SchemaIntrospector.new(app).static_call
        allow(RailsAiContext::Tools::GetSchema).to receive_messages(cached_context: { schema: schema }, rails_app: app)
        text = RailsAiContext::Tools::GetSchema.call(detail: "summary").content.first[:text]

        expect(schema[:tables].keys).to eq(%w[users])
        expect(schema[:secondary_databases].transform_values { |db| [ db[:tables].keys, db[:dump] ] })
          .to eq("queue" => [ %w[jobs], "db/queue_schema.rb" ], "legacy" => [ %w[legacy_orders], "db/legacy_schema.rb" ])
        expect(text).to include("jobs").and include("legacy_orders")
      end
    end

    it "is read by the model introspector and the performance check on the #{tier} tier" do
      on_tier(tier, root) do
        tables = RailsAiContext::Introspectors::ModelIntrospector.new(app).send(:secondary_dump_tables)
        performance = RailsAiContext::Introspectors::PerformanceIntrospector.new(app).call

        expect(tables).to eq(Set["jobs", "legacy_orders"])
        expect(performance[:missing_fk_indexes].map { |f| f.values_at(:database, :table, :column) })
          .to contain_exactly(%w[queue jobs user_id], %w[legacy legacy_orders user_id])
        expect(performance).not_to have_key(:unchecked_databases)
      end
    end
  end
end

# `preset: standard` runs no multi_database section.
RSpec.describe "the app databases where the payload holds no multi_database section" do
  around do |example|
    config = RailsAiContext.configuration
    previous = [ RailsAiContext.tier, ENV.fetch("RAILS_ENV", nil), config.introspectors, config.app_root ]
    RailsAiContext.tier = :static
    ENV["RAILS_ENV"] = "test"
    config.introspectors = RailsAiContext::Configuration::PRESETS[:standard].dup
    example.run
  ensure
    RailsAiContext.tier, ENV["RAILS_ENV"], config.introspectors, config.app_root = previous
  end

  def answers(fixture)
    root = File.expand_path("../../fixtures/app_databases/#{fixture}", __dir__)
    RailsAiContext.configuration.app_root = root
    RailsAiContext::RunCache.around do
      context = RailsAiContext::Introspector.new(RailsAiContext::StaticApp.new(root)).call
      tools = [ RailsAiContext::Tools::GetSchema, RailsAiContext::Tools::Onboard ]
      tools.each { |tool| allow(tool).to receive_messages(cached_context: context) }
      { context: context, schema: tools.first.call(detail: "summary").content.first[:text],
        onboard: tools.last.call(detail: "standard").content.first[:text],
        file: RailsAiContext::Serializers::MarkdownSerializer.new(context).call }
    end
  end

  it "marks the databases only production configures in rails_get_schema, rails_onboard and the generated file" do
    found = answers("rails8")

    expect(found[:context]).not_to have_key(:multi_database)
    expect(found[:schema]).to include("- **cache** (production only): 1 table", "- **queue** (production only): 1 table")
    expect(found[:onboard]).to include("databases of their own: cache (production only), queue (production only), cable (production only).")
    expect(found[:file]).to include("cable (production only): Solid Cable (1 table)", "- queue (production only): 1 total, 0 pending in db/queue_migrate")
  end

  it "names the first database by its own name where another database is named primary" do
    found = answers("animals_first")

    expect(found[:onboard]).to include("plus the primary database on MySQL (1 table).")
    expect(found[:file]).to include("## Database Schema: animals (2 tables)", "## Database Schema: primary (1 table)", "- Total: 0 (animals)")
  end
end
