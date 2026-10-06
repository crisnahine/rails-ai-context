# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::SchemaIntrospector do
  let(:app) { double("app", root: Pathname.new(fixture_path)) }
  let(:fixture_path) { File.expand_path("../../fixtures", __FILE__) }
  let(:introspector) { described_class.new(app) }

  describe "#call" do
    # A blog that is connected but not yet migrated: the answer comes from the
    # files, and the database is there.
    context "when connected to a database with no tables yet" do
      it "says the database is connected, not that there is no connection" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db", "migrate"))
          File.write(File.join(dir, "db", "migrate", "20260901000000_create_posts.rb"), <<~RUBY)
            class CreatePosts < ActiveRecord::Migration[8.1]
              def change
                create_table :posts do |t|
                  t.string :title
                end
              end
            end
          RUBY
          blog = described_class.new(RailsAiContext::StaticApp.new(dir))
          allow(blog).to receive(:active_record_connected?).and_return(true)
          allow(blog).to receive(:table_names).and_return([])

          note = blog.call[:note].to_s

          expect(note).to include("connected, no tables yet")
          expect(note).not_to include("no DB connection")
        end
      end
    end

    context "when ActiveRecord is not connected and no schema file" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(false)
      end

      it "reports the source as unavailable, not failed" do
        result = introspector.call
        expect(result[:unavailable]).to include("No db/schema.rb or migrations found")
        expect(result[:error]).to be_nil
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

      it "keeps a foreign key over two columns as its columns on the static tier" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
            ActiveRecord::Schema[8.0].define(version: 1) do
              create_table "event_refs" do |t|
                t.bigint "event_id"
                t.date "event_day"
              end

              add_foreign_key "event_refs", "events", column: ["event_id", "event_day"], primary_key: ["id", "day"]
            end
          RUBY

          keys = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:tables]["event_refs"][:foreign_keys]

          expect(keys).to eq([ { from_table: "event_refs", to_table: "events", column: %w[event_id event_day], primary_key: %w[id day] } ])
        end
      end

      # `declared_tables` names what db/schema.rb declares on both tiers, and
      # a structure.sql app has no such list: the booted tier answers nil.
      it "names what db/schema.rb declares on the static tier" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"),
                     %(ActiveRecord::Schema[8.0].define(version: 1) do\n  create_table "users" do |t|\n    t.string "email"\n  end\nend\n))

          result = described_class.new(RailsAiContext::StaticApp.new(dir)).send(:static_schema_parse)

          expect(result[:declared_tables]).to eq([ "users" ])
          expect(result[:declared_in]).to eq("db/schema.rb")
        end
      end

      it "names no dump for an app whose tables come from the migrations" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db", "migrate"))
          File.write(File.join(dir, "db", "migrate", "20240101000000_create_users.rb"),
                     "class CreateUsers < ActiveRecord::Migration[8.0]\n  def change\n    create_table :users\n  end\nend\n")

          result = described_class.new(RailsAiContext::StaticApp.new(dir)).send(:static_schema_parse)

          expect(result[:tables]).to have_key("users")
          expect(result[:declared_tables]).to be_nil
          expect(result[:declared_in]).to be_nil
        end
      end

      it "claims no db/schema.rb declaration for a structure.sql app" do
        result = introspector.call

        expect(result).to have_key(:declared_tables)
        expect(result[:declared_tables]).to be_nil
      end

      it "names a bigint column the way db/schema.rb does" do
        connection = ActiveRecord::Base.connection
        connection.create_table(:pa_q_blobs, force: true) do |t|
          t.bigint :filesize
          t.integer :views
        end

        columns = introspector.send(:extract_columns, "pa_q_blobs")

        expect(columns).to include(a_hash_including(name: "filesize", type: "bigint"))
        expect(columns.find { |c| c[:name] == "filesize" }).not_to have_key(:limit)
        expect(columns).to include(a_hash_including(name: "views", type: "integer"))
      ensure
        ActiveRecord::Base.connection.drop_table(:pa_q_blobs, if_exists: true)
      end

      # PostgreSQL reports an array column's default as its literal (`{}`);
      # the static tier reads it as Rails dumps it, and both keep the flag.
      it "reads a PostgreSQL array column as the static tier does" do
        metadata = double(sql_type: "character varying[]")
        column = double(name: "tags", type: :string, null: true, default: '{a,"b c"}', limit: nil, precision: nil,
                        scale: nil, comment: nil, collation: nil, sql_type: "character varying[]", array?: true, sql_type_metadata: metadata)
        allow(ActiveRecord::Base.connection).to receive(:columns).with("pa_v_things").and_return([ column ])

        expect(introspector.send(:extract_columns, "pa_v_things"))
          .to eq([ { name: "tags", type: "string", null: true, default: '["a", "b c"]', array: true } ])
      end

      it "reads a MySQL text column's size as schema.rb writes it" do
        column = double(name: "body", type: :text, null: true, default: nil, limit: 16_777_215, precision: nil,
                        scale: nil, comment: nil, collation: nil, sql_type: "mediumtext", array?: false)
        allow(introspector).to receive(:connection).and_return(double("mysql2", columns: [ column ], native_database_types: {}, mariadb?: false))

        expect(introspector.send(:extract_columns, "pa_v_posts")).to eq([ { name: "body", type: "text", null: true, size: "medium" } ])
      end

      # Collations are matched by exact table name; user_roles and userxroles are different tables.
      it "takes a MySQL table's own collation, read once for every table" do
        column = double(name: "name", type: :string, null: true, default: nil, limit: nil, precision: nil,
                        scale: nil, comment: nil, collation: "utf8mb4_bin", sql_type: "varchar(255)", array?: false)
        connection = double("mysql2", columns: [ column ], native_database_types: {}, mariadb?: false)
        allow(connection).to receive(:select_rows).once
          .and_return([ [ "userxroles", "utf8mb4_bin" ], [ "user_roles", "utf8mb4_0900_ai_ci" ] ])
        allow(introspector).to receive(:connection).and_return(connection)

        expect(introspector.send(:extract_columns, "user_roles").first).to include(collation: "utf8mb4_bin")
        expect(introspector.send(:extract_columns, "userxroles").first).not_to have_key(:collation)
      end

      it "names a MySQL enum, set or timestamp column by the type schema.rb writes" do
        columns = { "kind" => [ :string, "enum('a','b')" ], "flags" => [ :string, "set('x','y')" ], "seen_at" => [ :datetime, "timestamp" ] }.map do |name, (type, sql_type)|
          double(name: name, type: type, null: true, default: nil, limit: nil, precision: nil,
                 scale: nil, comment: nil, collation: nil, sql_type: sql_type, array?: false)
        end
        allow(introspector).to receive(:connection).and_return(double("mysql2", columns: columns, native_database_types: {}, mariadb?: false))

        expect(introspector.send(:extract_columns, "pa_v_shapes").map { |c| c[:type] }).to eq([ "enum('a','b')", "set('x','y')", "timestamp" ])
      end

      # ActiveRecord gives an expression index's columns as one String; the
      # static readers split it into keys, and every consumer maps the list.
      it "reads an expression index's columns as the static readers do" do
        index = double(name: "idx_lower_email", columns: "lower((email)::text), id", unique: true, where: nil,
                       using: :btree, type: nil, orders: {}, opclasses: {}, lengths: {})
        allow(ActiveRecord::Base.connection).to receive(:indexes).with("pa_v_people").and_return([ index ])

        expect(introspector.send(:extract_indexes, "pa_v_people"))
          .to eq([ { name: "idx_lower_email", columns: [ "lower((email)::text)", "id" ], unique: true } ])
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
              t.index ["name"], name: "index_user_profiles_on_name", unique: true, where: "(is_default IS TRUE)"
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

      it "carries a partial index's where: condition" do
        indexes = introspector.call[:tables]["user_profiles"][:indexes]

        expect(indexes.find { |i| i[:name] == "index_user_profiles_on_name" }[:where]).to eq("(is_default IS TRUE)")
        expect(indexes.find { |i| i[:name] == "index_user_profiles_on_user_id" }).not_to have_key(:where)
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

            create_table "users" do |t|
              t.integer "age"
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
        expect(result[:note]).to end_with("(no DB connection, db/schema.rb declares no tables)")
      end

      it "says nothing about unnamed tables when every create_table named one" do
        expect(introspector.call[:note]).not_to include("unnamed")
      end

      # A create_table whose name is computed makes a table the replay cannot
      # name, and the count said the schema was whole.
      it "says how many create_table calls it could not name" do
        File.write(File.join(fixture_path, "db", "migrate", "20250101000004_create_dynamic.rb"), <<~RUBY)
          class CreateDynamic < ActiveRecord::Migration[8.0]
            def change
              create_table computed_name do |t|
                t.string :x
              end
            end
          end
        RUBY

        expect(introspector.call[:note]).to include("1 create_table call left unnamed")
      end

      it "says how many added columns it could not name" do
        File.write(File.join(fixture_path, "db", "migrate", "20250101000005_add_dynamic.rb"), <<~RUBY)
          class AddDynamic < ActiveRecord::Migration[8.0]
            def change
              add_column :posts, computed_column, :string
            end
          end
        RUBY

        expect(introspector.call[:note]).to include("1 added column left unnamed")
      end

      it "says how many migration helper calls it could not replay" do
        FileUtils.mkdir_p(File.join(fixture_path, "lib", "acme"))
        File.write(File.join(fixture_path, "lib", "acme", "slow_helpers.rb"), <<~RUBY)
          module Acme
            module SlowHelpers
              def swap_type(table, column, type)
                add_column table, "tmp", type
                remove_column table, column
              end
            end
          end
        RUBY
        File.write(File.join(fixture_path, "db", "migrate", "20250101000006_use_helper.rb"), <<~RUBY)
          class UseHelper < ActiveRecord::Migration[8.0]
            extend Acme::SlowHelpers
            def up
              swap_type :posts, :title, :text
            end
          end
        RUBY

        expect(introspector.call[:note]).to include("1 migration helper call not replayed")
      ensure
        FileUtils.rm_rf(File.join(fixture_path, "lib", "acme"))
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

      it "names an implied foreign key column from the singular target table" do
        migrate_dir = File.join(fixture_path, "db", "migrate")
        File.write(File.join(migrate_dir, "20250101000004_add_statuses.rb"), <<~RUBY)
          class AddStatuses < ActiveRecord::Migration[8.0]
            def change
              create_table :statuses do |t|
                t.string :name
              end
              add_foreign_key :posts, :statuses
              add_foreign_key :posts, :users, column: :author_id
            end
          end
        RUBY

        result = introspector.call

        expect(result[:tables]["posts"][:foreign_keys]).to eq([
          { from_table: "posts", to_table: "statuses", column: "status_id", primary_key: "id" },
          { from_table: "posts", to_table: "users", column: "author_id", primary_key: "id" }
        ])
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

    context "when the database names some of its tables as partitions" do
      it "lists the partitioned table and not its partitions" do
        connection = ActiveRecord::Base.connection
        connection.create_table(:pa_p_events, force: true) { |t| t.date :happened_on }
        connection.create_table(:pa_p_events_2026, force: true) { |t| t.date :happened_on }
        allow(RailsAiContext::Introspectors::PgPartitions).to receive(:names).and_return([ "pa_p_events_2026" ])

        result = introspector.call

        expect(result[:tables]).to have_key("pa_p_events")
        expect(result[:tables]).not_to have_key("pa_p_events_2026")
        expect(result[:total_tables]).to eq(result[:tables].size)
      ensure
        connection.drop_table(:pa_p_events, if_exists: true)
        connection.drop_table(:pa_p_events_2026, if_exists: true)
      end

      # PostgreSQL clones a key that references a partitioned table once per partition.
      it "keeps a foreign key to the partitioned table once" do
        connection = ActiveRecord::Base.connection
        connection.create_table(:pa_p_refs, force: true) { |t| t.integer :event_id }
        allow(RailsAiContext::Introspectors::PgPartitions).to receive(:names).and_return([ "pa_p_events_2026" ])
        allow(connection).to receive(:foreign_keys).and_call_original
        allow(connection).to receive(:foreign_keys).with("pa_p_refs").and_return(
          %w[pa_p_events pa_p_events_2026].map { |to| double(from_table: "pa_p_refs", to_table: to, column: "event_id", primary_key: "id", on_delete: nil, on_update: nil, deferrable: nil, validate?: true) }
        )

        keys = introspector.call[:tables]["pa_p_refs"][:foreign_keys]

        expect(keys.map { |fk| fk[:to_table] }).to eq(%w[pa_p_events])
      ensure
        connection.drop_table(:pa_p_refs, if_exists: true)
      end
    end

    # The booted answer read its table list off the connection and its version
    # stamp off db/schema.rb, and joined neither, so a branch pulled without
    # running db:migrate looked like a misspelled table.
    context "when db/schema.rb declares a table the connection does not have" do
      before do
        allow(introspector).to receive(:active_record_connected?).and_return(true)
        allow(introspector).to receive(:adapter_name).and_return("postgresql")
        allow(introspector).to receive(:table_names).and_return([ "users" ])
        allow(introspector).to receive(:extract_tables).and_return({ "users" => { columns: [], indexes: [], foreign_keys: [] } })
      end

      it "carries the tables the dump declares alongside the live ones" do
        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.0].define(version: 2026_09_20_000000) do
            create_table "users", force: :cascade do |t|
              t.string "email"
            end

            create_table "order_comments", force: :cascade do |t|
              t.text "body"
            end

            create_virtual_table "docs_fts", "fts5", ["body"]
            create_view "active_users", sql_definition: "SELECT 1"
          end
        RUBY

        result = introspector.call

        # A virtual table counts as a table, as the schema header counts it; a view does not.
        expect(result[:declared_tables]).to contain_exactly("users", "order_comments", "docs_fts")
        expect(result[:tables].keys).to eq([ "users" ])
        expect(result[:declared_in]).to eq("db/schema.rb")
      ensure
        FileUtils.rm_rf(db_dir)
      end

      # The connection lists a table the dumper skipped, so the declared side counts it too.
      it "counts a table schema.rb could not dump as declared" do
        allow(introspector).to receive(:extract_tables).and_return(
          "users" => { columns: [], indexes: [], foreign_keys: [] }, "legacy" => { columns: [], indexes: [], foreign_keys: [] }
        )
        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.0].define(version: 2026_09_20_000000) do
            create_table "users", force: :cascade do |t|
              t.string "email"
            end

            create_table "posts", force: :cascade do |t|
              t.text "body"
            end

          # Could not dump table "legacy" because of following StandardError
          #   Unknown type 'geometry' for column 'shape'

          end
        RUBY

        result = introspector.call
        allow(RailsAiContext::Tools::GetSchema).to receive(:cached_context).and_return({ schema: result, models: {} })
        text = RailsAiContext::Tools::GetSchema.call(detail: "summary").content.first[:text]

        expect(result[:declared_tables]).to contain_exactly("users", "posts", "legacy")
        expect(text).to include("declares 3 tables; the connected database has 2. Missing: posts")
      ensure
        FileUtils.rm_rf(db_dir)
      end

      it "carries the connection's pending migrations, which name what adds the table" do
        pending = [ { version: "20260921000000", name: "CreateOrderComments" } ]
        allow(RailsAiContext::PendingMigrations).to receive(:live)
          .with([ File.join(fixture_path, "db", "migrate") ]).and_return(pending)

        expect(introspector.call[:pending_migrations]).to eq(pending)
      end

      # Before Rails 8 schema.rb dumps a partition as a plain table, which read
      # as a declared table the database lacks.
      it "does not count a partition the database names as missing" do
        db_dir = File.join(fixture_path, "db")
        FileUtils.mkdir_p(db_dir)
        File.write(File.join(db_dir, "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.2].define(version: 2026_09_20_000000) do
            create_table "users", force: :cascade do |t|
              t.string "email"
            end

            create_table "users_2026", force: :cascade do |t|
              t.string "email"
            end
          end
        RUBY
        allow(RailsAiContext::Introspectors::PgPartitions).to receive(:names).and_return([ "users_2026" ])

        expect(introspector.call[:declared_tables]).to eq([ "users" ])
      ensure
        FileUtils.rm_rf(db_dir)
      end
    end

    context "with a secondary database dump and ActiveRecord not connected" do
      it "still attaches secondary_databases through the static fallback" do
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

          fixture_introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
          allow(fixture_introspector).to receive(:active_record_connected?).and_return(false)

          result = fixture_introspector.call

          expect(result[:secondary_databases].keys).to eq([ "queue" ])
        end
      end
    end

    context "with a secondary database dump and no live tables" do
      it "still attaches secondary_databases when table_names is empty" do
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

          fixture_introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
          allow(fixture_introspector).to receive(:active_record_connected?).and_return(true)
          allow(fixture_introspector).to receive(:table_names).and_return([])

          result = fixture_introspector.call

          expect(result[:secondary_databases].keys).to eq([ "queue" ])
        end
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

    it "names the declared foreign key column instead of the target table convention" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_01_01_000000) do
            create_table "posts" do |t|
              t.string "title"
            end

            create_table "comments" do |t|
              t.integer "post_id"
              t.integer "parent_post_id"
            end

            add_foreign_key "comments", "posts"
            add_foreign_key "comments", "posts", column: "parent_post_id"
          end
        RUBY
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:tables]["comments"][:foreign_keys]).to eq([
          { from_table: "comments", to_table: "posts", column: "post_id", primary_key: "id" },
          { from_table: "comments", to_table: "posts", column: "parent_post_id", primary_key: "id" }
        ])
      end
    end

    it "reports Mongoid apps as unavailable instead of a misleading missing-schema error" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result[:unavailable]).to include("Mongoid")
        expect(result).not_to have_key(:error)
      end
    end
  end

  describe "an app that does not load Active Record" do
    it "says so instead of calling the schema files missing" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/application.rb"), "require \"rails\"\nrequire \"active_model/railtie\"\n# require \"active_record/railtie\"\nrequire \"action_controller/railtie\"\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:unavailable]).to eq("this app does not load Active Record; ActiveRecord schema introspection does not apply")
      end
    end
  end

  describe "a sequel-rails app" do
    it "says the app uses Sequel instead of replaying its migrations as Active Record" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "config/application.rb"), "require \"rails\"\n# require \"active_record/railtie\"\nrequire \"sequel_rails\"\nrequire \"action_controller/railtie\"\n")
        File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    sequel-rails (1.2.4)\n\nDEPENDENCIES\n  sequel-rails\n")
        File.write(File.join(dir, "db/schema.rb"), "Sequel.migration do\n  change do\n    create_table(:artists) do\n      primary_key :id\n    end\n  end\nend\n")
        File.write(File.join(dir, "db/migrate/20260101000001_create_artists.rb"), "Sequel.migration do\n  change do\n    create_table(:artists) do\n      String :name\n    end\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result).to eq(unavailable: "this app uses Sequel; ActiveRecord schema introspection does not apply")
      end
    end
  end

  describe "a dump that holds only views" do
    view_sql = "CREATE VIEW public.daily_totals AS SELECT 1 AS n;\n"

    it "lists the view of a views-only primary structure.sql" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db/structure.sql"), view_sql)

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:tables].keys).to eq([ "daily_totals" ])
        expect(result[:total_tables]).to eq(0)
      end
    end

    it "keeps a secondary database whose dump holds only views" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db/structure.sql"), "CREATE TABLE public.users (\n    id bigint NOT NULL\n);\n")
        File.write(File.join(dir, "db/reporting_structure.sql"), view_sql)

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:secondary_databases].keys).to eq([ "reporting" ])
        expect(result[:secondary_databases]["reporting"][:tables].keys).to eq([ "daily_totals" ])
      end
    end
  end

  describe "migrations_paths in database.yml" do
    def write_app(dir, files)
      files.each do |path, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), body)
      end
    end

    let(:create_posts) do
      "class CreatePosts < ActiveRecord::Migration[8.1]\n  def change\n    create_table :posts do |t|\n      t.string :title\n    end\n  end\nend\n"
    end

    it "replays the primary's migrations from the path it names" do
      Dir.mktmpdir do |dir|
        write_app(dir, "config/database.yml" => "#{RailsAiContext.environment_name}:\n  adapter: sqlite3\n  database: db/dev.sqlite3\n  migrations_paths: db/main_migrate\n",
                       "db/main_migrate/20240101000000_create_posts.rb" => create_posts)

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:tables].keys).to eq([ "posts" ])
        expect(result[:note]).to include("Reconstructed from 1 migration file")
      end
    end

    it "replays a secondary database that has migrations and no dump yet" do
      Dir.mktmpdir do |dir|
        write_app(dir, "config/database.yml" => <<~YAML,
                    #{RailsAiContext.environment_name}:
                      primary:
                        adapter: sqlite3
                        database: db/dev.sqlite3
                      queue:
                        adapter: sqlite3
                        database: db/queue.sqlite3
                        migrations_paths: db/queue_migrate
                  YAML
                       "db/migrate/20240101000000_create_posts.rb" => create_posts,
                       "db/queue_migrate/20240101000000_create_jobs.rb" => create_posts.sub("CreatePosts", "CreateJobs").sub(":posts", ":jobs"))

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:tables].keys).to eq([ "posts" ])
        expect(result[:secondary_databases].keys).to eq([ "queue" ])
        expect(result[:secondary_databases]["queue"][:tables].keys).to eq([ "jobs" ])
        expect(result[:secondary_databases]["queue"][:note]).to include("db/queue_migrate")
      end
    end

    it "lists no replica or database_tasks: false entry as a database of its own" do
      Dir.mktmpdir do |dir|
        write_app(dir, "config/database.yml" => <<~YAML,
                    #{RailsAiContext.environment_name}:
                      primary:
                        adapter: sqlite3
                        database: db/dev.sqlite3
                      analytics: &analytics
                        adapter: sqlite3
                        database: db/analytics.sqlite3
                        migrations_paths: db/analytics_migrate
                      analytics_replica:
                        <<: *analytics
                        replica: true
                      reporting:
                        <<: *analytics
                        database_tasks: false
                  YAML
                       "db/schema.rb" => "ActiveRecord::Schema[8.1].define(version: 1) do\n  create_table \"users\" do |t|\n  end\nend\n",
                       "db/analytics_schema.rb" => "ActiveRecord::Schema[8.1].define(version: 1) do\n  create_table \"page_views\" do |t|\n  end\nend\n",
                       "db/analytics_migrate/20260101000001_create_page_views.rb" => create_posts)

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:secondary_databases].keys).to eq([ "analytics" ])
        expect(RailsAiContext::Introspectors::SchemaDumpPath.secondaries(dir).keys).to eq([ "analytics" ])
      end
    end

    it "reads a secondary database's dump under the name its schema_dump gives" do
      Dir.mktmpdir do |dir|
        write_app(dir, "config/database.yml" => <<~YAML,
                    #{RailsAiContext.environment_name}:
                      primary:
                        adapter: sqlite3
                        database: db/dev.sqlite3
                      analytics:
                        adapter: sqlite3
                        database: db/analytics.sqlite3
                        migrations_paths: db/analytics_migrate
                        schema_dump: analytics_custom.rb
                  YAML
                       "db/schema.rb" => "ActiveRecord::Schema[8.1].define(version: 1) do\n  create_table \"users\" do |t|\n  end\nend\n",
                       "db/analytics_custom.rb" => "ActiveRecord::Schema[8.1].define(version: 2026_01_01_000001) do\n  create_table \"page_views\" do |t|\n    t.string \"path\", null: false\n  end\nend\n",
                       "db/analytics_migrate/20260101000001_create_page_views.rb" => create_posts,
                       "db/analytics_migrate/20260101000002_add_x.rb" => create_posts.sub("CreatePosts", "AddX"))

        analytics = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:secondary_databases]["analytics"]

        expect(analytics[:tables].keys).to eq([ "page_views" ])
        expect(analytics[:tables]["page_views"][:columns].first).to include(name: "id", type: "integer")
        expect(analytics[:note]).to include("db/analytics_custom.rb")
        expect(analytics[:pending_migrations].map { |m| m[:version] }).to eq([ "20260101000002" ])
      end
    end

    it "lists a secondary once when its schema_dump file ends in _schema.rb under another name" do
      Dir.mktmpdir do |dir|
        write_app(dir, "config/database.yml" => <<~YAML,
                    #{RailsAiContext.environment_name}:
                      primary:
                        adapter: sqlite3
                        database: db/dev.sqlite3
                      analytics:
                        adapter: sqlite3
                        database: db/analytics.sqlite3
                        schema_dump: warehouse_schema.rb
                  YAML
                       "db/schema.rb" => "ActiveRecord::Schema[8.1].define(version: 1) do\n  create_table \"users\" do |t|\n  end\nend\n",
                       "db/warehouse_schema.rb" => "ActiveRecord::Schema[8.1].define(version: 2) do\n  create_table \"page_views\" do |t|\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:secondary_databases].keys).to eq([ "analytics" ])
      end
    end

    it "reads no migrations_paths outside the app" do
      Dir.mktmpdir do |outside|
        write_app(outside, "20240101000000_create_posts.rb" => create_posts)
        Dir.mktmpdir do |dir|
          write_app(dir, "config/database.yml" => "#{RailsAiContext.environment_name}:\n  adapter: sqlite3\n  migrations_paths: #{outside}\n")

          result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

          expect(result).to have_key(:unavailable)
        end
      end
    end
  end

  # sequel-rails keeps its schema and migrations where Active Record's go, in Sequel's DSL.
  describe "an app whose schema files are Sequel's" do
    def sequel_app(dir, schema: true)
      files = {
        "Gemfile" => "source \"https://rubygems.org\"\ngem \"rails\"\ngem \"sequel-rails\"\n",
        "config/application.rb" => "require \"rails\"\nrequire \"active_record/railtie\"\nrequire \"sequel_rails\"\n",
        "db/migrate/20260101000001_create_artists.rb" => "Sequel.migration do\n  change do\n    create_table(:artists) do\n      primary_key :id\n      String :name, null: false\n    end\n  end\nend\n"
      }
      files["db/schema.rb"] = "Sequel.migration do\n  change do\n    create_table(:artists) do\n      primary_key :id\n    end\n  end\nend\n" if schema
      files.each do |path, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), body)
      end
    end

    it "says the schema is Sequel's instead of reading it as Active Record's" do
      [ true, false ].each do |schema|
        Dir.mktmpdir do |dir|
          sequel_app(dir, schema: schema)

          result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

          expect(result[:tables]).to be_nil
          expect(result[:unavailable]).to include("Sequel")
          expect(RailsAiContext::Introspectors::SchemaReader.for(dir).tables).to eq({})
        end
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
          ActiveRecord::Schema[8.0].define(version: 2019_09_20_000000) do
            create_table "solid_queue_jobs" do |t|
              t.string "queue_name", null: false
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:tables].keys).to eq([ "users" ])
        expect(result[:schema_version]).to eq("20240101000000")
        expect(result[:secondary_databases].keys).to eq([ "queue" ])
        expect(result[:secondary_databases]["queue"][:tables]).to have_key("solid_queue_jobs")
        expect(result[:secondary_databases]["queue"][:note]).to include("queue_schema.rb")
        expect(result[:secondary_databases]["queue"][:schema_version]).to eq("20190920000000")
      end
    end

    it "lists the secondary dumps of a new app whose primary has no tables yet" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "queue_schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.0].define(version: 1) do
            create_table "solid_queue_jobs" do |t|
              t.string "queue_name", null: false
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result).not_to have_key(:unavailable)
        expect(result[:total_tables]).to eq(0)
        expect(result[:secondary_databases].keys).to eq([ "queue" ])
        expect(result[:secondary_databases]["queue"][:tables]).to have_key("solid_queue_jobs")
      end
    end

    it "reads each dump's own generated columns" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.0].define(version: 2024_01_01_000000) do
            create_table "users" do |t|
              t.virtual "full_name", type: :string, as: "first || last", stored: true
            end
          end
        RUBY
        File.write(File.join(dir, "db", "queue_schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.0].define(version: 2019_09_20_000000) do
            create_table "solid_queue_jobs" do |t|
              t.virtual "priority_label", type: :string, as: "x", stored: true
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:generated_columns]).to contain_exactly(
          a_hash_including(table: "users", column: "full_name")
        )
        expect(result[:secondary_databases]["queue"][:generated_columns]).to contain_exactly(
          a_hash_including(table: "solid_queue_jobs", column: "priority_label")
        )
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

  describe "pending migrations" do
    def static_parse(dir)
      described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
    end

    def write_migrations(dir, names)
      migrate = File.join(dir, "db", "migrate")
      FileUtils.mkdir_p(migrate)
      names.each { |name| File.write(File.join(migrate, "#{name}.rb"), "class X < ActiveRecord::Migration[7.1]; end\n") }
    end

    it "reports an out-of-order migration the structure.sql dump has not recorded" do
      Dir.mktmpdir do |dir|
        write_migrations(dir, %w[20240101000000_create_users 20240201000000_add_index 20240301000000_create_posts])
        File.write(File.join(dir, "db", "structure.sql"), <<~SQL)
          CREATE TABLE public.users (id bigint NOT NULL);

          INSERT INTO schema_migrations (version) VALUES ('20240101000000'), ('20240301000000');
        SQL

        expect(static_parse(dir)[:pending_migrations]).to eq([ { version: "20240201000000", name: "AddIndex" } ])
      end
    end

    it "reports files newer than a schema.rb version as entries" do
      Dir.mktmpdir do |dir|
        write_migrations(dir, %w[20240301000000_create_posts])
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_02_01_000000) do
            create_table "users", force: :cascade do |t|
              t.string "email"
            end
          end
        RUBY

        expect(static_parse(dir)[:pending_migrations]).to eq([ { version: "20240301000000", name: "CreatePosts" } ])
      end
    end

    it "omits the key when the schema.rb records no version" do
      Dir.mktmpdir do |dir|
        write_migrations(dir, %w[20240301000000_create_posts])
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema.define do
            create_table "users", force: :cascade do |t|
              t.string "email"
            end
          end
        RUBY

        expect(static_parse(dir)).not_to have_key(:pending_migrations)
      end
    end
  end

  describe "what a column, index, key and table declare beyond name and type" do
    def static_tables(schema)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), "test:\n  adapter: sqlite3\n")
        File.write(File.join(dir, "db", "schema.rb"), schema)
        described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
      end
    end

    let(:result) do
      static_tables(<<~RUBY)
        ActiveRecord::Schema[8.1].define(version: 2026_01_01_000001) do
          enable_extension "citext"
          create_table "accounts", comment: "Tenant accounts", force: :cascade do |t|
            t.string "name", limit: 120, null: false, collation: "C"
            t.integer "seats", unsigned: true
            t.decimal "total", precision: 10, scale: 2
            t.text "bio", size: :long
            t.unique_constraint ["name"], deferrable: :immediate, name: "uniq_name"
          end
          create_table "users", force: :cascade do |t|
            t.jsonb "data"
            t.bigint "account_id"
            t.index ["data"], name: "index_users_on_data", using: :gin
            t.index ["account_id"], name: "idx_acct", include: ["data"], order: { account_id: :desc }
          end
          add_foreign_key "users", "accounts", on_delete: :cascade, deferrable: :deferred, validate: false
        end
      RUBY
    end

    it "keeps a column's limit, precision, scale, unsigned flag and collation" do
      columns = result[:tables]["accounts"][:columns].to_h { |c| [ c[:name], c ] }

      expect(columns["name"]).to include(limit: 120, collation: "C")
      expect(columns["seats"]).to include(unsigned: true)
      expect(columns["total"]).to include(precision: 10, scale: 2)
      expect(columns["bio"]).to include(size: "long")
    end

    it "keeps the table comment and its unique constraints" do
      accounts = result[:tables]["accounts"]

      expect(accounts[:comment]).to eq("Tenant accounts")
      expect(accounts[:unique_constraints]).to eq([ { name: "uniq_name", columns: [ "name" ], deferrable: "immediate" } ])
    end

    it "keeps an index's method, included columns and order" do
      indexes = result[:tables]["users"][:indexes].to_h { |i| [ i[:name], i ] }

      expect(indexes["index_users_on_data"]).to include(using: "gin")
      expect(indexes["idx_acct"]).to include(include: [ "data" ], order: { "account_id" => "desc" })
    end

    it "keeps a foreign key's on_delete action, deferrable mode and validate: false" do
      expect(result[:tables]["users"][:foreign_keys]).to eq([
        { from_table: "users", to_table: "accounts", column: "account_id", primary_key: "id", on_delete: "cascade", deferrable: "deferred", validate: false }
      ])
    end

    it "lists the extensions the dump enables" do
      expect(result[:extensions]).to eq([ "citext" ])
    end

    # The booted tier reads the connection and the static tier reads what Rails
    # dumps from that same connection, so a table must come out the same.
    it "gives the booted answer the static tier reads from the dump of the same table" do
      connection = ActiveRecord::Base.connection
      connection.create_table(:pa_d_owners, force: true) { |t| t.string :label }
      connection.create_table(:pa_d_items, force: true) do |t|
        t.decimal :total, precision: 10, scale: 2
        t.string :code, limit: 20
        t.string :slug, collation: "NOCASE"
        t.datetime :seen_at, precision: 3
        t.datetime :made_at
        t.integer :pa_d_owner_id
        t.index [ :code, :total ], name: "idx_pa_d_code", order: { code: :desc }
        t.check_constraint "total >= 0", name: "pa_d_total_nonneg"
        t.virtual :doubled, type: :decimal, as: "total * 2", stored: true if connection.supports_virtual_columns?
      end
      connection.add_foreign_key :pa_d_items, :pa_d_owners, on_delete: :cascade

      dump = StringIO.new
      # Rails 7.2 dumps from a pool, earlier versions from a connection.
      source = ActiveRecord.version >= Gem::Version.new("7.2") ? ActiveRecord::Base.connection_pool : connection
      ActiveRecord::SchemaDumper.dump(source, dump)
      # The static tier leaves out null: true, which the booted tier spells.
      booted = introspector.call[:tables]["pa_d_items"]
      booted = booted.merge(columns: booted[:columns].map { |c| c[:null] ? c.except(:null) : c })
      static = static_tables(dump.string)[:tables]["pa_d_items"]

      expect(booted[:check_constraints]).to eq([ { name: "pa_d_total_nonneg", expression: "total >= 0" } ])
      %i[columns indexes foreign_keys primary_key check_constraints].each do |key|
        expect(booted[key]).to eq(static[key]), "#{key}: booted #{booted[key].inspect}, static #{static[key].inspect}"
      end
    ensure
      connection.drop_table(:pa_d_items, if_exists: true)
      connection.drop_table(:pa_d_owners, if_exists: true)
    end
  end

  describe "the primary key" do
    def static_parse_of(schema)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "schema.rb"), schema)
        described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:tables]
      end
    end

    let(:tables) do
      static_parse_of(<<~RUBY)
        ActiveRecord::Schema[8.1].define(version: 2026_01_01_000001) do
          create_table "orders", primary_key: ["shop_id", "id"], force: :cascade do |t|
            t.integer "shop_id", null: false
            t.integer "id", null: false
            t.string "number"
          end
          create_table "legacy_widgets", primary_key: "widget_code", id: :string, force: :cascade do |t|
            t.string "label"
          end
          create_table "posts", force: :cascade do |t|
            t.string "title"
          end
          create_table "tags_posts", id: false, force: :cascade do |t|
            t.integer "tag_id"
          end
        end
      RUBY
    end

    it "types a key written as an id: hash by its type" do
      tokens = static_parse_of(<<~RUBY)["tokens"]
        ActiveRecord::Schema[8.1].define(version: 2026_01_01_000000) do
          create_table "tokens", id: { type: :string, limit: 36 }, force: :cascade do |t|
            t.string "name"
          end
        end
      RUBY

      expect(tokens[:columns].first).to include(name: "id", type: "string", limit: 36, primary_key: true)
    end

    it "names the key on the table and flags its columns, for the implicit id too" do
      expect(tables.transform_values { |t| t[:primary_key] }).to eq(
        "orders" => %w[shop_id id], "legacy_widgets" => "widget_code", "posts" => "id", "tags_posts" => nil
      )
      expect(tables["orders"][:columns].select { |c| c[:primary_key] }.map { |c| c[:name] }).to eq(%w[shop_id id])
      expect(tables["tags_posts"][:columns].none? { |c| c[:primary_key] }).to be(true)
    end

    it "reads SQLite's inline key from structure.sql" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "structure.sql"), <<~SQL)
          CREATE TABLE "accounts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL);
        SQL
        accounts = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:tables]["accounts"]

        expect(accounts[:primary_key]).to eq("id")
        expect(accounts[:columns].first).to include(name: "id", primary_key: true)
      end
    end
  end

  describe "check constraints, enum types and generated columns" do
    let(:result) do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.1].define(version: 2026_01_01_000001) do
            create_enum "mood", ["happy", "sad"]
            create_table "users", force: :cascade do |t|
              t.integer "age"
              t.enum "mood", enum_type: "mood"
              t.virtual "age_next", type: :integer, as: "age + 1", stored: true
              t.check_constraint "age >= 0", name: "age_nonneg"
            end
          end
        RUBY
        described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
      end
    end

    it "keeps a table's check constraints, with their names, on the table" do
      expect(result[:tables]["users"][:check_constraints]).to eq([ { name: "age_nonneg", expression: "age >= 0" } ])
      expect(result[:check_constraints]).to eq([ { table: "users", name: "age_nonneg", expression: "age >= 0" } ])
    end

    it "types a generated column by its type and keeps its expression" do
      age_next = result[:tables]["users"][:columns].find { |c| c[:name] == "age_next" }

      expect(age_next).to include(type: "integer", generated: "age + 1", stored: true)
      expect(result[:generated_columns]).to eq([ { table: "users", column: "age_next", expression: "age + 1", stored: true } ])
    end

    it "names the enum type an enum column uses" do
      expect(result[:tables]["users"][:columns].find { |c| c[:name] == "mood" }).to include(type: "enum", enum_type: "mood")
    end

    it "reads a booted table's check constraints from the connection" do
      connection = ActiveRecord::Base.connection
      connection.create_table(:pa_c_posts, force: true) { |t| t.string :title }
      connection.add_check_constraint :pa_c_posts, "length(title) > 0", name: "pa_c_title_present"

      expect(introspector.call[:tables]["pa_c_posts"][:check_constraints])
        .to eq([ { name: "pa_c_title_present", expression: "length(title) > 0" } ])
    ensure
      connection.drop_table(:pa_c_posts, if_exists: true)
    end
  end

  describe "a structure.sql that names no table it can read" do
    it "says the file is there rather than missing" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "structure.sql"), "-- nothing yet\n")
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result).not_to have_key(:unavailable)
        expect(result[:total_tables]).to eq(0)
        expect(result[:note]).to include("db/structure.sql")
      end
    end
  end

  describe "a column schema.rb writes with t.column" do
    it "reads it with the type it names" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.1].define(version: 2026_01_01_000001) do
            create_table "things", force: :cascade do |t|
              t.column "kind", "enum('a','b')"
            end
          end
        RUBY
        things = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:tables]["things"]

        expect(things[:columns].map { |c| [ c[:name], c[:type] ] }).to eq([ %w[id bigint], [ "kind", "enum('a','b')" ] ])
        expect(things).not_to have_key(:unread_calls)
      end
    end
  end

  describe "a schema.rb dumped with more than one schema" do
    it "names a table in public by its bare name, as the app sees it" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          ActiveRecord::Schema[8.1].define(version: 2026_01_01_000001) do
            create_schema "other"
            create_enum "public.mood", ["happy", "sad"]
            create_table "other.widgets", force: :cascade do |t|
              t.string "n"
            end
            create_table "public.posts", force: :cascade do |t|
              t.bigint "user_id"
              t.enum "mood", enum_type: "public.mood"
            end
            create_table "public.users", force: :cascade do |t|
              t.string "email", null: false
            end
            add_index "public.posts", ["user_id"], name: "idx_posts_user"
            add_foreign_key "public.posts", "public.users"
          end
        RUBY
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:tables].keys).to eq(%w[other.widgets posts users])
        expect(result[:tables]["users"][:columns].map { |c| c[:name] }).to eq(%w[id email])
        expect(result[:tables]["posts"][:indexes].map { |i| i[:name] }).to eq(%w[idx_posts_user])
        expect(result[:tables]["posts"][:foreign_keys]).to eq([ { from_table: "posts", to_table: "users", column: "user_id", primary_key: "id" } ])
        expect(result[:enum_types]).to eq([ { name: "mood", values: %w[happy sad] } ])
        expect(result[:tables]["posts"][:columns].find { |c| c[:name] == "mood" }).to include(enum_type: "mood")
      end
    end
  end

  describe "views, virtual tables and a table the dumper could not write" do
    def static_of(file, content)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", file), content)
        described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
      end
    end

    it "lists scenic's views from schema.rb with their SQL" do
      tables = static_of("schema.rb", <<~RUBY)[:tables]
        ActiveRecord::Schema[8.1].define(version: 2026_01_01_000002) do
          create_table "users", force: :cascade do |t|
            t.string "email", null: false
          end

          create_view "active_users", sql_definition: <<-SQL
              SELECT users.id, users.email FROM users WHERE users.active;
          SQL
          create_view "user_stats", materialized: true, sql_definition: <<-SQL
              SELECT count(*) AS total FROM users;
          SQL
        end
      RUBY

      expect(tables.keys).to eq(%w[users active_users user_stats])
      expect(tables["active_users"]).to include(kind: "view", sql: "SELECT users.id, users.email FROM users WHERE users.active;", columns: [])
      expect(tables["user_stats"]).to include(kind: "materialized_view", sql: "SELECT count(*) AS total FROM users;")
    end

    def view_with_index_dumps
      rb = static_of("schema.rb", <<~RUBY)
        ActiveRecord::Schema[8.1].define(version: 2026_01_01_000002) do
          create_table "users", force: :cascade do |t|
            t.string "email", null: false
          end

          create_view "user_stats", materialized: true, sql_definition: <<-SQL
              SELECT email, count(*) AS total FROM users GROUP BY email;
          SQL
          add_index "user_stats", ["email"], name: "index_user_stats_on_email", unique: true
        end
      RUBY
      sql = static_of("structure.sql", <<~SQL)
        CREATE TABLE public.users (
            id bigint NOT NULL,
            email character varying
        );
        CREATE MATERIALIZED VIEW public.user_stats AS
         SELECT email, count(*) AS total
           FROM public.users
          GROUP BY email
          WITH NO DATA;
        CREATE UNIQUE INDEX index_user_stats_on_email ON public.user_stats USING btree (email);
      SQL

      [ rb, sql ]
    end

    it "counts a view apart from the tables" do
      expect(view_with_index_dumps.map { |result| result[:total_tables] }).to eq([ 1, 1 ])
    end

    it "keeps the indexes declared on a materialized view" do
      view_with_index_dumps.each do |result|
        expect(result[:tables]["user_stats"][:indexes]).to eq([ { name: "index_user_stats_on_email", columns: [ "email" ], unique: true } ])
      end
    end

    it "lists a SQLite virtual table from schema.rb with its columns" do
      tables = static_of("schema.rb", <<~RUBY)[:tables]
        ActiveRecord::Schema[8.1].define(version: 2026_01_01_000001) do
          create_table "docs", force: :cascade do |t|
            t.string "title"
          end
          create_virtual_table "docs_fts", "fts5", ["title", "body", "tokenize='porter'"]
        end
      RUBY

      expect(tables["docs_fts"]).to include(kind: "virtual_table", module: "fts5", columns: [ { name: "title" }, { name: "body" } ])
    end

    it "lists a table the dumper could not describe, with its reason" do
      tables = static_of("schema.rb", <<~RUBY)[:tables]
        ActiveRecord::Schema[7.0].define(version: 2026_01_01_000001) do
          create_table "docs", force: :cascade do |t|
            t.string "title"
          end

        # Could not dump table "boxes" because of following StandardError
        #   Unknown type 'virtual' for column 'area'

        end
      RUBY

      expect(tables["boxes"]).to include(columns: [], not_dumped: "StandardError: Unknown type 'virtual' for column 'area'")
    end

    it "reads views and virtual tables from structure.sql" do
      tables = static_of("structure.sql", <<~SQL)[:tables]
        CREATE TABLE IF NOT EXISTS "users" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "active" boolean);
        CREATE VIEW active_users AS SELECT id FROM users WHERE active;
        CREATE VIRTUAL TABLE docs_fts USING fts5 (title, body)
        /* docs_fts(title,body) */;
        CREATE TABLE IF NOT EXISTS 'docs_fts_data'(id INTEGER PRIMARY KEY, block BLOB);
      SQL

      expect(tables.keys).to eq(%w[users active_users docs_fts])
      expect(tables["active_users"]).to include(kind: "view", sql: "SELECT id FROM users WHERE active")
      expect(tables["docs_fts"]).to include(kind: "virtual_table", module: "fts5", columns: [ { name: "title" }, { name: "body" } ])
    end

    it "reads a PostgreSQL materialized view from structure.sql" do
      tables = static_of("structure.sql", <<~SQL)[:tables]
        CREATE TABLE public.users (
            id bigint NOT NULL
        );
        CREATE MATERIALIZED VIEW public.user_stats AS
         SELECT count(*) AS total
           FROM public.users
          WITH NO DATA;
      SQL

      expect(tables["user_stats"]).to include(kind: "materialized_view", sql: "SELECT count(*) AS total\n   FROM public.users")
    end

    it "names the extensions a structure.sql dump creates, as the connection names them" do
      result = static_of("structure.sql", <<~SQL)
        CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA public;
        CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
        CREATE EXTENSION pg_trgm;
        CREATE TABLE public.users (
            id bigint NOT NULL
        );
      SQL

      expect(result[:extensions]).to eq(%w[hstore extensions.uuid-ossp pg_trgm])
    end

    describe "extension names against the connection's current schema" do
      let(:dump) do
        <<~SQL
          CREATE SCHEMA app;
          CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA app;
          CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA public;
          CREATE TABLE public.users (
              id bigint NOT NULL
          );
        SQL
      end

      def extensions_with(database_yml: nil, rails: nil)
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "db", "structure.sql"), dump)
          File.write(File.join(dir, "config", "database.yml"), "#{RailsAiContext.environment_name}:\n#{database_yml}") if database_yml
          if rails
            File.write(File.join(dir, "Gemfile"), "gem \"rails\"\n")
            File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (#{rails})\n\nDEPENDENCIES\n  rails\n")
          end
          described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:extensions]
        end
      end

      it "names an extension in the first search path schema bare" do
        expect(extensions_with(database_yml: "  adapter: postgresql\n  schema_search_path: \"app,public\"\n"))
          .to eq(%w[pg_trgm public.hstore])
      end

      it "reads the search path of the primary database in a multi-database config" do
        yml = "  primary:\n    adapter: postgresql\n    schema_search_path: \" App , public\"\n  cache:\n    adapter: postgresql\n"
        expect(extensions_with(database_yml: yml)).to eq(%w[pg_trgm public.hstore])
      end

      it "takes public as the current schema with no search path" do
        expect(extensions_with(database_yml: "  adapter: postgresql\n")).to eq(%w[app.pg_trgm hstore])
      end

      it "takes public as the current schema when the path starts with $user" do
        expect(extensions_with(database_yml: "  adapter: postgresql\n  schema_search_path: '\"$user\", public'\n"))
          .to eq(%w[app.pg_trgm hstore])
      end

      it "names every extension bare before Rails 8.0, whose connection reads extname alone" do
        expect(extensions_with(database_yml: "  adapter: postgresql\n", rails: "7.2.2")).to eq(%w[pg_trgm hstore])
      end
    end

    describe "tables in the schemas on the search path" do
      def static_with(file, content, database_yml)
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "db", file), content)
          File.write(File.join(dir, "config", "database.yml"), "#{RailsAiContext.environment_name}:\n  adapter: postgresql\n#{database_yml}")
          described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        end
      end

      let(:structure) do
        <<~SQL
          CREATE SCHEMA app;
          CREATE SCHEMA audit;
          CREATE TABLE app.widgets (
              id bigint NOT NULL,
              owner_id bigint
          );
          CREATE TABLE app.users (
              id bigint NOT NULL,
              tenant_column text
          );
          CREATE TABLE public.users (
              id bigint NOT NULL,
              shared_column text
          );
          CREATE TABLE public.notes (
              id bigint NOT NULL
          );
          CREATE TABLE audit.events (
              id bigint NOT NULL
          );
          ALTER TABLE ONLY app.widgets
              ADD CONSTRAINT fk_owner FOREIGN KEY (owner_id) REFERENCES app.users(id);
        SQL
      end

      it "names a structure.sql table in any search path schema bare, the first schema winning a shared name" do
        tables = static_with("structure.sql", structure, "  schema_search_path: \"app,public\"\n")[:tables]

        expect(tables.keys).to contain_exactly("widgets", "users", "notes")
        expect(tables["users"][:columns].map { |c| c[:name] }).to eq(%w[id tenant_column])
        expect(tables["widgets"][:foreign_keys].first).to include(to_table: "users")
      end

      it "keeps today's tables with no search path" do
        tables = static_with("structure.sql", structure, "")[:tables]

        expect(tables.keys).to contain_exactly("users", "notes")
        expect(tables["users"][:columns].map { |c| c[:name] }).to eq(%w[id shared_column])
      end

      it "reads $user as the configured username when the dump creates that schema" do
        tables = static_with("structure.sql", structure, "  username: audit\n")[:tables]

        expect(tables.keys).to contain_exactly("users", "notes", "events")
      end

      it "skips $user when the dump creates no schema by the username" do
        tables = static_with("structure.sql", structure, "  username: postgres\n")[:tables]

        expect(tables.keys).to contain_exactly("users", "notes")
      end

      it "names a schema.rb table in any search path schema bare, the first schema winning a shared name" do
        rb = <<~RUBY
          ActiveRecord::Schema[8.1].define(version: 2026_01_01_000001) do
            create_schema "app"

            create_table "app.users", force: :cascade do |t|
              t.string "tenant_column"
            end

            create_table "app.widgets", force: :cascade do |t|
              t.bigint "owner_id"
            end

            create_table "public.notes", force: :cascade do |t|
            end

            create_table "public.users", force: :cascade do |t|
              t.string "shared_column"
            end

            add_foreign_key "app.widgets", "app.users", column: "owner_id"
          end
        RUBY
        tables = static_with("schema.rb", rb, "  schema_search_path: \"app,public\"\n")[:tables]

        expect(tables.keys).to contain_exactly("users", "widgets", "notes")
        expect(tables["users"][:columns].map { |c| c[:name] }).to eq(%w[id tenant_column])
        expect(tables["widgets"][:foreign_keys].first).to include(to_table: "users")
      end
    end

    it "skips a view or virtual table it cannot read instead of failing" do
      rb = static_of("schema.rb", <<~RUBY)[:tables]
        ActiveRecord::Schema[8.1].define(version: 2026_01_01_000001) do
          create_table "docs", force: :cascade do |t|
            t.string "title"
          end
          create_view view_name, sql_definition: sql
          create_view "bare"
          create_virtual_table "loose", "fts5"
        end
      RUBY
      sql = static_of("structure.sql", <<~SQL)[:tables]
        CREATE TABLE "docs" ("id" integer PRIMARY KEY);
        CREATE VIRTUAL TABLE plain USING rtree;
        CREATE VIEW broken
      SQL

      expect(rb.keys).to eq(%w[docs bare loose])
      expect(rb["bare"]).to eq(kind: "view", columns: [], indexes: [], foreign_keys: [])
      expect(rb["loose"][:columns]).to eq([])
      expect(sql.keys).to eq(%w[docs plain])
    end

    it "tells PostgreSQL's materialized views apart and leaves out an extension's views" do
      connection = double("pg", views: %w[user_stats geometry_columns], columns: [], indexes: [], native_database_types: {})
      allow(connection).to receive(:select_rows).and_return([ [ "user_stats", "m", false ], [ "geometry_columns", "v", true ] ])
      allow(introspector).to receive_messages(connection: connection, adapter_name: "PostgreSQL")

      tables = introspector.send(:add_live_relations, {})
      expect(tables.keys).to eq(%w[user_stats])
      expect(tables["user_stats"]).to include(kind: "materialized_view")
    end

    it "reads the indexes on a booted materialized view" do
      index = ActiveRecord::ConnectionAdapters::IndexDefinition.new("user_stats", "index_user_stats_on_email", true, [ "email" ])
      connection = double("pg", views: %w[user_stats], columns: [], native_database_types: {})
      allow(connection).to receive(:select_rows).and_return([ [ "user_stats", "m", false ] ])
      allow(connection).to receive(:indexes).with("user_stats").and_return([ index ])
      allow(introspector).to receive_messages(connection: connection, adapter_name: "PostgreSQL")

      expect(introspector.send(:add_live_relations, {})["user_stats"][:indexes])
        .to eq([ { name: "index_user_stats_on_email", columns: [ "email" ], unique: true } ])
    end

    it "lists a booted view with the connection's columns and the dump's SQL" do
      connection = ActiveRecord::Base.connection
      connection.create_table(:pa_v_users, force: true) { |t| t.string :email }
      connection.execute("CREATE VIEW pa_v_active AS SELECT id, email FROM pa_v_users")
      connection.execute("CREATE VIRTUAL TABLE pa_v_fts USING fts5 (title, body)")

      tables = introspector.call[:tables]
      expect(tables["pa_v_active"]).to include(kind: "view")
      expect(tables["pa_v_active"][:columns].map { |c| c[:name] }).to eq(%w[id email])
      expect(tables["pa_v_fts"]).to include(kind: "virtual_table", module: "fts5", columns: [ { name: "title" }, { name: "body" } ])
      expect(tables.keys.grep(/\Apa_v_fts_/)).to eq([])
    ensure
      connection.execute("DROP VIEW IF EXISTS pa_v_active")
      connection.execute("DROP TABLE IF EXISTS pa_v_fts")
      connection.drop_table(:pa_v_users, if_exists: true)
    end

    it "reads a booted view's SQL and a generated column's expression from structure.sql" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "config/application.rb"), "class App < Rails::Application\n  config.active_record.schema_format = :sql\nend\n")
        File.write(File.join(dir, "db/structure.sql"), <<~SQL)
          CREATE TABLE pa_s_users (id integer PRIMARY KEY, name varchar, upper_name varchar GENERATED ALWAYS AS (upper(name)) VIRTUAL);
          CREATE VIEW pa_s_active AS SELECT id, name FROM pa_s_users;
        SQL
        booted = described_class.new(double("app", root: Pathname.new(dir)))
        connection = double("mysql", views: %w[pa_s_active], columns: [])
        allow(booted).to receive_messages(connection: connection, adapter_name: "Mysql2")

        expect(booted.send(:add_live_relations, {})["pa_s_active"]).to include(sql: "SELECT id, name FROM pa_s_users")
        expect(booted.send(:declared_generated, "pa_s_users", "upper_name")).to eq("upper(name)")
      end
    end
  end

  describe "the dump file the app configures" do
    def static_with(files)
      Dir.mktmpdir do |dir|
        files.each do |path, content|
          FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
          File.write(File.join(dir, path), content)
        end
        yield described_class.new(RailsAiContext::StaticApp.new(dir)).static_call, dir
      end
    end

    let(:one_table_rb) do
      ->(name) { "ActiveRecord::Schema[8.1].define(version: 2026_01_01_000001) do\n  create_table \"#{name}\" do |t|\n    t.string \"x\"\n  end\nend\n" }
    end
    let(:migration) { { "db/migrate/20260101000000_create_notes.rb" => "class CreateNotes < ActiveRecord::Migration[8.1]\n  def change\n    create_table :notes\n  end\nend\n" } }

    it "reads the file database.yml names with schema_dump" do
      files = { "config/database.yml" => "#{RailsAiContext.environment_name}:\n  adapter: sqlite3\n  database: storage/development.sqlite3\n  schema_dump: schema_sqlite.rb\n",
                "db/schema_sqlite.rb" => one_table_rb.call("widgets") }.merge(migration)
      static_with(files) do |result, dir|
        expect(result[:tables].keys).to eq(%w[widgets])
        expect(result[:note]).to start_with("Parsed from db/schema_sqlite.rb")
        expect(RailsAiContext::Introspectors::SchemaReader.for(dir).tables.keys).to eq(%w[widgets])
      end
    end

    it "names the configured dump when neither it nor a migration exists" do
      files = { "config/database.yml" => "#{RailsAiContext.environment_name}:\n  adapter: sqlite3\n  schema_dump: main_schema.rb\n" }
      static_with(files) { |result, _| expect(result[:unavailable]).to eq("No db/main_schema.rb or migrations found") }
      static_with(files.merge("db/queue_schema.rb" => one_table_rb.call("jobs"))) do |result, _|
        expect(result[:note]).to eq("The primary database has no tables yet: no db/main_schema.rb or migrations found.")
      end
    end

    it "reads the dump on disk in both tiers when the configured one is missing" do
      files = { "config/database.yml" => "#{RailsAiContext.environment_name}:\n  adapter: sqlite3\n  schema_dump: main_schema.rb\n",
                "db/schema.rb" => one_table_rb.call("widgets") }
      static_with(files) do |result, dir|
        expect(result[:tables].keys).to eq(%w[widgets])
        booted = described_class.new(double("app", root: Pathname.new(dir)))
        expect(booted.send(:schema_reader).tables.keys).to eq(%w[widgets])
        expect(booted.send(:declared_dump).tables.keys).to eq(%w[widgets])
      end
    end

    it "compares a configured dump against db/migrate, the primary database's migrations" do
      files = { "config/database.yml" => "#{RailsAiContext.environment_name}:\n  adapter: sqlite3\n  schema_dump: schema_sqlite.rb\n",
                "db/schema_sqlite.rb" => one_table_rb.call("widgets").sub("2026_01_01_000001", "2025_01_01_000000") }.merge(migration)
      static_with(files) do |result, _|
        expect(result[:pending_migrations]).to eq([ { version: "20260101000000", name: "CreateNotes" } ])
      end
    end

    it "types a configured primary dump's implicit key by the primary database's adapter" do
      yml = "#{RailsAiContext.environment_name}:\n  queue:\n    adapter: sqlite3\n  primary:\n    adapter: postgresql\n    schema_dump: main.rb\n"
      static_with({ "config/database.yml" => yml, "db/main.rb" => one_table_rb.call("widgets") }) do |result, _|
        expect(result[:tables]["widgets"][:columns].first).to include(name: "id", type: "bigint")
      end
    end

    it "reads structure.sql first when the app sets schema_format = :sql" do
      files = { "config/application.rb" => "module App\n  class Application < Rails::Application\n    # config.active_record.schema_format = :ruby\n    config.active_record.schema_format = :sql\n  end\nend\n",
                "db/schema.rb" => one_table_rb.call("stale_things"),
                "db/structure.sql" => "CREATE TABLE \"fresh_things\" (\"id\" integer PRIMARY KEY);\n" }
      static_with(files) do |result, dir|
        expect(result[:tables].keys).to eq(%w[fresh_things])
        expect(RailsAiContext::Introspectors::SchemaReader.for(dir).source).to eq(:structure_sql)
      end
    end

    it "takes schema_format however the environment file or an initializer spells the assignment" do
      dump = { "db/schema.rb" => one_table_rb.call("stale_things"),
               "db/structure.sql" => "CREATE TABLE \"fresh_things\" (\"id\" integer PRIMARY KEY);\n" }
      [ { "config/environments/#{RailsAiContext.environment_name}.rb" => "Rails.application.config.active_record.schema_format = :sql\n" },
        { "config/initializers/ar.rb" => "Rails.application.configure do\n  config.active_record.schema_format = :sql\nend\n" },
        { "config/initializers/ar.rb" => "ActiveRecord.schema_format = :sql\n" } ].each do |config|
        static_with(dump.merge(config)) { |result, _| expect(result[:tables].keys).to eq(%w[fresh_things]), config.inspect }
      end
    end

    def lockfile(activerecord)
      "GEM\n  remote: https://rubygems.org/\n  specs:\n    activerecord (#{activerecord})\n\nDEPENDENCIES\n  activerecord\n"
    end

    it "takes the format database.yml gives the database over the app's" do
      files = { "config/database.yml" => "#{RailsAiContext.environment_name}:\n  primary:\n    adapter: sqlite3\n    schema_format: sql\n    schema_dump: primary.sql\n",
                "db/schema.rb" => one_table_rb.call("stale_things"),
                "db/primary.sql" => "CREATE TABLE \"fresh_things\" (\"id\" integer PRIMARY KEY);\n" }
      static_with(files) { |result, _| expect(result[:tables].keys).to eq(%w[fresh_things]) }
      static_with(files.merge("Gemfile.lock" => lockfile("8.0.3"))) { |result, _| expect(result[:tables].keys).to eq(%w[fresh_things]) }
    end

    it "leaves database.yml's schema_format to Rails versions that read it" do
      files = { "config/database.yml" => "#{RailsAiContext.environment_name}:\n  adapter: sqlite3\n  schema_format: sql\n",
                "Gemfile.lock" => lockfile("8.0.2"),
                "db/schema.rb" => one_table_rb.call("loaded_things"),
                "db/structure.sql" => "CREATE TABLE \"ignored_things\" (\"id\" integer PRIMARY KEY);\n" }
      static_with(files) { |result, _| expect(result[:tables].keys).to eq(%w[loaded_things]) }
    end

    it "names no configured file when schema_dump is false, and an environment file's format wins" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config/environments"))
        File.write(File.join(dir, "config/database.yml"), "#{RailsAiContext.environment_name}:\n  adapter: sqlite3\n  schema_dump: false\n")
        File.write(File.join(dir, "config/application.rb"), "config.active_record.schema_format = :ruby\n")
        File.write(File.join(dir, "config/environments/#{RailsAiContext.environment_name}.rb"), "config.active_record.schema_format = :sql\n")

        expect(RailsAiContext::Introspectors::SchemaDumpPath.candidates(dir))
          .to eq([ [ :sql, File.join(dir, "db/structure.sql") ], [ :ruby, File.join(dir, "db/schema.rb") ] ])
      end
    end

    it "says the configured dump is too large instead of answering from another file" do
      allow(RailsAiContext.configuration).to receive(:max_schema_file_size).and_return(50)
      files = { "config/database.yml" => "#{RailsAiContext.environment_name}:\n  adapter: sqlite3\n  schema_dump: big.rb\n",
                "db/big.rb" => one_table_rb.call("fresh_things"),
                "db/structure.sql" => "CREATE TABLE \"stale\" (\"id\" integer);\n" }
      static_with(files) do |result, dir|
        expect(RailsAiContext::Introspectors::SchemaDumpPath.candidates(dir).first).to eq([ :ruby, File.join(dir, "db/big.rb") ])
        expect(result[:error]).to start_with("db/big.rb too large")
        expect(result[:tables]).to be_nil
      end
    end

    it "falls back to the usual files when the configured name is unusable" do
      files = { "config/database.yml" => "#{RailsAiContext.environment_name}:\n  adapter: sqlite3\n  schema_dump: ../../outside.rb\n  bad: [\n",
                "db/schema.rb" => one_table_rb.call("things") }
      static_with(files) { |result, _| expect(result[:tables].keys).to eq(%w[things]) }

      files = { "config/database.yml" => "#{RailsAiContext.environment_name}:\n  adapter: sqlite3\n  schema_dump: ../../outside.rb\n",
                "db/schema.rb" => one_table_rb.call("things") }
      static_with(files) { |result, _| expect(result[:tables].keys).to eq(%w[things]) }
    end
  end
end
