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

# Rails dumps both the first database and the one named primary to db/schema.rb,
# so the file holds whichever was dumped last.
RSpec.describe "two databases that share db/schema.rb" do
  include AppDatabasesTiers

  let(:posts) { { "posts" => { columns: [], indexes: [], foreign_keys: [] } } }
  let(:main_and_primary) do
    <<~YAML
      test:
        main:
          adapter: sqlite3
          database: db/main.sqlite3
        primary:
          adapter: sqlite3
          database: db/primary.sqlite3
    YAML
  end

  # A rails_get_schema answer for an app booted on its first database, main, whose db/schema.rb declares zz_events.
  def schema_answer(database_yml, live, **args)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "db"))
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config", "database.yml"), database_yml)
      File.write(File.join(root, "db", "schema.rb"),
                 "ActiveRecord::Schema[8.0].define(version: 1) do\n  create_table \"zz_events\" do |t|\n  end\nend\n")
      app = RailsAiContext::StaticApp.new(root)
      ActiveRecord::Base.connection.execute("SELECT 1")
      on_tier(:booted, root, connected: "main") do
        introspector = RailsAiContext::Introspectors::SchemaIntrospector.new(app)
        allow(introspector).to receive_messages(table_names: live.keys, extract_tables: live) if live
        allow(RailsAiContext::Tools::GetSchema).to receive_messages(cached_context: { schema: introspector.call }, rails_app: app)
        RailsAiContext::Tools::GetSchema.call(**args).content.first[:text]
      end
    end
  end

  it "says the dump may describe the other database, and calls no table of it missing" do
    note = "main and primary both dump to db/schema.rb, so it may describe primary. Not in main: zz_events."
    no_migrate = satisfy { |text| !text.include?("rails db:migrate") }

    [ nil, posts ].each { |live| expect(schema_answer(main_and_primary, live, detail: "summary")).to include("_#{note}_").and(no_migrate) }
    expect(schema_answer(main_and_primary, posts, table: "zz_events")).to eq("Table 'zz_events' is declared in db/schema.rb. #{note}")
  end

  it "shares nothing with a database another environment configures" do
    other_environment = <<~YAML
      test:
        main:
          adapter: sqlite3
          database: db/main.sqlite3
      development:
        main:
          adapter: sqlite3
          database: db/main_dev.sqlite3
        primary:
          adapter: sqlite3
          database: db/primary.sqlite3
    YAML

    expect(schema_answer(other_environment, posts, detail: "summary"))
      .to include("Missing: zz_events. Run `rails db:migrate`.").and(satisfy { |text| !text.include?("both dump to") })
  end
end

# `preset: standard` runs no multi_database introspector; the context carries the app databases list alone.
RSpec.describe "the app databases on preset standard" do
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

    expect(found[:context][:multi_database].keys).to contain_exactly(:databases)
    expect(found[:schema]).to include("- **cache** (production only): 1 table", "- **queue** (production only): 1 table")
    expect(found[:onboard]).to include("databases of their own: cache (production only), queue (production only), cable (production only).")
    expect(found[:file]).to include("cable (production only): Solid Cable (1 table)", "- queue (production only): 1 total, 0 pending in db/queue_migrate")
  end

  it "keeps the marks on a preset whose multi_database introspector failed" do
    RailsAiContext.configuration.introspectors = RailsAiContext::Configuration::PRESETS[:full].dup
    allow_any_instance_of(RailsAiContext::Introspectors::MultiDatabaseIntrospector).to receive(:call).and_raise("boom")

    expect(answers("rails8")[:onboard]).to include("databases of their own: cache (production only), queue (production only)")
  end

  it "keeps every other section where listing the app databases raises" do
    allow_any_instance_of(RailsAiContext::Introspectors::MultiDatabaseIntrospector).to receive(:listing).and_raise("boom")

    found = answers("rails8")
    expect(found[:context]).to include(:schema).and(satisfy { |context| !context.key?(:multi_database) })
    expect(found[:context][:_warnings]).to include({ introspector: "multi_database", error: "boom" })
    expect(found[:onboard]).to include("Rails application")
  end

  it "names a database with no dump, no migrations and no file, and says its tables were not read" do
    found = answers("missing_dump")

    expect(found[:onboard]).to include("(1 table), plus the extra database on SQLite (tables not read), plus the legacy database on SQLite (tables not read).")
    expect(found[:schema]).to include("- **extra**: Its tables are not listed: db/extra_schema.rb is not on disk\n",
                                      "- **legacy**: Its tables are not listed: its database.yml entry turns `database_tasks` off")
    expect(found[:file]).to include("_Its tables are not listed: db/extra_schema.rb is not on disk._\n")
    expect(found[:onboard] + found[:schema]).not_to include("extra_replica")
    rules = Dir.mktmpdir do |dir|
      RailsAiContext::Serializers::ClaudeRulesSerializer.new(found[:context]).call(dir)
      File.read(File.join(dir, ".claude/rules/rails-schema.md"))
    end
    # Only the primary has tables, so the listing needs no heading per database.
    expect(rules).to include("# Database Tables (1)").and(satisfy { |text| !text.include?("## primary") })
  end

  it "lists no database whose dump is the primary's, though that dump is not on disk" do
    found = answers("shared_dump_unread")

    expect(found[:onboard]).to include("Rails application on SQLite (1 table).")
    expect(found[:onboard] + found[:schema]).not_to include("tables not read")
  end

  it "names the first database by its own name where another database is named primary" do
    found = answers("animals_first")

    expect(found[:onboard]).to include("plus the primary database on MySQL (1 table).")
    expect(found[:file]).to include("## Database Schema: animals (2 tables)", "## Database Schema: primary (1 table)", "- Total: 0 (animals)")
  end

  it "names each database's adapter and lists the databases, as preset full does" do
    found = answers("animals_first")
    rules = Dir.mktmpdir do |dir|
      RailsAiContext::Serializers::ClaudeRulesSerializer.new(found[:context]).call(dir)
      %w[rails-schema rails-context].map { |name| File.read(File.join(dir, ".claude/rules/#{name}.md")) }.join
    end

    expect(found[:onboard]).to include("animals_first is a Rails application on PostgreSQL (2 tables), plus the primary database on MySQL (1 table).")
    expect(rules).to include("## animals (PostgreSQL, 2 tables)", "## primary (MySQL, 1 table)", "- Databases: 2 (animals, primary)")
  end
end

# The static tier reads db/schema.rb and knows which tables it declares.
RSpec.describe "a model whose table the schema dump does not declare, on the static tier" do
  around do |example|
    config = RailsAiContext.configuration
    previous = [ RailsAiContext.tier, config.introspectors, config.app_root ]
    RailsAiContext.tier = :static
    config.introspectors = RailsAiContext::Configuration::PRESETS[:standard].dup
    example.run
  ensure
    RailsAiContext.tier, config.introspectors, config.app_root = previous
  end

  it "says the table is missing from db/schema.rb for a model of the primary, and judges no other database" do
    Dir.mktmpdir do |root|
      { "config/application.rb" => "module Demo\n  class Application < Rails::Application\n  end\nend\n",
        "db/schema.rb" => "ActiveRecord::Schema[8.0].define(version: 1) do\n  create_table \"posts\" do |t|\n  end\n  create_table \"sdg_goals\" do |t|\n  end\nend\n",
        "app/models/sdg.rb" => "module SDG\n  def self.table_name_prefix\n    \"sdg_\"\n  end\nend\n",
        "app/models/sdg/goal.rb" => "class SDG::Goal < ApplicationRecord\nend\n",
        "app/models/legacy_record.rb" => "class LegacyRecord < ApplicationRecord\n  self.abstract_class = true\n  establish_connection :legacy\nend\n",
        "app/models/legacy_user.rb" => "class LegacyUser < LegacyRecord\nend\n",
        "app/models/ledger.rb" => "class Ledger < ApplicationRecord\n  establish_connection :legacy\nend\n",
        "app/models/report.rb" => "class Report < ApplicationRecord\n  self.table_name = \"reporting.reports\"\nend\n",
        "app/models/shard_record.rb" => "class ShardRecord < ApplicationRecord\n  self.abstract_class = true\n  connects_to shards: { default: { writing: :analytics } }\nend\n",
        "app/models/tenant.rb" => "class Tenant < ShardRecord\nend\n",
        "app/models/primary_record.rb" => "class PrimaryRecord < ApplicationRecord\n  self.abstract_class = true\n  connects_to database: { writing: :primary }\nend\n",
        "app/models/bookkeeping.rb" => "class Bookkeeping < PrimaryRecord\n  establish_connection :legacy\nend\n",
        "app/models/attachment.rb" => "class Attachment < ApplicationRecord\n  include Vendor::TableSetter\nend\n",
        "app/models/big_base.rb" => "class BigBase < ApplicationRecord\n  self.abstract_class = true\n#{"  # padding\n" * 400}end\n",
        "app/models/gadget.rb" => "class Gadget < BigBase\nend\n",
        "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
        "app/models/post.rb" => "class Post < ApplicationRecord\nend\n",
        "app/models/widget.rb" => "class Widget < ApplicationRecord\nend\n",
        "db/analytics_schema.rb" => "ActiveRecord::Schema[8.0].define(version: 1) do\n  create_table \"visits\" do |t|\n  end\nend\n",
        "app/models/analytics_record.rb" => "class AnalyticsRecord < ApplicationRecord\n  self.abstract_class = true\n  connects_to database: { writing: :analytics }\nend\n",
        "app/models/visit.rb" => "class Visit < AnalyticsRecord\nend\n",
        "app/models/event.rb" => "class Event < AnalyticsRecord\nend\n",
        "config/database.yml" => "test:\n  primary:\n    adapter: sqlite3\n    database: db/test.sqlite3\n  analytics:\n    adapter: sqlite3\n    database: db/analytics.sqlite3\n" \
                                 "  archive:\n    adapter: sqlite3\n    database: db/archive.sqlite3\n    migrations_paths: db/archive_migrate\n",
        "db/archive_migrate/20240101000000_create_records.rb" => "class CreateRecords < ActiveRecord::Migration[8.0]\n  def change\n    create_table :records\n  end\nend\n",
        "app/models/archive_record.rb" => "class ArchiveRecord < ApplicationRecord\n  self.abstract_class = true\n  connects_to database: { writing: :archive }\nend\n",
        "app/models/relic.rb" => "class Relic < ArchiveRecord\nend\n" }.each do |path, source|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), source)
      end
      RailsAiContext.configuration.app_root = root
      allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(2_000)
      texts = RailsAiContext::RunCache.around do
        context = RailsAiContext::Introspector.new(RailsAiContext::StaticApp.new(root)).call
        [ RailsAiContext::Tools::GetModelDetails, RailsAiContext::Tools::Onboard ].each { |tool| allow(tool).to receive_messages(cached_context: context) }
        [ RailsAiContext::Tools::GetModelDetails.call(model: "Widget"), RailsAiContext::Tools::GetModelDetails.call(model: "Post"),
          RailsAiContext::Tools::Onboard.call(detail: "standard"), RailsAiContext::Tools::GetModelDetails.call(model: "Event"),
          RailsAiContext::Tools::GetModelDetails.call(model: "Visit"),
          RailsAiContext::Tools::GetModelDetails.call(model: "Relic"), RailsAiContext::Tools::GetModelDetails.call(model: "SDG::Goal"),
          RailsAiContext::Tools::GetModelDetails.call(model: "LegacyUser"),
          RailsAiContext::Tools::GetModelDetails.call(model: "Ledger"),
          RailsAiContext::Tools::GetModelDetails.call(model: "Report"),
          RailsAiContext::Tools::GetModelDetails.call(model: "Tenant"), RailsAiContext::Tools::GetModelDetails.call(model: "Bookkeeping"),
          RailsAiContext::Tools::GetModelDetails.call(model: "Attachment"),
          RailsAiContext::Tools::GetModelDetails.call(model: "Gadget") ].map { |response| response.content.first[:text] }
      end

      widget, post, onboard, event, visit, relic, goal, legacy_user, ledger, report, tenant, bookkeeping, attachment, gadget = texts
      # The static tier cannot always tell which database a model writes to, so only the primary's dump is judged.
      expect([ event, visit, tenant ]).to all(include("**Table:** `").and(satisfy { |text| !text.include?("missing from") }))
      expect(widget).to include("**Table:** `widgets` missing from db/schema.rb").and(satisfy { |text| !text.include?('table:"widgets"') })
      expect(post).to include("**Table:** `posts`", 'rails_get_schema(table:"posts")').and(satisfy { |text| !text.include?("missing from") })
      expect(onboard).not_to include("missing from db/analytics")
      # A replay can miss a table raw SQL creates, so the migrations are never named as leaving one out.
      expect(relic).to include("**Table:** `relics`").and(satisfy { |text| !text.include?("missing from") })
      expect(goal).to include("**Table:** `sdg_goals`").and(satisfy { |text| !text.include?("missing from") })
      # A connection of its own reads a database no dump here names.
      # The nearest establish_connection wins over a base's connects_to, as in Rails.
      expect([ legacy_user, ledger, bookkeeping ]).to all(include("**Table:** `").and(satisfy { |text| !text.include?("missing from") }))
      # A concern or base the static tier could not read may set the table name.
      expect(attachment).to include("**Table:** `attachments`", "Vendor::TableSetter").and(satisfy { |text| !text.include?("missing from") })
      expect(gadget).to include("**Table:** `big_bases`", "BigBase").and(satisfy { |text| !text.include?("missing from") })
      # schema.rb holds only the search path's tables, so it says nothing of another schema's.
      expect(report).to include("**Table:** `reporting.reports`").and(satisfy { |text| !text.include?("missing from") })
    end
  end

  def static_answers(files, models)
    Dir.mktmpdir do |root|
      { "config/application.rb" => "module Demo\n  class Application < Rails::Application\n  end\nend\n",
        "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
        "db/schema.rb" => "ActiveRecord::Schema[8.0].define(version: 1) do\n  create_table \"posts\" do |t|\n  end\nend\n" }.merge(files).compact.each do |path, source|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), source)
      end
      RailsAiContext.configuration.app_root = root
      RailsAiContext::RunCache.around do
        context = RailsAiContext::Introspector.new(RailsAiContext::StaticApp.new(root)).call
        allow(RailsAiContext::Tools::GetModelDetails).to receive_messages(cached_context: context)
        models.to_h { |name| [ name, RailsAiContext::Tools::GetModelDetails.call(model: name).content.first[:text] ] }
      end
    end
  end

  it "judges no table name a setting shapes that the static tier could not read, nor tables read from the migrations", :aggregate_failures do
    answers = [
      static_answers({ "app/models/sdg.rb" => "module SDG\n  def self.table_name_prefix\n    ENV.fetch(\"P\", \"sdg_\")\n  end\nend\n",
                       "app/models/sdg/goal.rb" => "class SDG::Goal < ApplicationRecord\nend\n" }, [ "SDG::Goal" ]),
      static_answers({ "app/models/widget.rb" => "class Widget < ApplicationRecord\n  self.pluralize_table_names = ENV[\"X\"] == \"1\"\nend\n" }, [ "Widget" ]),
      static_answers({ "app/models/gizmo.rb" => "class Gizmo < ApplicationRecord\n  self.table_name = ENV.fetch(\"T\", \"gizmos\")\nend\n" }, [ "Gizmo" ]),
      static_answers({ "config/initializers/prefix.rb" => "ActiveRecord::Base.table_name_prefix = ENV.fetch(\"P\", \"\")\n",
                       "app/models/thing.rb" => "class Thing < ApplicationRecord\nend\n" }, [ "Thing" ]),
      static_answers({ "db/schema.rb" => nil, "app/models/relic.rb" => "class Relic < ApplicationRecord\nend\n",
                       "db/migrate/20240101000000_create_posts.rb" => "class CreatePosts < ActiveRecord::Migration[8.0]\n  def change\n    create_table :posts\n  end\nend\n" },
                     [ "Relic" ]),
      static_answers({ "app/models/base_thing.rb" => "class BaseThing < ApplicationRecord\n  self.table_name = ENV.fetch(\"T\", \"base_things\")\nend\n",
                       "app/models/gadget.rb" => "class Gadget < BaseThing\nend\n" }, [ "Gadget" ]),
      static_answers({ "app/models/base_record.rb" => "class BaseRecord < ApplicationRecord\n  self.abstract_class = true\n  self.table_name_prefix = ENV.fetch(\"P\", \"\")\nend\n",
                       "app/models/piece.rb" => "class Piece < BaseRecord\nend\n" }, [ "Piece" ])
    ].reduce(:merge)

    # A table a computed setting shapes is named by that setting, never guessed; one read from the migrations is not judged.
    set_by = { "SDG::Goal" => "SDG.table_name_prefix", "Widget" => "Widget.pluralize_table_names", "Gizmo" => "Gizmo.table_name",
               "Thing" => "ActiveRecord::Base.table_name_prefix", "Gadget" => "BaseThing.table_name", "Piece" => "BaseRecord.table_name_prefix" }
    expect(answers.transform_values { |text| text[/^\*\*Table:\*\* .*$/] })
      .to eq(set_by.transform_values { |setting| "**Table:** set by `#{setting}`, which the static tier did not read" }.merge("Relic" => "**Table:** `relics`"))

    # The innermost module that declares the prefix decides it, and a literal table_name needs no prefix.
    judged = static_answers({ "app/models/outer.rb" => "module Outer\n  def self.table_name_prefix\n    ENV.fetch(\"P\", \"o_\")\n  end\nend\n",
                              "app/models/outer/inner.rb" => "module Outer::Inner\n  def self.table_name_prefix\n    \"in_\"\n  end\nend\n",
                              "app/models/outer/inner/item.rb" => "class Outer::Inner::Item < ApplicationRecord\nend\n",
                              "app/models/outer/fixed.rb" => "class Outer::Fixed < ApplicationRecord\n  self.table_name = \"fixed_items\"\nend\n" },
                            [ "Outer::Inner::Item", "Outer::Fixed" ])
    expect(judged.values.map { |text| text[/^\*\*Table:\*\* .*$/] })
      .to eq([ "**Table:** `in_items` missing from db/schema.rb", "**Table:** `fixed_items` missing from db/schema.rb" ])

    # A nearer literal affix decides over a computed one further out.
    nearer = [
      static_answers({ "config/initializers/prefix.rb" => "ActiveRecord::Base.table_name_prefix = ENV.fetch(\"P\", \"\")\n",
                       "app/models/admin.rb" => "module Admin\n  def self.table_name_prefix\n    \"admin_\"\n  end\nend\n",
                       "app/models/admin/widget.rb" => "class Admin::Widget < ApplicationRecord\nend\n" }, [ "Admin::Widget" ]),
      static_answers({ "app/models/base_record.rb" => "class BaseRecord < ApplicationRecord\n  self.abstract_class = true\n  self.table_name_prefix = ENV.fetch(\"P\", \"\")\nend\n",
                       "app/models/part.rb" => "class Part < BaseRecord\n  self.table_name_prefix = \"x_\"\nend\n" }, [ "Part" ])
    ].reduce(:merge)
    expect(nearer.values.map { |text| text[/^\*\*Table:\*\* .*$/] })
      .to eq([ "**Table:** `admin_widgets` missing from db/schema.rb", "**Table:** `x_parts` missing from db/schema.rb" ])
  end

  it "says so in rails_onboard" do
    Dir.mktmpdir do |root|
      { "config/application.rb" => "module Demo\n  class Application < Rails::Application\n  end\nend\n",
        "db/schema.rb" => "ActiveRecord::Schema[8.0].define(version: 1) do\n  create_table \"posts\" do |t|\n  end\n  create_table \"sdg_goals\" do |t|\n  end\nend\n",
        "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
        "app/models/post.rb" => "class Post < ApplicationRecord\nend\n",
        "app/models/sdg.rb" => "module SDG\n  def self.table_name_prefix\n    \"sdg_\"\n  end\nend\n",
        "app/models/sdg/goal.rb" => "class SDG::Goal < ApplicationRecord\nend\n",
        "app/models/widget.rb" => "class Widget < ApplicationRecord\nend\n" }.each do |path, source|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), source)
      end
      RailsAiContext.configuration.app_root = root
      onboard = RailsAiContext::RunCache.around do
        context = RailsAiContext::Introspector.new(RailsAiContext::StaticApp.new(root)).call
        allow(RailsAiContext::Tools::Onboard).to receive_messages(cached_context: context)
        RailsAiContext::Tools::Onboard.call(detail: "standard").content.first[:text]
      end

      expect(onboard).to include("**Widget** (table `widgets` missing from db/schema.rb)", "**Post** (table: `posts`)", "**SDG::Goal** (table: `sdg_goals`)")
    end
  end
end
