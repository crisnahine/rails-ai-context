# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

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
              t.timestamptz "last_seen_at"
              t.tsvector "search_vector"
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
        expect(user_cols).to include(a_hash_including(name: "last_seen_at", type: "timestamptz"))
        expect(user_cols).to include(a_hash_including(name: "search_vector", type: "tsvector"))
      end
    end

    def parse_structure_fixture(sql)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        path = File.join(dir, "db", "structure.sql")
        File.write(path, sql)
        fixture_introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        return fixture_introspector.send(:parse_structure_sql, path)
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

      it "reports the postgresql dialect" do
        result = introspector.call
        expect(result[:dialect]).to eq("postgresql")
      end
    end

    context "with a MySQL (mysqldump) structure.sql" do
      let(:mysql_sql) do
        <<~SQL
          CREATE TABLE `products` (
            `id` bigint NOT NULL AUTO_INCREMENT,
            `name` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
            `price_cents` int NOT NULL DEFAULT '0',
            `active` tinyint(1) DEFAULT '1',
            `store_id` bigint DEFAULT NULL,
            `metadata` json DEFAULT NULL,
            `created_at` datetime(6) NOT NULL,
            PRIMARY KEY (`id`),
            UNIQUE KEY `index_products_on_name` (`name`),
            KEY `index_products_on_store_id` (`store_id`),
            CONSTRAINT `fk_rails_123abc` FOREIGN KEY (`store_id`) REFERENCES `stores` (`id`)
          ) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

          CREATE TABLE `stores` (
            `id` bigint NOT NULL AUTO_INCREMENT,
            `name` varchar(255) DEFAULT NULL,
            PRIMARY KEY (`id`)
          ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

          INSERT INTO `schema_migrations` (version) VALUES ('20240101000000');
        SQL
      end

      it "extracts tables, columns, indexes, and foreign keys" do
        result = parse_structure_fixture(mysql_sql)

        expect(result[:dialect]).to eq("mysql")
        expect(result[:total_tables]).to eq(2)

        products = result[:tables]["products"]
        expect(products[:columns].map { |c| c[:name] })
          .to contain_exactly("id", "name", "price_cents", "active", "store_id", "metadata", "created_at")
        types = products[:columns].to_h { |c| [ c[:name], c[:type] ] }
        expect(types["name"]).to eq("string")
        expect(types["active"]).to eq("boolean")
        expect(types["price_cents"]).to eq("integer")
        expect(types["created_at"]).to eq("datetime")

        expect(products[:indexes]).to include(
          { name: "index_products_on_name", columns: [ "name" ], unique: true },
          { name: "index_products_on_store_id", columns: [ "store_id" ], unique: false }
        )
        expect(products[:foreign_keys]).to eq(
          [ { from_table: "products", to_table: "stores", column: "store_id", primary_key: "id" } ]
        )
      end
    end

    context "with unquoted key/index column names (PostgreSQL non-reserved words)" do
      let(:pg_key_sql) do
        <<~SQL
          CREATE TABLE public.settings (
              id bigint NOT NULL,
              key character varying NOT NULL,
              index integer DEFAULT 0,
              value text
          );
        SQL
      end

      it "parses key and index as columns, not index definitions" do
        result = parse_structure_fixture(pg_key_sql)
        settings = result[:tables]["settings"]
        expect(settings[:columns].map { |c| c[:name] }).to contain_exactly("id", "key", "index", "value")
        expect(settings[:indexes]).to be_empty
      end
    end

    context "with a SQLite structure.sql" do
      let(:sqlite_sql) do
        <<~SQL
          CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
          CREATE TABLE IF NOT EXISTS "widgets" (
            "id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
            "name" varchar DEFAULT NULL,
            "weight" decimal(8,2),
            "created_at" datetime(6) NOT NULL
          );
          CREATE UNIQUE INDEX "index_widgets_on_name" ON "widgets" ("name");
          INSERT INTO "schema_migrations" (version) VALUES ('20240101000000');
        SQL
      end

      it "extracts quoted tables, columns, and indexes" do
        result = parse_structure_fixture(sqlite_sql)

        expect(result[:dialect]).to eq("sqlite")
        expect(result[:tables].keys).to eq([ "widgets" ])
        widgets = result[:tables]["widgets"]
        expect(widgets[:columns].map { |c| c[:name] }).to include("name", "weight", "created_at")
        expect(widgets[:indexes]).to eq(
          [ { name: "index_widgets_on_name", columns: [ "name" ], unique: true } ]
        )
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

  describe "#static_call" do
    it "answers from files even when a live connection exists" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_01_01_000000) do
            create_table "widgets" do |t|
              t.string "name"
            end
          end
        RUBY
        app = RailsAiContext::StaticApp.new(dir)
        result = described_class.new(app).static_call
        expect(result[:total_tables]).to eq(1)
        expect(result[:tables]).to have_key("widgets")
        expect(result[:adapter]).to eq("static_parse")
      end
    end
  end

  describe "secondary database dumps" do
    it "reports db/*_schema.rb dumps under secondary_databases" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.0].define(version: 2024_01_01_000000) do
            create_table "users" do |t|
              t.string "name"
            end
          end
        RUBY
        File.write(File.join(dir, "db", "queue_schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.0].define(version: 1) do
            create_table "solid_queue_jobs" do |t|
              t.string "queue_name", null: false
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:tables].keys).to eq([ "users" ])
        expect(result[:secondary_databases].keys).to eq([ "queue" ])
        expect(result[:secondary_databases]["queue"][:tables]).to have_key("solid_queue_jobs")
        expect(result[:secondary_databases]["queue"][:note]).to include("queue_schema.rb")
      end
    end

    it "omits the key entirely when no secondary dumps exist" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.0].define(version: 1) do
            create_table "users" do |t|
              t.string "name"
            end
          end
        RUBY
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result).not_to have_key(:secondary_databases)
      end
    end

    it "attaches secondary_databases from the LIVE path in #call too" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "queue_schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.0].define(version: 1) do
            create_table "solid_queue_jobs" do |t|
              t.string "queue_name", null: false
            end
          end
        RUBY

        app = double("app", root: Pathname.new(dir))
        live_introspector = described_class.new(app)
        allow(live_introspector).to receive(:active_record_connected?).and_return(true)
        allow(live_introspector).to receive(:adapter_name).and_return("postgresql")
        allow(live_introspector).to receive(:table_names).and_return([ "users" ])
        allow(live_introspector).to receive(:extract_tables).and_return({ "users" => { columns: [], indexes: [], foreign_keys: [] } })

        result = live_introspector.call

        expect(result[:tables].keys).to eq([ "users" ])
        expect(result[:secondary_databases].keys).to eq([ "queue" ])
        expect(result[:secondary_databases]["queue"][:tables]).to have_key("solid_queue_jobs")
      end
    end
  end
end
