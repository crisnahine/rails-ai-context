# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SchemaIntrospector do
  let(:app) { double("app", root: Pathname.new(fixture_path)) }
  let(:fixture_path) { File.expand_path("../../fixtures", __FILE__) }
  let(:introspector) { described_class.new(app) }

  describe "#call" do
    context "when ActiveRecord is not connected and no schema file" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)
      end

      it "returns an error" do
        result = introspector.call
        expect(result[:error]).to include("No db/schema.rb, db/structure.sql, or migrations found")
      end
    end

    context "with an empty schema.rb and no migrations (fresh Rails app)" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)

        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.0].define(version: 0) do
          end
        RUBY
      end

      after { FileUtils.rm_rf(File.join(fixture_path, "db")) }

      it "does not report 'file not found' when schema.rb exists but is empty" do
        result = introspector.call
        expect(result[:error]).to be_nil
      end

      it "returns an empty-schema state with total_tables=0 and a helpful note" do
        result = introspector.call
        expect(result[:total_tables]).to eq(0)
        expect(result[:tables]).to eq({})
        expect(result[:note]).to include("no migrations have been run yet")
        expect(result[:note]).to include("bin/rails db:migrate")
      end

      it "returns the empty-schema state for a genuinely 0-byte schema.rb" do
        File.write(File.join(fixture_path, "db", "schema.rb"), "")
        result = introspector.call
        expect(result[:error]).to be_nil
        expect(result[:total_tables]).to eq(0)
        expect(result[:note]).to include("no migrations have been run yet")
      end
    end

    context "with a valid schema.rb fixture" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)

        # Create fixture schema.rb
        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_01_15_000000) do
            create_table "users" do |t|
              t.string "email"
              t.string "name"
              t.integer "role"
              t.timestamps
            end

            create_table "posts" do |t|
              t.string "title"
              t.text "body"
              t.references "user"
              t.timestamps
            end
          end
        RUBY
      end

      after do
        FileUtils.rm_rf(File.join(fixture_path, "db"))
      end

      it "falls back to static schema.rb parsing" do
        result = introspector.call
        expect(result[:adapter]).to eq("static_parse")
        expect(result[:note]).to include("no DB connection")
      end

      it "parses tables from schema.rb" do
        result = introspector.call
        expect(result[:tables]).to have_key("users")
        expect(result[:tables]).to have_key("posts")
        expect(result[:total_tables]).to eq(2)
      end

      it "extracts column names and types" do
        result = introspector.call
        user_cols = result[:tables]["users"][:columns]
        expect(user_cols).to include(a_hash_including(name: "email", type: "string"))
        expect(user_cols).to include(a_hash_including(name: "role", type: "integer"))
      end
    end

    context "with a valid structure.sql fixture" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)

        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "structure.sql"), <<~SQL)
          CREATE TABLE public.users (
              id bigint NOT NULL,
              email character varying NOT NULL,
              name character varying,
              role integer DEFAULT 0,
              created_at timestamp(6) without time zone NOT NULL,
              updated_at timestamp(6) without time zone NOT NULL
          );

          CREATE TABLE public.posts (
              id bigint NOT NULL,
              title character varying,
              body text,
              user_id bigint,
              created_at timestamp(6) without time zone NOT NULL,
              updated_at timestamp(6) without time zone NOT NULL
          );

          CREATE TABLE public.schema_migrations (
              version character varying NOT NULL
          );

          CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);
          CREATE INDEX index_posts_on_user_id ON public.posts USING btree (user_id);

          ALTER TABLE ONLY public.posts
              ADD CONSTRAINT fk_rails_user FOREIGN KEY (user_id) REFERENCES public.users(id);
        SQL
      end

      after do
        FileUtils.rm_rf(File.join(fixture_path, "db"))
      end

      it "falls back to static structure.sql parsing" do
        result = introspector.call
        expect(result[:adapter]).to eq("static_parse")
        expect(result[:note]).to include("structure.sql")
      end

      it "parses tables from structure.sql" do
        result = introspector.call
        expect(result[:tables]).to have_key("users")
        expect(result[:tables]).to have_key("posts")
        expect(result[:total_tables]).to eq(2)
      end

      it "excludes schema_migrations table" do
        result = introspector.call
        expect(result[:tables]).not_to have_key("schema_migrations")
      end

      it "extracts columns with normalized types" do
        result = introspector.call
        user_cols = result[:tables]["users"][:columns]
        expect(user_cols).to include(a_hash_including(name: "email", type: "string"))
        expect(user_cols).to include(a_hash_including(name: "role", type: "integer"))
        expect(user_cols).to include(a_hash_including(name: "created_at", type: "datetime"))
      end

      it "extracts indexes" do
        result = introspector.call
        user_indexes = result[:tables]["users"][:indexes]
        expect(user_indexes).to include(a_hash_including(name: "index_users_on_email"))
      end

      it "extracts foreign keys" do
        result = introspector.call
        post_fks = result[:tables]["posts"][:foreign_keys]
        expect(post_fks).to include(a_hash_including(
          from_table: "posts",
          to_table: "users",
          column: "user_id"
        ))
      end
    end

    context "with t.index format inside create_table" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)

        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_01_15_000000) do
            create_table "user_profiles" do |t|
              t.integer "user_id"
              t.boolean "is_default"
              t.string "name"
              t.index ["user_id", "is_default"], name: "index_user_profiles_on_user_id_and_is_default"
              t.index ["user_id"], name: "index_user_profiles_on_user_id", unique: true
            end
          end
        RUBY
      end

      after do
        FileUtils.rm_rf(File.join(fixture_path, "db"))
      end

      it "parses t.index with composite columns" do
        result = introspector.call
        indexes = result[:tables]["user_profiles"][:indexes]
        composite_idx = indexes.find { |i| i[:name] == "index_user_profiles_on_user_id_and_is_default" }
        expect(composite_idx).not_to be_nil
        expect(composite_idx[:columns]).to eq(%w[user_id is_default])
      end

      it "parses t.index with unique flag" do
        result = introspector.call
        indexes = result[:tables]["user_profiles"][:indexes]
        unique_idx = indexes.find { |i| i[:name] == "index_user_profiles_on_user_id" }
        expect(unique_idx).not_to be_nil
        expect(unique_idx[:unique]).to eq(true)
      end
    end

    context "prefers schema.rb over structure.sql" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)

        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_01_15_000000) do
            create_table "users" do |t|
              t.string "email"
            end
          end
        RUBY
        File.write(File.join(db_dir, "structure.sql"), "CREATE TABLE public.other (id bigint);")
      end

      after do
        FileUtils.rm_rf(File.join(fixture_path, "db"))
      end

      it "uses schema.rb when both exist" do
        result = introspector.call
        expect(result[:note]).to include("schema.rb")
        expect(result[:tables]).to have_key("users")
      end
    end

    context "with check_constraints in schema.rb" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)

        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_01_15_000000) do
            create_table "orders" do |t|
              t.integer "quantity"
              t.check_constraint "quantity > 0", name: "quantity_positive"
            end

            add_check_constraint "users", "age >= 18", name: "age_check"
          end
        RUBY
      end

      after { FileUtils.rm_rf(File.join(fixture_path, "db")) }

      it "parses check_constraints from schema.rb" do
        result = introspector.call
        expect(result[:check_constraints]).to be_an(Array)
        expect(result[:check_constraints]).to include(a_hash_including(table: "orders", expression: "quantity > 0"))
        expect(result[:check_constraints]).to include(a_hash_including(table: "users", expression: "age >= 18"))
      end
    end

    context "with enum types in schema.rb" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)

        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_01_15_000000) do
            create_enum "status", ["pending", "active", "archived"]

            create_table "users" do |t|
              t.string "email"
            end
          end
        RUBY
      end

      after { FileUtils.rm_rf(File.join(fixture_path, "db")) }

      it "parses enum types from schema.rb" do
        result = introspector.call
        expect(result[:enum_types]).to be_an(Array)
        expect(result[:enum_types]).to include(a_hash_including(name: "status", values: [ "pending", "active", "archived" ]))
      end
    end

    context "with generated columns in schema.rb" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)

        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_01_15_000000) do
            create_table "products" do |t|
              t.decimal "price"
              t.decimal "tax"
              t.virtual "total", type: :decimal, as: "price + tax", stored: true
              t.virtual "display_name", type: :string, as: "name || ' ' || sku", virtual: true
            end
          end
        RUBY
      end

      after { FileUtils.rm_rf(File.join(fixture_path, "db")) }

      it "detects generated columns with stored flag" do
        result = introspector.call
        expect(result[:generated_columns]).to be_an(Array)
        total_col = result[:generated_columns].find { |c| c[:column] == "total" }
        expect(total_col).not_to be_nil
        expect(total_col[:stored]).to be true
      end

      it "detects virtual columns" do
        result = introspector.call
        display_col = result[:generated_columns].find { |c| c[:column] == "display_name" }
        expect(display_col).not_to be_nil
        expect(display_col[:stored]).to be false
      end
    end

    context "with schema_migrations table in schema.rb" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)

        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_01_15_000000) do
            create_table "schema_migrations" do |t|
              t.string "version"
            end

            create_table "users" do |t|
              t.string "email"
            end
          end
        RUBY
      end

      after { FileUtils.rm_rf(File.join(fixture_path, "db")) }

      it "skips schema_migrations without corrupting subsequent tables" do
        result = introspector.call
        expect(result[:tables]).not_to have_key("schema_migrations")
        expect(result[:tables]).to have_key("users")
        user_cols = result[:tables]["users"][:columns]
        expect(user_cols).to include(a_hash_including(name: "email", type: "string"))
      end
    end

    context "with migration files fallback (empty schema.rb)" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)

        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        # Empty schema.rb (just boilerplate, no create_table)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.0].define() do
          end
        RUBY

        migrate_dir = File.join(db_dir, "migrate")
        FileUtils.mkdir_p(migrate_dir)
        File.write(File.join(migrate_dir, "20250101000001_create_users.rb"), <<~RUBY)
          class CreateUsers < ActiveRecord::Migration[8.0]
            def change
              create_table :users do |t|
                t.string :email, null: false
                t.string :name
                t.timestamps
              end
              add_index :users, :email, unique: true
            end
          end
        RUBY
        File.write(File.join(migrate_dir, "20250101000002_create_posts.rb"), <<~RUBY)
          class CreatePosts < ActiveRecord::Migration[8.0]
            def change
              create_table :posts do |t|
                t.string :title
                t.text :body
                t.references :user, null: false
                t.timestamps
              end
            end
          end
        RUBY
        File.write(File.join(migrate_dir, "20250101000003_add_slug_to_posts.rb"), <<~RUBY)
          class AddSlugToPosts < ActiveRecord::Migration[8.0]
            def change
              add_column :posts, :slug, :string
              add_index :posts, :slug, unique: true
            end
          end
        RUBY
      end

      after { FileUtils.rm_rf(File.join(fixture_path, "db")) }

      it "falls back to migration parsing when schema.rb is empty" do
        result = introspector.call
        expect(result[:adapter]).to eq("static_parse")
        expect(result[:note]).to include("migration")
      end

      it "reconstructs tables from create_table migrations" do
        result = introspector.call
        expect(result[:tables]).to have_key("users")
        expect(result[:tables]).to have_key("posts")
        expect(result[:total_tables]).to eq(2)
      end

      it "extracts columns including types and null constraints" do
        result = introspector.call
        user_cols = result[:tables]["users"][:columns]
        expect(user_cols).to include(a_hash_including(name: "email", type: "string", null: false))
        expect(user_cols).to include(a_hash_including(name: "name", type: "string"))
      end

      it "handles t.references as bigint column" do
        result = introspector.call
        post_cols = result[:tables]["posts"][:columns]
        expect(post_cols).to include(a_hash_including(name: "user_id", type: "bigint"))
      end

      it "adds timestamps columns" do
        result = introspector.call
        user_cols = result[:tables]["users"][:columns]
        expect(user_cols).to include(a_hash_including(name: "created_at", type: "datetime"))
        expect(user_cols).to include(a_hash_including(name: "updated_at", type: "datetime"))
      end

      it "replays add_column from later migrations" do
        result = introspector.call
        post_cols = result[:tables]["posts"][:columns]
        expect(post_cols).to include(a_hash_including(name: "slug", type: "string"))
      end

      it "extracts indexes from migrations" do
        result = introspector.call
        user_indexes = result[:tables]["users"][:indexes]
        expect(user_indexes).to include(a_hash_including(columns: [ "email" ], unique: true))
        post_indexes = result[:tables]["posts"][:indexes]
        expect(post_indexes).to include(a_hash_including(columns: [ "slug" ], unique: true))
      end
    end

    context "schema version parsing" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(true)
        allow(introspector).to receive(:adapter_name).and_return("postgresql")
        allow(introspector).to receive(:table_names).and_return([ "users" ])
        allow(introspector).to receive(:extract_tables).and_return({ "users" => { columns: [], indexes: [], foreign_keys: [] } })
      end

      it "parses full schema version with underscores" do
        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_01_15_123456) do
          end
        RUBY

        result = introspector.call
        expect(result[:schema_version]).to eq("20240115123456")
      ensure
        FileUtils.rm_rf(db_dir)
      end
    end
  end
end
