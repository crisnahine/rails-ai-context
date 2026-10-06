# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::MigrationAdvisor do
  describe ".call" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: {
          tables: {
            "users" => {
              columns: [
                { name: "email", type: "string" },
                { name: "name", type: "string" }
              ]
            },
            "posts" => {
              columns: [
                { name: "title", type: "string" },
                { name: "user_id", type: "integer" }
              ]
            }
          }
        },
        models: {
          User: { associations: [ { macro: :has_many, name: :posts, class_name: "Post" } ] },
          Post: { associations: [ { macro: :belongs_to, name: :user, class_name: "User" } ] }
        }
      })
    end

    # Underscoring a namespaced model asks for `admin/action_logs`, which the
    # identifier guard then rejects as invalid - a dead end for a model the
    # payload can name a table for.
    it "takes a namespaced model's table from the model tier" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" } ] } } },
        models: { "Admin::Entry" => { table_name: "posts" } }
      })

      response = described_class.call(action: "add_column", table: "Admin::Entry", column: "phone", type: "string")

      expect(response.content.first[:text]).to include("add_column :posts, :phone, :string")
    end

    it "generates add_column migration" do
      response = described_class.call(action: "add_column", table: "users", column: "phone", type: "string")
      text = response.content.first[:text]
      expect(text).to include("add_column :users, :phone, :string")
      expect(text).to include("Reversible:** Yes")
    end

    it "warns when adding a column that already exists" do
      response = described_class.call(action: "add_column", table: "users", column: "email", type: "string")
      text = response.content.first[:text]
      expect(text).to include("already exists")
      expect(text).to include("DuplicateColumn")
    end

    it "warns when adding an association FK that already exists" do
      response = described_class.call(action: "add_association", table: "posts", column: "user")
      text = response.content.first[:text]
      expect(text).to include("already exists")
    end

    it "warns when removing a nonexistent column" do
      response = described_class.call(action: "remove_column", table: "users", column: "totally_fake")
      text = response.content.first[:text]
      expect(text).to include("does not exist")
    end

    it "warns when renaming a nonexistent column" do
      response = described_class.call(action: "rename_column", table: "users", column: "totally_fake", new_name: "still_fake")
      text = response.content.first[:text]
      expect(text).to include("does not exist")
    end

    it "warns when adding index on nonexistent column" do
      response = described_class.call(action: "add_index", table: "users", column: "totally_fake")
      text = response.content.first[:text]
      expect(text).to include("does not exist")
    end

    it "warns when changing type of nonexistent column" do
      response = described_class.call(action: "change_type", table: "users", column: "totally_fake", type: "text")
      text = response.content.first[:text]
      expect(text).to include("does not exist")
    end

    it "warns when removing column from nonexistent table" do
      response = described_class.call(action: "remove_column", table: "nonexistent_table", column: "name")
      text = response.content.first[:text]
      expect(text).to include("not found")
    end

    it "generates remove_column migration with warning" do
      response = described_class.call(action: "remove_column", table: "users", column: "name")
      text = response.content.first[:text]
      expect(text).to include("remove_column :users, :name")
      expect(text).to include("Data loss")
    end

    # add_index names the index index_<table>_on_<col> and fails only when
    # that name exists. A composite index that merely contains the column is
    # no collision, and it is exactly when the new index is worth adding.
    describe "the duplicate-index warning" do
      def advise(indexes)
        allow(described_class).to receive(:cached_context).and_return({
          schema: { tables: { "posts" => {
            columns: [ { name: "blog_id", type: "integer" }, { name: "author_id", type: "integer" } ],
            indexes: indexes
          } } },
          models: {}
        })
        described_class.call(action: "add_index", table: "posts", column: "author_id").content.first[:text]
      end

      it "warns when the index add_index would name already exists" do
        text = advise([ { name: "index_posts_on_author_id", columns: %w[author_id], unique: false } ])

        expect(text).to include("already exists")
      end

      it "does not warn when the column only sits in a composite index" do
        text = advise([ { name: "index_posts_on_blog_id_and_author_id", columns: %w[blog_id author_id], unique: false } ])

        expect(text).not_to include("already exists")
      end
    end

    it "generates add_index migration" do
      response = described_class.call(action: "add_index", table: "posts", column: "title")
      text = response.content.first[:text]
      expect(text).to include("add_index :posts, :title")
    end

    it "generates add_association migration" do
      response = described_class.call(action: "add_association", table: "posts", column: "categories")
      text = response.content.first[:text]
      expect(text).to include("add_reference")
      expect(text).to include("belongs_to")
      expect(text).to include("has_many")
    end

    it "generates create_table migration" do
      response = described_class.call(action: "create_table", table: "tags", column: "name:string,color:string")
      text = response.content.first[:text]
      expect(text).to include("create_table :tags")
      expect(text).to include("t.string :name")
    end

    it "warns about irreversible change_type" do
      response = described_class.call(action: "change_type", table: "posts", column: "title", type: "text")
      text = response.content.first[:text]
      expect(text).to include("Reversible:** No")
      expect(text).to include("data loss")
    end

    it "shows affected models" do
      response = described_class.call(action: "add_column", table: "users", column: "age", type: "integer")
      text = response.content.first[:text]
      expect(text).to include("Affected Models")
    end

    context "with a model whose table is not the camelized table name" do
      before do
        allow(described_class).to receive(:cached_context).and_return({
          schema: { tables: { "admin_action_logs" => { columns: [ { name: "note", type: "string" } ] } } },
          models: {
            "Admin::ActionLog" => {
              table_name: "admin_action_logs",
              associations: [ { macro: :belongs_to, name: :account, class_name: "Account" } ]
            },
            "Account" => {
              table_name: "accounts",
              associations: [ { macro: :has_many, name: :action_logs, class_name: "Admin::ActionLog" } ]
            }
          }
        })
      end

      it "names the model that records the table" do
        response = described_class.call(action: "add_column", table: "Admin::ActionLog", column: "note2", type: "string")

        expect(response.content.first[:text])
          .to include("- **Admin::ActionLog** - directly affected (table: admin_action_logs)")
      end

      it "names the association that points at that model" do
        response = described_class.call(action: "add_column", table: "Admin::ActionLog", column: "note2", type: "string")

        expect(response.content.first[:text]).to include("- **Account** - has_many :action_logs")
      end

      it "points remove_column's ignored_columns step at the model's own file" do
        allow(described_class).to receive(:strong_migrations_gem_present?).and_return(true)
        response = described_class.call(action: "remove_column", table: "Admin::ActionLog", column: "note")

        expect(response.content.first[:text]).to include("app/models/admin/action_log.rb")
      end
    end

    # ignored_columns belongs on the class that owns the table, and every STI
    # class on it records the same table, so the first name in payload order
    # could be a child.
    context "with an STI family on one table" do
      before do
        described_class.reset_cache!
        allow(described_class).to receive(:cached_context).and_return({
          schema: { tables: { "users" => { columns: [ { name: "note", type: "string" } ] } } },
          models: {
            "AdminUser" => { table_name: "users", file: "app/models/admin_user.rb" },
            "User" => { table_name: "users", file: "app/models/user.rb" }
          }
        })
      end

      it "points ignored_columns at the base's file, not a child's" do
        allow(described_class).to receive(:strong_migrations_gem_present?).and_return(true)
        response = described_class.call(action: "remove_column", table: "users", column: "note")

        expect(response.content.first[:text]).to include("app/models/user.rb")
        expect(response.content.first[:text]).not_to include("app/models/admin_user.rb")
      end
    end

    it "omits the Affected Models heading when no model uses the table" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { tables: { "flipper_gates" => { columns: [] } } }, models: {}
      })

      response = described_class.call(action: "add_column", table: "flipper_gates", column: "note", type: "string")

      expect(response.content.first[:text]).not_to include("Affected Models")
    end

    it "generates rename_column with new_name parameter" do
      response = described_class.call(action: "rename_column", table: "users", column: "name", new_name: "full_name")
      text = response.content.first[:text]
      expect(text).to include("rename_column :users, :name, :full_name")
      expect(text).to include("Reversible:** Yes")
      expect(text).to include(":name")
      expect(text).to include(":full_name")
    end

    it "falls back to type param for rename_column backward compat" do
      response = described_class.call(action: "rename_column", table: "users", column: "name", type: "full_name")
      text = response.content.first[:text]
      expect(text).to include("rename_column :users, :name, :full_name")
    end

    it "rejects invalid table names with special characters" do
      response = described_class.call(action: "add_column", table: "users; DROP TABLE", column: "name")
      text = response.content.first[:text]
      expect(text).to include("Invalid table name")
    end

    it "rejects invalid column names with special characters" do
      response = described_class.call(action: "add_column", table: "users", column: "name; DROP")
      text = response.content.first[:text]
      expect(text).to include("Invalid column name")
    end

    it "allows column definition strings for create_table" do
      response = described_class.call(action: "create_table", table: "tags", column: "name:string,slug:string")
      text = response.content.first[:text]
      expect(text).to include("create_table :tags")
      expect(text).to include("t.string :name")
    end
  end

  describe "Strong Migrations integration" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "PostgreSQL", tables: { "users" => { columns: [ { name: "email", type: "string" } ] } } },
        models: {}
      })
    end

    context "when strong_migrations gem is absent" do
      before { allow(described_class).to receive(:strong_migrations_gem_present?).and_return(false) }

      it "does not include the warnings section for remove_column" do
        response = described_class.call(action: "remove_column", table: "users", column: "email")
        text = response.content.first[:text]
        expect(text).not_to include("Strong Migrations Warnings")
      end
    end

    context "when strong_migrations gem is present on a PostgreSQL app" do
      before { allow(described_class).to receive(:strong_migrations_gem_present?).and_return(true) }

      it "warns about remove_column needing safety_assured + ignored_columns" do
        response = described_class.call(action: "remove_column", table: "users", column: "email")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("ignored_columns")
        expect(text).to include("safety_assured")
      end

      it "warns about rename_column being unsafe under load" do
        response = described_class.call(action: "rename_column", table: "users", column: "email", new_name: "email_address")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("unsafe under load")
      end

      it "warns about change_type blocking writes" do
        response = described_class.call(action: "change_type", table: "users", column: "email", type: "text")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("blocks writes")
      end

      it "warns about add_index without :concurrently" do
        response = described_class.call(action: "add_index", table: "users", column: "email")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("algorithm: :concurrently")
      end

      it "warns about add_index without :concurrently on a PostGIS app" do
        allow(described_class).to receive(:cached_context).and_return({
          schema: { adapter: "PostGIS", tables: { "users" => { columns: [ { name: "email", type: "string" } ] } } },
          models: {}
        })

        text = described_class.call(action: "add_index", table: "users", column: "email").content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
      end

      it "does not warn about add_index when :concurrently is already specified" do
        response = described_class.call(action: "add_index", table: "users", column: "email", options: "algorithm: :concurrently")
        text = response.content.first[:text]
        expect(text).not_to include("Strong Migrations Warnings")
      end

      it "warns about add_association needing two-step foreign key validation" do
        response = described_class.call(action: "add_association", table: "users", column: "tenant")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("validate: false")
        expect(text).to include("validate_foreign_key")
      end

      it "warns about NOT NULL add_column without default" do
        response = described_class.call(action: "add_column", table: "users", column: "phone", type: "string", options: "null: false")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("NOT NULL")
      end

      it "does not warn about add_column when nullable" do
        response = described_class.call(action: "add_column", table: "users", column: "phone", type: "string")
        text = response.content.first[:text]
        expect(text).not_to include("Strong Migrations Warnings")
      end
    end

    context "when strong_migrations gem is present on a MySQL/Trilogy app" do
      before do
        allow(described_class).to receive(:strong_migrations_gem_present?).and_return(true)
        allow(described_class).to receive(:cached_context).and_return({
          schema: { adapter: "Trilogy", tables: { "users" => { columns: [ { name: "email", type: "string" } ] } } },
          models: {}
        })
      end

      it "does not raise the Postgres-only :concurrently warning for add_index" do
        response = described_class.call(action: "add_index", table: "users", column: "email")
        text = response.content.first[:text]
        expect(text).not_to include("Strong Migrations Warnings")
        expect(text).not_to include("ACCESS EXCLUSIVE")
      end

      it "describes online DDL instead of algorithm: :concurrently in the add_index note" do
        response = described_class.call(action: "add_index", table: "users", column: "email")
        text = response.content.first[:text]
        expect(text).to include("online DDL")
        expect(text).not_to include("**Note:** For large tables, consider `algorithm: :concurrently` (PostgreSQL) to avoid locking")
      end

      it "warns about add_association using foreign_key_checks instead of the Postgres two-step validation" do
        response = described_class.call(action: "add_association", table: "users", column: "tenant")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("foreign_key_checks")
        expect(text).not_to include("validate_foreign_key")
      end
    end
  end
  describe "the migration superclass version" do
    def text_for(**args)
      described_class.call(**args).content.first[:text]
    end

    context "when the app's context names a Rails version" do
      before do
        allow(described_class).to receive(:cached_context).and_return({
          rails_version: "8.1.3.1",
          schema: { adapter: "PostgreSQL", tables: { "accounts" => { columns: [ { name: "domain", type: "string" } ] } } },
          models: {}
        })
      end

      it "stamps the app's version, not the Rails the gem process loaded" do
        expect(text_for(action: "add_index", table: "accounts", column: "domain"))
          .to include("ActiveRecord::Migration[8.1]")
      end

      it "does the same for create_table" do
        expect(text_for(action: "create_table", table: "widgets", column: "name:string"))
          .to include("ActiveRecord::Migration[8.1]")
      end

      it "does the same for add_column" do
        expect(text_for(action: "add_column", table: "accounts", column: "note", type: "string"))
          .to include("ActiveRecord::Migration[8.1]")
      end

      it "does not note a fallback" do
        expect(text_for(action: "add_index", table: "accounts", column: "domain"))
          .not_to include("Could not determine this app's Rails version")
      end
    end

    context "when the context carries an unavailable marker" do
      before do
        allow(described_class).to receive(:cached_context).and_return({
          rails_version: "[UNAVAILABLE: app not booted]", schema: { tables: {} }, models: {}
        })
      end

      it "falls back to the loaded Rails rather than emitting the marker" do
        loaded = Rails::VERSION::STRING.split(".").first(2).join(".")

        expect(text_for(action: "add_index", table: "accounts", column: "domain"))
          .to include("ActiveRecord::Migration[#{loaded}]")
      end
    end

    context "when nothing names a Rails version" do
      before do
        hide_const("Rails")
        allow(described_class).to receive(:cached_context).and_return({
          rails_version: "[UNAVAILABLE: app not booted]", schema: { tables: {} }, models: {}
        })
      end

      it "stamps the supported floor and says so, so the code still parses" do
        text = text_for(action: "add_index", table: "accounts", column: "domain")
        expect(text).to include("ActiveRecord::Migration[7.0]")
        expect(text).to include("Could not determine this app's Rails version")
      end

      # The version is unknown for three reasons; here it is the unavailable
      # marker, not a lockfile with no rails in it.
      it "states what it observed, not a cause it never checked" do
        text = text_for(action: "add_index", table: "accounts", column: "domain")
        expect(text).not_to include("Gemfile.lock")
      end
    end

    context "rendered against the static fixture app" do
      before do
        described_class.reset_cache!
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(IntrospectedFixture::ROOT))
        allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      end

      after { described_class.reset_cache! }

      it "reads the version the fixture's Gemfile.lock pins" do
        expect(text_for(action: "add_index", table: "users", column: "email"))
          .to include("ActiveRecord::Migration[7.2]")
      end
    end
  end

  describe "a table in a secondary database" do
    it "finds the table and its columns" do
      allow(described_class).to receive(:cached_context).and_return(
        models: {},
        schema: { tables: {}, secondary_databases: { "analytics" => { tables: { "page_views" => { columns: [ { name: "path", type: "string" } ] } } } } }
      )
      text = described_class.call(action: "remove_column", table: "page_views", column: "path").content.first[:text]
      expect(text).not_to include("not found in current schema")
      expect(text).not_to include("does not exist on")
    end

    def shard_context
      tables = { tables: { "orders" => { columns: [ { name: "total_cents", type: "integer" } ] } } }
      { models: {}, schema: { tables: {}, secondary_databases: { "analytics" => { tables: { "page_views" => { columns: [] } } }, "shard_one" => tables, "shard_two" => tables } } }
    end

    it "generates the migration into the database that holds the table" do
      allow(described_class).to receive(:cached_context).and_return(shard_context)
      allow(RailsAiContext::DatabaseYml).to receive(:entry).and_return({ "database" => "x" })
      text = described_class.call(action: "add_column", table: "page_views", column: "referrer", type: "string").content.first[:text]
      expect(text).to include("`page_views` is in analytics, not the primary database",
                              "**Run:** `bin/rails generate migration AddReferrerToPageViews referrer:string --database analytics`")
    end

    it "names every database a table is in, and one command when they share migrations_paths" do
      allow(described_class).to receive(:cached_context).and_return(shard_context)
      allow(RailsAiContext::DatabaseYml).to receive(:entry).and_return({ "migrations_paths" => "db/shard_migrate" })
      text = described_class.call(action: "add_index", table: "orders", column: "total_cents").content.first[:text]
      expect(text).to include("`orders` is in shard_one and shard_two", "`--database shard_one`")
      expect(text).not_to include("once per database")
    end

    it "adds a reference with no foreign key to a table in another database" do
      context = shard_context
      context[:schema][:tables]["users"] = { columns: [] }
      allow(described_class).to receive(:cached_context).and_return(context)

      across = described_class.call(action: "add_association", table: "page_views", column: "user").content.first[:text]
      expect(across).to include("add_reference :page_views, :user\n", "`users` is in primary")
      expect(across).not_to include("foreign_key: true")

      same = described_class.call(action: "add_association", table: "users", column: "user").content.first[:text]
      expect(same).to include("add_reference :users, :user, foreign_key: true")
    end

    it "gives no command for a dump whose database no environment configures" do
      allow(described_class).to receive(:cached_context).and_return(shard_context)
      allow(RailsAiContext::DatabaseYml).to receive_messages(entry: nil, elsewhere: nil)
      text = described_class.call(action: "add_column", table: "page_views", column: "referrer", type: "string").content.first[:text]
      expect(text).to include("`page_views` is in the analytics dump, which no environment in config/database.yml configures")
      expect(text).not_to include("--database analytics")
      expect(text).not_to include("bin/rails generate")
    end

    it "generates under the environment that configures a database the running one does not" do
      allow(described_class).to receive(:cached_context).and_return(shard_context)
      allow(RailsAiContext::DatabaseYml).to receive_messages(entry: nil, elsewhere: [ "production", { "migrations_paths" => "db/analytics_migrate" } ])
      text = described_class.call(action: "remove_column", table: "orders", column: "total_cents").content.first[:text]
      expect(text).to include("`orders` is in shard_one and shard_two, which production configures and this environment does not, not the primary database: generate with `RAILS_ENV=production` and `--database shard_one` so the migration lands in db/analytics_migrate and production's `bin/rails db:migrate`",
                              "**Run:** `RAILS_ENV=production bin/rails generate migration RemoveTotalCentsFromOrders total_cents:integer --database shard_one`")
    end

    it "asks for one migration per database when their migrations_paths differ" do
      allow(described_class).to receive(:cached_context).and_return(shard_context)
      allow(RailsAiContext::DatabaseYml).to receive(:entry) { |_, name| { "migrations_paths" => "db/#{name}_migrate" } }
      text = described_class.call(action: "remove_column", table: "orders", column: "total_cents").content.first[:text]
      expect(text).to include("generate it once per database: `--database shard_one`, `--database shard_two`")
    end
  end
end
