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
        multi_database: { databases: [ { name: "primary", adapter: "pg" } ] },
        gems: { notable_gems: [ { name: "sqlite3" } ] }
      }
      expect(described_class.label(context)).to eq("PostgreSQL")
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
