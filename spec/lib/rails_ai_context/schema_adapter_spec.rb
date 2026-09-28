# frozen_string_literal: true

require "spec_helper"

# Four call sites each grew their own substitute for `static_parse` and gave
# three different answers for one app. These examples pin the single answer.
RSpec.describe RailsAiContext::SchemaAdapter do
  describe ".label" do
    it "passes an observed adapter through untouched" do
      expect(described_class.label({ schema: { adapter: "PostgreSQL" } })).to eq("PostgreSQL")
    end

    it "never returns the internal marker" do
      expect(described_class.label({ schema: { adapter: "static_parse" } })).not_to include("static_parse")
    end

    # The app's own database config needs no connection and is not a guess,
    # so it outranks both the dialect and the Gemfile.
    it "prefers the app's configured adapter" do
      context = {
        schema: { adapter: "static_parse", dialect: "sqlite" },
        multi_database: { databases: [ { name: "primary", adapter: "postgresql" } ] },
        gems: { notable_gems: [ { name: "sqlite3" } ] }
      }
      expect(described_class.label(context)).to eq("PostgreSQL")
    end

    # MultiDatabaseIntrospector reports ActiveRecord adapter names, not gem
    # names. Feeding this example "pg" - a name no introspector emits here -
    # is why the first version passed while a real Postgres app rendered
    # "Database: postgresql".
    it "uses the ActiveRecord adapter names the introspector actually emits" do
      {
        "postgresql" => "PostgreSQL",
        "mysql2" => "MySQL",
        "trilogy" => "MySQL",
        "sqlite3" => "SQLite"
      }.each do |configured, shown|
        context = {
          schema: { adapter: "static_parse" },
          multi_database: { databases: [ { name: "primary", adapter: configured } ] }
        }
        expect(described_class.label(context)).to eq(shown)
      end
    end

    it "passes an adapter it does not recognise through rather than losing it" do
      context = {
        schema: { adapter: "static_parse" },
        multi_database: { databases: [ { name: "primary", adapter: "oracle_enhanced" } ] }
      }
      expect(described_class.label(context)).to eq("oracle_enhanced")
    end

    it "falls back to the structure.sql dialect" do
      context = {
        schema: { adapter: "static_parse", dialect: "postgresql" },
        gems: { notable_gems: [ { name: "sqlite3" } ] }
      }
      expect(described_class.label(context)).to eq("PostgreSQL")
    end

    it "falls back to the Gemfile last" do
      context = { schema: { adapter: "static_parse" }, gems: { notable_gems: [ { name: "trilogy" } ] } }
      expect(described_class.label(context)).to eq("MySQL")
    end

    # onboard let the last gem match win, the serializer let the first win, so
    # one app with two adapter gems got two answers. Order must not decide it.
    it "answers the same however the gem list is ordered" do
      forward = { schema: { adapter: "static_parse" }, gems: { notable_gems: [ { name: "pg" }, { name: "sqlite3" } ] } }
      reverse = { schema: { adapter: "static_parse" }, gems: { notable_gems: [ { name: "sqlite3" }, { name: "pg" } ] } }
      expect(described_class.label(forward)).to eq(described_class.label(reverse))
      expect(described_class.label(forward)).to eq("PostgreSQL or SQLite")
    end

    # Huginn bundles pg and mysql2 and runs on MySQL. Picking whichever gem
    # came first in a constant named PostgreSQL in every generated file.
    it "refuses to pick between two adapter gems and names them" do
      context = { schema: { adapter: "static_parse" }, gems: { notable_gems: [ { name: "pg" }, { name: "mysql2" } ] } }
      expect(described_class.label(context)).to eq("PostgreSQL or MySQL")
    end

    it "still answers when two gems mean the same database" do
      context = { schema: { adapter: "static_parse" }, gems: { notable_gems: [ { name: "mysql2" }, { name: "trilogy" } ] } }
      expect(described_class.label(context)).to eq("MySQL")
    end

    # An adapter the file computes in ERB with one literal fallback is what
    # the app runs on with the env var unset, which is worth saying - as a
    # default, not as an observation.
    it "marks a configured adapter that came from an ERB default" do
      context = {
        schema: { adapter: "static_parse" },
        multi_database: { databases: [ { name: "primary", adapter: "mysql2", adapter_default: true } ] }
      }
      expect(described_class.label(context)).to eq("MySQL by database.yml default")
    end

    # The schema tool's Adapter line has room for the reason; a sentence
    # mid-paragraph does not.
    it "adds the reason where a surface has room for it" do
      context = { schema: { adapter: "static_parse" }, multi_database: { databases: [ { name: "primary", adapter: nil } ] },
                  gems: { notable_gems: [ { name: "mysql2" }, { name: "sqlite3" } ] } }
      expect(described_class.label_with_reason(context)).to eq("MySQL or SQLite, database.yml does not say which")
    end

    # Plots2 commits no database.yml: its five example files name both.
    it "says the example files name each when that is where the candidates came from" do
      context = { schema: { adapter: "static_parse" }, multi_database: { databases: [], example_adapters: %w[mysql2 sqlite3] } }
      expect(described_class.label_with_reason(context)).to eq("MySQL or SQLite, its database.yml examples name each")
    end

    it "blames no file the app does not have" do
      context = { schema: { adapter: "static_parse" }, multi_database: { databases: [] },
                  gems: { notable_gems: [ { name: "pg" }, { name: "mysql2" } ] } }
      expect(described_class.label_with_reason(context)).to eq("PostgreSQL or MySQL, the app does not say which")
    end

    it "adds no reason to an adapter it could decide" do
      context = { schema: { adapter: "PostgreSQL" } }
      expect(described_class.label_with_reason(context)).to eq("PostgreSQL")
    end

    # Canvas commits no database.yml and bundles pg and sqlite3, but its
    # database.yml.example says postgresql and its tables have jsonb columns.
    describe "evidence before the gem list" do
      let(:two_gems) { { notable_gems: [ { name: "pg" }, { name: "sqlite3" } ] } }

      it "reads the adapter a database.yml example names" do
        context = { schema: { adapter: "static_parse" }, multi_database: { databases: [], example_adapters: %w[postgresql] }, gems: two_gems }
        expect(described_class.label(context)).to eq("PostgreSQL")
      end

      it "names every adapter the example files name, when they name several" do
        context = { schema: { adapter: "static_parse" }, multi_database: { databases: [], example_adapters: %w[sqlite3 mysql2] }, gems: two_gems }
        expect(described_class.label(context)).to eq("MySQL or SQLite")
      end

      it "reads PostgreSQL from column types only it has" do
        tables = { "courses" => { columns: [ { name: "settings", type: "jsonb" } ] } }
        context = { schema: { adapter: "static_parse", tables: tables }, gems: two_gems }
        expect(described_class.label(context)).to eq("PostgreSQL")
      end

      it "reads PostgreSQL from an array column" do
        tables = { "courses" => { columns: [ { name: "tags", type: "string", array: true } ] } }
        context = { schema: { adapter: "static_parse", tables: tables }, gems: two_gems }
        expect(described_class.label(context)).to eq("PostgreSQL")
      end

      # An example file is a setup hint, often SQLite for convenience; a jsonb
      # column is proof of the database the schema was dumped from.
      it "lets column types only one database has outrank an example file" do
        tables = { "courses" => { columns: [ { name: "settings", type: "jsonb" } ] } }
        context = { schema: { adapter: "static_parse", tables: tables },
                    multi_database: { databases: [], example_adapters: %w[sqlite3] }, gems: two_gems }
        expect(described_class.label(context)).to eq("PostgreSQL")
      end

      it "lets a structure.sql dialect outrank the column types" do
        tables = { "courses" => { columns: [ { name: "notes", type: "mediumtext" } ] } }
        context = { schema: { adapter: "static_parse", dialect: "postgresql", tables: tables }, gems: two_gems }
        expect(described_class.label(context)).to eq("PostgreSQL")
      end

      # activerecord-postgis-adapter names its adapter postgis; it is PostgreSQL.
      it "reads the postgis adapter as PostgreSQL" do
        context = { schema: { adapter: "static_parse" }, multi_database: { databases: [], example_adapters: %w[postgis] } }
        expect(described_class.label(context)).to eq("PostgreSQL")
        configured = { schema: { adapter: "static_parse" }, multi_database: { databases: [ { name: "primary", adapter: "postgis" } ] } }
        expect(described_class.label(configured)).to eq("PostgreSQL")
      end

      it "leaves column types that point both ways to the gem list" do
        tables = { "a" => { columns: [ { name: "x", type: "jsonb" }, { name: "y", type: "mediumtext" } ] } }
        context = { schema: { adapter: "static_parse", tables: tables }, gems: two_gems }
        expect(described_class.label(context)).to eq("PostgreSQL or SQLite")
      end
    end

    it "says unknown when nothing can resolve it" do
      expect(described_class.label({ schema: { adapter: "static_parse" } })).to eq("unknown")
    end

    it "survives an unusable section" do
      context = { schema: { adapter: nil }, multi_database: { error: "boom" }, gems: { error: "boom" } }
      expect(described_class.label(context)).to eq("unknown")
    end

    it "survives a context that is not a Hash" do
      expect(described_class.label(nil)).to eq("unknown")
    end
  end
end
