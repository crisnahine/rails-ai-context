# frozen_string_literal: true

require "spec_helper"

# A Rails 7.1 app with a SQLite analytics database, its own migrations_paths
# and its own dump, beside a PostgreSQL primary. Every generated file counted
# the primary's tables and migrations alone: "Migrations: 3 total" with 6 on disk.
RSpec.describe "database counts across every generated file" do
  let(:context) do
    serializer_context(
      schema: {
        adapter: "postgresql", total_tables: 1, tables: { "users" => { columns: [ { name: "id" } ] } },
        secondary_databases: { "analytics" => { adapter: "static_parse", total_tables: 2, tables: { "events" => {}, "page_views" => {} } } }
      },
      multi_database: { databases: [ { name: "primary", adapter: "postgresql" }, { name: "analytics", adapter: "sqlite3" } ] },
      migrations: {
        total: 1, pending: [],
        secondary_databases: { "analytics" => { total: 3, pending: [ { version: "20261009141117", name: "AddBrowserToPageViews" } ] } }
      }
    )
  end

  let(:database_line) { "- Database: PostgreSQL - 1 table; analytics: SQLite - 2 tables" }
  let(:migrations_line) { "- Migrations: 1 total, 0 pending; analytics: 3 total, 1 pending" }

  {
    "CLAUDE.md" => RailsAiContext::Serializers::ClaudeSerializer,
    "AGENTS.md" => RailsAiContext::Serializers::OpencodeSerializer,
    ".github/copilot-instructions.md" => RailsAiContext::Serializers::CopilotSerializer
  }.each do |file, klass|
    it "#{file} counts every database's tables and migrations" do
      expect(klass.new(context).call).to include(database_line, migrations_line)
    end
  end

  # The overview rule files, and .cursorrules, which CursorRulesSerializer writes too.
  {
    "ClaudeRulesSerializer" => RailsAiContext::Serializers::ClaudeRulesSerializer,
    "CursorRulesSerializer" => RailsAiContext::Serializers::CursorRulesSerializer,
    "CopilotInstructionsSerializer" => RailsAiContext::Serializers::CopilotInstructionsSerializer
  }.each do |name, klass|
    it "#{name} counts every database's tables the same way" do
      Dir.mktmpdir do |dir|
        written = klass.new(context).call(dir)[:written]

        expect(written.map { |f| File.read(f) }.join("\n")).to include(database_line)
      end
    end
  end
end
