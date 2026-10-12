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
