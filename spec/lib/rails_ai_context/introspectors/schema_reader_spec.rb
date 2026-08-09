# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SchemaReader do
  def reader_for(source)
    path = File.join(Dir.tmpdir, "rac_schema_reader_#{rand(1_000_000)}.rb")
    File.write(path, source)
    described_class.new(path)
  ensure
    @paths ||= []
    @paths << path
  end

  after { @paths&.each { |p| FileUtils.rm_f(p) } }

  describe "#tables" do
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

    it "collects in-table indexes as column lists" do
      reader = reader_for(<<~RUBY)
        create_table "profiles" do |t|
          t.integer "user_id"
          t.boolean "primary"
          t.index [ "user_id", "primary" ], name: "idx_profiles"
          t.index [ "user_id" ]
        end
      RUBY

      expect(reader.tables["profiles"][:indexes]).to contain_exactly(
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

      expect(reader.tables["users"][:indexes]).to eq([ %w[email] ])
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
end
