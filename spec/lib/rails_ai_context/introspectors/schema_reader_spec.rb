# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SchemaReader do
  def reader_for(source, **options)
    path = File.join(Dir.tmpdir, "rac_schema_reader_#{rand(1_000_000)}.rb")
    File.write(path, source)
    described_class.new(path, **options)
  ensure
    @paths ||= []
    @paths << path
  end

  after { @paths&.each { |p| FileUtils.rm_f(p) } }

  describe "#tables" do
    it "reads a table Rails 8.0 dumps once per search path schema holding it as one table" do
      reader = reader_for(<<~RUBY)
        ActiveRecord::Schema[8.0].define(version: 2024_01_01_000000) do
          create_table "users", force: :cascade do |t|
            t.text "tenant_column"
            t.index ["tenant_column"], name: "index_users_on_tenant_column"
          end

          create_table "users", force: :cascade do |t|
            t.text "tenant_column"
            t.index ["tenant_column"], name: "index_users_on_tenant_column"
          end
        end
      RUBY

      expect(reader.tables["users"][:columns].map { |c| c[:name] }).to eq(%w[tenant_column])
      expect(reader.tables["users"][:indexes].size).to eq(1)
    end

    it "groups columns under the table that declares them" do
      reader = reader_for(<<~RUBY)
        ActiveRecord::Schema[7.1].define(version: 2024_01_01_000000) do
          create_table "users", force: :cascade do |t|
            t.string "email"
            t.boolean "admin"
          end

          create_table "posts", force: :cascade do |t|
            t.string "title"
          end
        end
      RUBY

      expect(reader.tables.keys).to contain_exactly("users", "posts")
      expect(reader.tables["users"][:columns].map { |c| c[:name] }).to eq(%w[email admin])
      expect(reader.tables["posts"][:columns].map { |c| c[:name] }).to eq(%w[title])
    end

    it "records the declared column type" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.string "email"
          t.integer "age"
        end
      RUBY

      types = reader.tables["users"][:columns].to_h { |c| [ c[:name], c[:type] ] }
      expect(types).to eq({ "email" => "string", "age" => "integer" })
    end

    it "expands a reference into its foreign key column" do
      reader = reader_for(<<~RUBY)
        create_table "posts" do |t|
          t.references "author"
        end
      RUBY

      column = reader.tables["posts"][:columns].first
      expect(column[:name]).to eq("author_id")
      expect(column[:type]).to eq("references")
    end

    it "expands every name of one reference call" do
      reader = reader_for(<<~RUBY)
        create_table "posts" do |t|
          t.references "author", "editor"
          t.string "title", "slug"
        end
      RUBY

      expect(reader.tables["posts"][:columns].map { |c| c[:name] }).to eq(%w[author_id editor_id title slug])
    end

    it "marks a table whose block calls a method the reader does not read" do
      reader = reader_for(<<~RUBY)
        create_table "posts" do |t|
          t.bigint "account_id"
          t.replica_identity_index
        end
      RUBY

      expect(reader.tables["posts"][:unread_calls]).to eq(%w[replica_identity_index])
    end

    it "reads every column method the adapters and the vector and PostGIS gems define" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.citext "email", null: false
          t.enum "status", enum_type: "status_kind"
          t.int4range "ages"
          t.int8range "big_ages"
          t.tstzrange "during"
          t.bigserial "seq"
          t.geometry "shape"
          t.geography "area"
          t.st_point "loc", geographic: true
          t.multi_polygon "zones"
          t.vector "embedding", limit: 1536
          t.halfvec "half"
          t.mediumtext "body"
          t.unsigned_integer "hits"
          t.string "name", { limit: 50 }
          t.column_exists? "x"
          t.index_exists? "x"
          t.rename_index "a", "b"
        end
      RUBY

      table = reader.tables["users"]
      expect(table[:unread_calls]).to be_nil
      expect(table[:columns].map { |c| c[:name] }).to eq(%w[email status ages big_ages during seq shape area loc zones embedding half body hits name])
    end

    it "collects in-table indexes as column lists" do
      reader = reader_for(<<~RUBY)
        create_table "profiles" do |t|
          t.integer "user_id"
          t.boolean "primary"
          t.index [ "user_id", "primary" ], name: "idx_profiles"
          t.index [ "user_id" ]
        end
      RUBY

      expect(reader.tables["profiles"][:indexes].map { |i| i[:columns] }).to contain_exactly(
        %w[user_id primary], %w[user_id]
      )
    end

    it "attaches a top-level add_index to its named table" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.string "email"
        end

        add_index "users", [ "email" ], unique: true
      RUBY

      expect(reader.tables["users"][:indexes].map { |i| i[:columns] }).to eq([ %w[email] ])
    end

    it "ignores an add_index naming a table it never saw" do
      reader = reader_for('add_index "ghosts", ["name"]')

      expect(reader.tables).to be_empty
    end

    it "returns an empty hash when the file does not exist" do
      expect(described_class.new("/nonexistent/schema.rb").tables).to eq({})
    end

    it "survives a syntax-broken file" do
      reader = reader_for("create_table \"users\" do |t|\n  t.string(((")

      expect { reader.tables }.not_to raise_error
      expect(reader.tables).to be_a(Hash)
    end
  end

  describe "#defaults_for" do
    it "reads literal defaults" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.string "role", default: "member"
          t.integer "attempts", default: 0
          t.boolean "active", default: true
        end
      RUBY

      expect(reader.defaults_for("users")).to eq({
        "role" => "member", "attempts" => "0", "active" => "true"
      })
    end

    it "reads a default split across lines, which line matching missed" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.string "role",
                   null: false,
                   default: "member"
        end
      RUBY

      expect(reader.defaults_for("users")).to eq({ "role" => "member" })
    end

    it "reads a proc default as its source, which line matching skipped" do
      reader = reader_for(<<~RUBY)
        create_table "events" do |t|
          t.datetime "occurred_at", default: -> { "CURRENT_TIMESTAMP" }
        end
      RUBY

      expect(reader.defaults_for("events")).to eq({ "occurred_at" => '-> { "CURRENT_TIMESTAMP" }' })
    end

    it "treats an explicit nil default as no default" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.string "nickname", default: nil
          t.string "role", default: "member"
        end
      RUBY

      expect(reader.defaults_for("users")).to eq({ "role" => "member" })
    end

    it "omits columns with no default" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.string "email"
          t.string "role", default: "member"
        end
      RUBY

      expect(reader.defaults_for("users")).to eq({ "role" => "member" })
    end

    it "returns an empty hash for an unknown table" do
      reader = reader_for('create_table "users" do |t|; t.string "email"; end')

      expect(reader.defaults_for("orders")).to eq({})
    end
  end

  describe "column and index detail" do
    it "keeps the declared options on a column" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.string "email", null: false, comment: "login"
          t.string "tags", array: true
        end
      RUBY

      email, tags = reader.tables["users"][:columns]
      expect(email[:options]).to include(null: false, comment: "login")
      expect(tags[:options]).to include(array: true)
    end

    it "keeps the declared options on an index" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.index [ "email" ], name: "idx_users_email", unique: true
        end
      RUBY

      index = reader.tables["users"][:indexes].first
      expect(index[:columns]).to eq(%w[email])
      expect(index[:options]).to include(name: "idx_users_email", unique: true)
    end

    it "keeps the create_table options for the table" do
      reader = reader_for('create_table "users", id: false, force: :cascade do |t|; end')

      expect(reader.tables["users"][:options]).to include(id: false)
    end
  end

  describe "#foreign_keys" do
    it "reads top-level foreign keys" do
      reader = reader_for(<<~RUBY)
        create_table "posts" do |t|
          t.integer "author_id"
        end

        add_foreign_key "posts", "users"
      RUBY

      expect(reader.foreign_keys).to eq([ { from: "posts", to: "users" } ])
    end

    it "keeps a declared column and primary_key" do
      reader = reader_for(<<~RUBY)
        create_table "comments" do |t|
          t.integer "parent_post_id"
        end

        add_foreign_key "comments", "posts", column: "parent_post_id", primary_key: "uuid"
      RUBY

      expect(reader.foreign_keys).to eq(
        [ { from: "comments", to: "posts", column: "parent_post_id", primary_key: "uuid" } ]
      )
    end
  end

  describe "#enums" do
    it "reads enum type declarations" do
      reader = reader_for('create_enum "status", [ "draft", "live" ]')

      expect(reader.enums).to eq([ { name: "status", values: %w[draft live] } ])
    end
  end

  describe "#check_constraints" do
    it "attaches an in-table constraint to its table" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.check_constraint "age > 0"
        end
      RUBY

      expect(reader.check_constraints).to eq([ { table: "users", expression: "age > 0" } ])
    end

    it "reads a top-level constraint with its own table" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.integer "age"
        end

        add_check_constraint "users", "age < 200"
      RUBY

      expect(reader.check_constraints).to eq([ { table: "users", expression: "age < 200" } ])
    end
  end

  # Rails dumps each partition as a table inheriting its parent, with copies
  # of the parent's keys and constraints.
  describe "a partitioned table" do
    let(:reader) do
      reader_for(<<~RUBY)
        ActiveRecord::Schema[8.1].define(version: 0) do
          create_table "capitals", id: false, options: "INHERITS (cities)", force: :cascade do |t|
            t.text "state"
          end

          create_table "cities", id: false, force: :cascade do |t|
            t.text "name"
          end

          create_table "measurements", primary_key: ["id", "recorded_on"], options: "PARTITION BY RANGE (recorded_on)", force: :cascade do |t|
            t.bigint "post_id"
            t.check_constraint "id > 0", name: "positive_id"
          end

          create_table "measurements_2026_01", primary_key: ["id", "recorded_on"], options: "INHERITS (measurements)", force: :cascade do |t|
            t.bigint "post_id"
            t.check_constraint "id > 0", name: "positive_id"
          end

          create_table "measurements_2026_02", primary_key: ["id", "recorded_on"], options: "INHERITS (measurements)", force: :cascade do |t|
            t.bigint "post_id"
            t.check_constraint "id > 0", name: "positive_id"
          end

          create_table "measurements_2026_02_a", primary_key: ["id", "recorded_on"], options: "INHERITS (measurements_2026_02)", force: :cascade do |t|
            t.bigint "post_id"
            t.check_constraint "id > 0", name: "positive_id"
          end

          create_table "posts", force: :cascade do |t|
            t.text "title"
          end

          add_foreign_key "measurements", "posts", name: "measurements_post_id_fkey"
          add_foreign_key "measurements_2026_01", "posts", name: "measurements_post_id_fkey"
          add_foreign_key "measurements_2026_02", "posts", name: "measurements_post_id_fkey"
          add_foreign_key "measurements_2026_02_a", "posts", name: "measurements_post_id_fkey"
        end
      RUBY
    end

    it "is one table, and a table inheriting a plain one stays its own" do
      expect(reader.tables.keys).to contain_exactly("capitals", "cities", "measurements", "posts")
    end

    it "declares its foreign key once" do
      expect(reader.foreign_keys.map { |fk| fk[:from] }).to eq(%w[measurements])
    end

    it "declares its check constraint once" do
      expect(reader.check_constraints.map { |c| c[:table] }).to eq(%w[measurements])
    end

    # PostgreSQL clones a key that references a partitioned table once per partition.
    it "keeps a foreign key to a partitioned table once" do
      reader = reader_for(<<~RUBY)
        create_table "events", id: false, options: "PARTITION BY RANGE (day)", force: :cascade do |t|
          t.date "day", null: false
        end

        create_table "events_2026", id: false, options: "INHERITS (events)", force: :cascade do |t|
          t.date "day", null: false
        end

        create_table "event_refs", force: :cascade do |t|
          t.date "event_day"
        end

        add_foreign_key "event_refs", "events", column: "event_day", primary_key: "day"
        add_foreign_key "event_refs", "events_2026", column: "event_day", primary_key: "day"
      RUBY

      expect(reader.foreign_keys.map { |fk| fk[:to] }).to eq(%w[events])
    end

    # Rails writes the parent's name raw, not as an identifier.
    it "is one table under a name that is not a bare word" do
      reader = reader_for(<<~RUBY)
        create_table "page-views", id: false, options: "PARTITION BY RANGE (viewed_on)", force: :cascade do |t|
          t.date "viewed_on", null: false
        end

        create_table "page-views 2026", id: false, options: "INHERITS (page-views)", force: :cascade do |t|
          t.date "viewed_on", null: false
        end
      RUBY

      expect(reader.tables.keys).to eq([ "page-views" ])
    end

    # Before Rails 8 a partition dumps as a plain table, so only the database
    # can say which tables are partitions.
    it "is one table when the caller names partitions the dump does not mark" do
      reader = reader_for(<<~RUBY, partitions: %w[measurements_2026_01])
        ActiveRecord::Schema[7.2].define(version: 0) do
          create_table "measurements", id: false, force: :cascade do |t|
            t.date "recorded_on", null: false
            t.check_constraint "recorded_on > '2000-01-01'::date", name: "recent"
          end

          create_table "measurements_2026_01", id: false, force: :cascade do |t|
            t.date "recorded_on", null: false
            t.check_constraint "recorded_on > '2000-01-01'::date", name: "recent"
          end

          add_foreign_key "measurements", "posts"
          add_foreign_key "measurements_2026_01", "posts"
        end
      RUBY

      expect(reader.tables.keys).to eq(%w[measurements])
      expect(reader.foreign_keys.map { |fk| fk[:from] }).to eq(%w[measurements])
      expect(reader.check_constraints.map { |c| c[:table] }).to eq(%w[measurements])
    end
  end

  describe "#column?" do
    it "answers whether a table declares a column" do
      reader = reader_for(<<~RUBY)
        create_table "posts" do |t|
          t.string "type"
        end
      RUBY

      expect(reader.column?("posts", "type")).to be true
      expect(reader.column?("posts", "deleted_at")).to be false
      expect(reader.column?("orders", "type")).to be false
    end
  end

  describe "#any_column?" do
    it "answers whether any table declares a column" do
      reader = reader_for(<<~RUBY)
        create_table "users" do |t|
          t.datetime "deleted_at"
        end

        create_table "posts" do |t|
          t.string "title"
        end
      RUBY

      expect(reader.any_column?("deleted_at")).to be true
      expect(reader.any_column?("archived_at")).to be false
    end
  end

  describe "pk_type" do
    it "adds the implied id column when a pk type is given" do
      path = File.join(Dir.tmpdir, "rac_schema_reader_pk_#{rand(1_000_000)}.rb")
      File.write(path, <<~RUBY)
        ActiveRecord::Schema[7.1].define(version: 1) do
          create_table "users", force: :cascade do |t|
            t.string "email"
          end
          create_table "posts_tags", id: false, force: :cascade do |t|
            t.bigint "post_id"
          end
        end
      RUBY

      reader = described_class.new(path, pk_type: "bigint")
      expect(reader.column?("users", "id")).to be true
      expect(reader.column?("posts_tags", "id")).to be false
    ensure
      FileUtils.rm_f(path)
    end
  end

  describe ".for" do
    it "chooses schema.rb, then structure.sql, then migration replay" do
      Dir.mktmpdir do |root|
        db = File.join(root, "db")
        FileUtils.mkdir_p(File.join(db, "migrate"))

        File.write(File.join(db, "migrate", "20240101000000_create_posts.rb"), <<~RUBY)
          class CreatePosts < ActiveRecord::Migration[7.1]
            def change
              create_table :posts do |t|
                t.string :title
              end
            end
          end
        RUBY
        expect(described_class.for(root).source).to eq(:migrations)
        expect(described_class.for(root).column?("posts", "title")).to be true

        File.write(File.join(db, "structure.sql"), <<~SQL)
          CREATE TABLE public.articles (
              id bigint NOT NULL,
              headline character varying
          );
        SQL
        expect(described_class.for(root).source).to eq(:structure_sql)
        expect(described_class.for(root).column?("articles", "headline")).to be true

        File.write(File.join(db, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 1) do
            create_table "users", force: :cascade do |t|
              t.string "email"
            end
          end
        RUBY
        reader = described_class.for(root)
        expect(reader.source).to eq(:schema_rb)
        expect(reader.column?("users", "email")).to be true
        expect(reader.column?("users", "id")).to be true
      end
    end

    it "answers emptily when the app has no schema source" do
      Dir.mktmpdir do |root|
        reader = described_class.for(root)
        expect(reader.source).to eq(:none)
        expect(reader.tables).to eq({})
        expect(reader.any_column?("id")).to be false
      end
    end
  end
end
