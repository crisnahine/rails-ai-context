# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::PgNaming do
  describe ".extension_name" do
    it "qualifies an extension outside the current schema from Rails 8.0" do
      expect(described_class.extension_name("pg_trgm", "app", %w[app public], "8.0.5")).to eq("pg_trgm")
      expect(described_class.extension_name("hstore", "public", %w[app public], "8.0.5")).to eq("public.hstore")
      expect(described_class.extension_name("plpgsql", "pg_catalog", %w[public], "8.1.4")).to eq("pg_catalog.plpgsql")
    end

    it "names every extension bare before Rails 8.0" do
      expect(described_class.extension_name("hstore", "public", %w[app public], "7.2.4")).to eq("hstore")
      expect(described_class.extension_name("plpgsql", "pg_catalog", %w[public], "7.0.10")).to eq("plpgsql")
    end

    it "names an extension the dump gives no schema bare" do
      expect(described_class.extension_name("hstore", nil, %w[public], "8.1.4")).to eq("hstore")
    end
  end

  describe ".enum_list" do
    let(:enums) { { "app.status" => %w[on], "public.mood" => %w[happy], "audit.level" => %w[low] } }

    it "lists the search path's types from Rails 7.1, bare in the current schema" do
      expect(described_class.enum_list(enums, %w[app public], "7.1.6"))
        .to eq([ { name: "public.mood", values: %w[happy] }, { name: "status", values: %w[on] } ])
    end

    it "lists every type by its bare name on Rails 7.0, the first of a shared name winning" do
      list = described_class.enum_list(enums.merge("public.status" => %w[x]), %w[app public], "7.0.10")

      expect(list.map { |e| e[:name] }).to eq(%w[level mood status])
      expect(list.last[:values]).to eq(%w[on])
    end

    it "keeps a bare name as it is" do
      expect(described_class.enum_list({ "mood" => %w[happy] }, %w[app public], "7.2.4").map { |e| e[:name] }).to eq(%w[mood])
    end
  end

  describe ".names" do
    let(:names) do
      described_class.names(%w[app public], relations: %w[app.users public.users public.posts audit.events], types: %w[app.mood public.mood public.level])
    end

    it "names a relation bare when the first search path schema holding its name is its own" do
      expect(names.relation("app.users")).to eq("users")
      expect(names.relation("public.posts")).to eq("posts")
    end

    it "keeps the qualified name of a relation the path hides or does not reach" do
      expect(names.relation("public.users")).to eq("public.users")
      expect(names.relation("audit.events")).to eq("audit.events")
      expect(names.relation("users")).to eq("users")
    end

    it "names a type the same way, from the types alone" do
      expect(names.type("app.mood")).to eq("mood")
      expect(names.type("public.mood")).to eq("public.mood")
      expect(names.type("public.level")).to eq("level")
    end
  end

  describe ".existing_path" do
    it "drops a schema the dump never creates, public assumed" do
      expect(described_class.existing_path(%w[deploy app public], %w[app])).to eq(%w[app public])
    end
  end

  describe "the schema.rb dumper's rules" do
    it "qualifies names in a schema.rb only from Rails 8.1" do
      expect(described_class.dump_qualifies_names?("8.1.4")).to be(true)
      expect(described_class.dump_qualifies_names?("8.0.5.1")).to be(false)
      expect(described_class.dump_qualifies_names?(nil)).to be(true)
    end

    it "places a bare name in its schema from Rails 8.1, or on a one-schema search path" do
      expect(described_class.dump_places_names?("8.1.4", %w[app public])).to be(true)
      expect(described_class.dump_places_names?("8.0.5.1", %w[public])).to be(true)
      expect(described_class.dump_places_names?("8.0.5.1", %w[app public])).to be(false)
    end

    it "writes create_schema from Rails 7.1" do
      expect(described_class.dump_lists_schemas?("7.1.6")).to be(true)
      expect(described_class.dump_lists_schemas?("7.0.10")).to be(false)
    end
  end

  describe ".missing_from_schema_rb" do
    it "says a Rails 8.1 schema.rb holding only the search path schemas leaves another schema out" do
      note = described_class.missing_from_schema_rb("audit.events", %w[app public], %w[app], "8.1.4", "db/schema.rb")

      expect(note).to include("If schema 'audit' exists, db/schema.rb leaves it out")
      expect(note).to include("`config.active_record.dump_schemas = :all`")
      # With schema_search_path set, structure.sql leaves it out as well (postgresql_database_tasks.rb:49-67).
      expect(note).not_to include("structure.sql")
    end

    it "says nothing before Rails 8.1, whose dumper writes every schema" do
      expect(described_class.missing_from_schema_rb("audit.events", %w[public], [], "8.0.5.1", "db/schema.rb")).to be_nil
      expect(described_class.missing_from_schema_rb("audit.events", %w[public], [], "7.0.10", "db/schema.rb")).to be_nil
    end

    it "says nothing for a schema the dump holds, or one on the search path" do
      expect(described_class.missing_from_schema_rb("app.events", %w[app public], %w[app], "8.1.4", "db/schema.rb")).to be_nil
      expect(described_class.missing_from_schema_rb("public.events", %w[app public], %w[app], "8.1.4", "db/schema.rb")).to be_nil
    end

    it "says nothing when the dump holds a schema off the search path, so dump_schemas is set" do
      expect(described_class.missing_from_schema_rb("audit.events", %w[app public], %w[app billing], "8.1.4", "db/schema.rb")).to be_nil
    end
  end

  describe ".enums_used" do
    let(:list) { [ { name: "mood", values: %w[happy sad] }, { name: "public.mood", values: %w[meh] } ] }

    it "pairs a bare column type with the first search path schema holding it" do
      expect(described_class.enums_used(list, %w[mood], %w[app public])).to eq([ list.first ])
      expect(described_class.enums_used(list, %w[public.mood], %w[app public])).to eq([ list.last ])
    end

    it "keys a bare list name by public when no search path is known" do
      expect(described_class.enums_used([ { name: "mood", values: %w[x] } ], %w[mood], nil)).to eq([ { name: "mood", values: %w[x] } ])
    end
  end

  describe ".rails_version" do
    def root_locking(rails)
      dir = Dir.mktmpdir
      File.write(File.join(dir, "Gemfile"), "gem \"rails\"\n")
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (#{rails})\n\nDEPENDENCIES\n  rails\n")
      dir
    end

    it "reads the lockfile without a boot" do
      RailsAiContext.tier = :static
      dir = root_locking("7.2.4")
      expect(described_class.rails_version(dir)).to eq("7.2.4")
    ensure
      RailsAiContext.tier = nil
      FileUtils.rm_rf(dir) if dir
    end

    it "reads the running Rails when booted" do
      dir = root_locking("7.2.4")
      expect(described_class.rails_version(dir)).to eq(Rails.version)
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
