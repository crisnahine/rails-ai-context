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

    # A pending migration that already adds the column got no word, and the
    # generator command offered then stopped with "Another migration is
    # already named add_discount_percent_to_users".
    context "with the change already written in a pending migration" do
      around do |example|
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db", "migrate"))
          File.write(File.join(dir, "db", "migrate", "20260101000000_add_discount_percent_to_users.rb"),
                     "class AddDiscountPercentToUsers < ActiveRecord::Migration[8.1]\n  def change\n" \
                     "    add_column :users, :discount_percent, :integer\n  end\nend\n")
          @root = dir
          example.run
        end
      end

      before do
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(@root))
        context = described_class.cached_context
        context[:schema][:pending_migrations] = [ { version: "20260101000000", name: "AddDiscountPercentToUsers" } ]
        allow(described_class).to receive(:cached_context).and_return(context)
      end

      it "names the pending migration and the name the generator refuses" do
        text = described_class.call(action: "add_column", table: "users", column: "discount_percent", type: "decimal").content.first[:text]

        expect(text).to include("**Warning:** Another migration is already named `add_discount_percent_to_users` " \
                                "(`db/migrate/20260101000000_add_discount_percent_to_users.rb`, not yet run)")
        expect(text).to include("**Warning:** Pending migration `20260101000000 AddDiscountPercentToUsers` already adds " \
                                "`discount_percent` (integer) to `users`: run `bin/rails db:migrate`")
        expect(text).not_to include("**Run:**")
      end

      it "names only the clash once that migration has run" do
        described_class.cached_context[:schema][:pending_migrations] = []
        text = described_class.call(action: "add_column", table: "users", column: "discount_percent", type: "decimal").content.first[:text]

        expect(text).to include("Another migration is already named `add_discount_percent_to_users`")
        expect(text).not_to include("Pending migration")
      end

      # A migration that drops a column re-adds it on rollback, and the
      # advisor read that as the pending migration's own change.
      it "reads no column a pending migration adds only on rollback" do
        File.write(File.join(@root, "db", "migrate", "20260102000000_drop_legacy_columns.rb"), <<~RUBY)
          class DropLegacyColumns < ActiveRecord::Migration[8.1]
            def up
              remove_column :users, :legacy_score
            end

            def down
              add_column :users, :legacy_score, :integer
            end
          end
        RUBY
        File.write(File.join(@root, "db", "migrate", "20260103000000_reshape_flags.rb"), <<~RUBY)
          class ReshapeFlags < ActiveRecord::Migration[8.1]
            def change
              reversible do |dir|
                dir.up { remove_column :users, :old_flag }
                dir.down { add_column :users, :old_flag, :boolean }
              end
              revert { add_column :users, :stale_note, :string }
            end
          end
        RUBY
        described_class.cached_context[:schema][:pending_migrations] += [
          { version: "20260102000000", name: "DropLegacyColumns" }, { version: "20260103000000", name: "ReshapeFlags" }
        ]

        texts = %w[legacy_score old_flag stale_note].map do |column|
          described_class.call(action: "add_column", table: "users", column: column, type: "integer").content.first[:text]
        end

        expect(texts).to all(satisfy { |text| !text.include?("Pending migration") })
      end
    end

    it "refuses a column type no adapter knows" do
      text = described_class.call(action: "add_column", table: "users", column: "sku", type: "strnig").content.first[:text]
      expect(text).to include("**Error:** Unknown column type `strnig`. Did you mean `string`?")
      expect(text).not_to include("add_column :users")
    end

    it "warns that null: false without a default fails on a table with rows" do
      context = described_class.cached_context.merge(database_stats: { tables: [ { table: "users", approximate_rows: 12 } ] })
      allow(described_class).to receive(:cached_context).and_return(context)

      text = described_class.call(action: "add_column", table: "users", column: "sku", type: "string", options: "null: false").content.first[:text]
      expect(text).to include("**Warning:** `null: false` without a default fails as `users` holds about 12 rows")
      expect(described_class.call(action: "add_column", table: "users", column: "sku", type: "string", options: "null: false, default: \"\"")
        .content.first[:text]).not_to include("without a default")
    end

    it "warns that create_table fails on a table that exists" do
      text = described_class.call(action: "create_table", table: "users", column: "name:string").content.first[:text]
      expect(text).to include("**Warning:** Table `users` already exists.")
    end

    # A `parent` reference wrote add_reference ... foreign_key: true to a `parents`
    # table no app has, and told the reader to add app/models/parent.rb.
    it "writes a parent reference on a table to the table itself" do
      text = described_class.call(action: "add_association", table: "posts", column: "parent").content.first[:text]

      expect(text).to include("add_reference :posts, :parent, foreign_key: { to_table: :posts }")
      expect(text).to include("belongs_to :parent, class_name: \"Post\", optional: true")
      expect(text).not_to include("parent.rb")
    end

    # Affected Models listed the table's associations, which a dropped plain
    # column does not move, and not the code that reads it.
    it "lists the code that names a column it drops" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "app", "models", "user.rb"), "class User < ApplicationRecord\n  def token = self.api_token\nend\n")
        File.write(File.join(dir, "app", "controllers", "base_controller.rb"), "User.find_by(api_token: token)\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))

        text = described_class.call(action: "remove_column", table: "users", column: "api_token").content.first[:text]
        expect(text).to include("## Code that names `api_token` (2 lines)")
        expect(text).to include("- `app/controllers/base_controller.rb:1` User.find_by(api_token: token)",
                                "- `app/models/user.rb:2` def token = self.api_token")
        expect(text).not_to include("has_many :posts")
      end
    end

    it "names the column's rename parameter by its name" do
      text = described_class.call(action: "rename_column", table: "users", column: "name").content.first[:text]
      expect(text).to include("`column` (the old name) and `new_name` are required")
      expect(text).not_to include("Affected Models")
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

    it "names the down that reverses change_type" do
      response = described_class.call(action: "change_type", table: "posts", column: "title", type: "text")
      text = response.content.first[:text]
      expect(text).to include("**Reversible:** Yes, through the `down` above, which restores `string`")
      expect(text).to include("data loss")
    end

    context "with a column that carries precision, scale, null and a default" do
      before do
        allow(described_class).to receive(:cached_context).and_return({
          schema: { tables: {
            "orders" => { columns: [
              { name: "total", type: "decimal", precision: 10, scale: 2, null: false, default: "0.0" },
              { name: "paid", type: "boolean", null: false, default: "false" },
              { name: "items_count", type: "integer", default: "0" }
            ] },
            "customers" => { columns: [] }
          } },
          models: {}
        })
      end

      # change_column replaces the whole column, so a bare `:decimal` would lose its precision, scale, null and default.
      it "rolls change_type back to the whole column" do
        text = described_class.call(action: "change_type", table: "orders", column: "total", type: "float").content.first[:text]

        expect(text).to include("  def down\n    change_column :orders, :total, :decimal, precision: 10, scale: 2, null: false, default: \"0.0\"\n  end")
      end

      # remove_column's inverse is add_column with the type and options it is given.
      it "writes remove_column with the options that add the column back" do
        text = described_class.call(action: "remove_column", table: "orders", column: "total").content.first[:text]

        expect(text).to include("    remove_column :orders, :total, :decimal, precision: 10, scale: 2, null: false, default: \"0.0\"\n")
      end

      # SchemaDumper writes a boolean or number default as its literal (type_cast_for_schema), a decimal as a string.
      it "writes a boolean or integer default as its literal" do
        paid = described_class.call(action: "change_type", table: "orders", column: "paid", type: "integer").content.first[:text]
        count = described_class.call(action: "change_type", table: "orders", column: "items_count", type: "bigint").content.first[:text]

        expect(paid).to include("    change_column :orders, :paid, :boolean, null: false, default: false\n")
        expect(count).to include("    change_column :orders, :items_count, :integer, default: 0\n")
      end

      it "writes add_column with a references type as add_reference" do
        %w[references belongs_to].each do |type|
          text = described_class.call(action: "add_column", table: "orders", column: "customer", type: type).content.first[:text]

          expect(text).to include("    add_reference :orders, :customer, foreign_key: true\n")
          expect(text).not_to include("add_column")
        end
      end

      # add_column's type is the column type, so the table a role points at goes to add_association's type.
      it "says where a references column names the table a role points at" do
        owner = described_class.call(action: "add_column", table: "orders", column: "owner", type: "references").content.first[:text]
        parent = described_class.call(action: "add_column", table: "orders", column: "parent", type: "references").content.first[:text]

        expect(owner).to include("`owner` reads as a role. Call `add_association` with the table it points at as `type`")
        expect(parent).to include("Call `add_association` with the table it points at as `type` to point it elsewhere.")
      end

      it "adds its own foreign_key when the options only mention one inside a value" do
        text = described_class.call(action: "add_association", table: "orders", column: "customer", options: "comment: \"no foreign_key: yet\"").content.first[:text]

        expect(text).to include("    add_reference :orders, :customer, comment: \"no foreign_key: yet\", foreign_key: true\n")
      end

      it "keeps a foreign_key the options give in place of its own" do
        text = described_class.call(action: "add_association", table: "orders", column: "customer", options: "foreign_key: false").content.first[:text]

        expect(text).to include("    add_reference :orders, :customer, foreign_key: false\n")
      end

      it "puts create_table's options on the create_table line" do
        text = described_class.call(action: "create_table", table: "payments", options: "id: :uuid").content.first[:text]

        expect(text).to include("    create_table :payments, id: :uuid do |t|\n")
      end
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

    # A hint belongs on the class the table belongs to. Every STI subclass
    # records the base's table, and one sorting first got it alone.
    context "with the classes a hint names" do
      let(:models) do
        {
          "CallForEvidence" => { table_name: "editions", file: "app/models/call_for_evidence.rb", parent_model: "Edition", sti: { sti_parent: "Edition" } },
          "Consultation" => { table_name: "editions", file: "app/models/consultation.rb", parent_model: "Publication", sti: { sti_parent: "Publication" } },
          "Edition" => { table_name: "editions", file: "app/models/edition.rb", sti: { sti_base: true, sti_children: %w[CallForEvidence Publication] } },
          "Publication" => { table_name: "editions", file: "app/models/publication.rb", parent_model: "Edition", sti: { sti_parent: "Edition", sti_children: %w[Consultation] } },
          "AdminUser" => { table_name: "users", file: "app/models/admin_user.rb", parent_model: "Person", sti: { sti_parent: "Person" } },
          "User" => { table_name: "users", file: "app/models/user.rb", parent_model: "Person", sti: { sti_parent: "Person" } },
          "Person" => { table_name: "users", file: "app/models/person.rb", sti: { sti_base: true, sti_children: %w[AdminUser User] } },
          "DraftArchive" => { table_name: "archived_editions", file: "app/models/draft_archive.rb", parent_model: "Archive" },
          "Archive" => { table_name: "archived_editions", file: "app/models/archive.rb", parent_model: "Edition" }
        }
      end

      before do
        described_class.reset_cache!
        allow(described_class).to receive(:strong_migrations_gem_present?).and_return(false)
        allow(described_class).to receive(:cached_context).and_return({
          schema: { tables: models.values.filter_map { |data| data[:table_name] }.to_h { |name| [ name, { columns: [ { name: "email", type: "string" } ] } ] } },
          models: models
        })
      end

      def advice(**args)
        described_class.call(action: "add_association", **args).content.first[:text]
      end

      it "puts belongs_to in the base class, past every level of subclass" do
        text = advice(table: "editions", column: "owner", type: "users")

        expect(text).to include("# app/models/edition.rb\nbelongs_to :owner, class_name: \"Person\"")
        expect(text).not_to include("app/models/call_for_evidence.rb")
        expect(text).not_to include("app/models/consultation.rb")
      end

      it "puts has_many in the base class of the table it points at" do
        text = advice(table: "editions", column: "owner", type: "users")

        expect(text).to include("# app/models/person.rb\nhas_many :editions, foreign_key: :owner_id, inverse_of: :owner")
        expect(text).not_to include("app/models/admin_user.rb")
      end

      it "names the base class on a reference to its own STI table" do
        text = advice(table: "editions", column: "parent")

        expect(text).to include("# app/models/edition.rb\nbelongs_to :parent, class_name: \"Edition\", optional: true")
        expect(text).to include("has_many :children, class_name: \"Edition\"")
      end

      # A subclass that sets its own table_name owns that table, though its
      # parent reads another one.
      it "keeps a subclass that reads a table of its own" do
        text = advice(table: "archived_editions", column: "owner", type: "users")

        expect(text).to include("# app/models/archive.rb\nbelongs_to :owner, class_name: \"Person\"")
      end

      # has_many :users reads as User, a subclass, where Person owns the table.
      it "names the owner on a has_many whose name reads as another class" do
        text = advice(table: "users", column: "reviewer", type: "editions")

        expect(text).to include("# app/models/person.rb\nbelongs_to :reviewer, class_name: \"Edition\"")
        expect(text).to include("# app/models/edition.rb\nhas_many :users, class_name: \"Person\", foreign_key: :reviewer_id, inverse_of: :reviewer")
      end

      it "points ignored_columns at the base when a subclass has the table's name" do
        allow(described_class).to receive(:strong_migrations_gem_present?).and_return(true)
        text = described_class.call(action: "remove_column", table: "users", column: "email").content.first[:text]

        expect(text).to include("`self.ignored_columns += %w[email]` in `app/models/person.rb`")
      end

      # A model that raised still names its table, so its subclasses are not
      # the only classes on it.
      context "when the base's details raised" do
        let(:models) do
          {
            "AdminUser" => { table_name: "users", parent_model: "User" },
            "Group" => { table_name: "users", parent_model: "Principal" },
            "User" => { table_name: "users", parent_model: "Principal" },
            "Principal" => { error: "boom", table_name: "users" },
            "Edition" => { table_name: "editions" }
          }
        end

        it "puts belongs_to in that base" do
          text = advice(table: "users", column: "owner", type: "editions")

          expect(text).to include("# app/models/principal.rb\nbelongs_to :owner, class_name: \"Edition\"")
        end
      end

      # Rails looks a class name up inside the model's namespace first.
      context "when a namespace holds a model of the same name" do
        let(:models) do
          {
            "Comment" => { table_name: "comments" },
            "Admin::Comment" => { table_name: "admin_comments" },
            "Admin::Post" => { table_name: "posts" }
          }
        end

        it "roots a class_name its namespace would read as another model" do
          text = advice(table: "comments", column: "post", type: "posts")

          expect(text).to include("# app/models/comment.rb\nbelongs_to :post, class_name: \"Admin::Post\"")
          expect(text).to include("# app/models/admin/post.rb\nhas_many :comments, class_name: \"::Comment\", foreign_key: :post_id, inverse_of: :post")
        end

        it "writes no class_name the association's name already reaches" do
          text = advice(table: "admin_comments", column: "post", type: "posts")

          expect(text).to include("# app/models/admin/comment.rb\nbelongs_to :post\n")
          expect(text).to include("# app/models/admin/post.rb\nhas_many :admin_comments, class_name: \"Admin::Comment\", dependent: :destroy")
        end
      end

      # HTMLPage is reached by `html_page` only through an ActiveSupport acronym,
      # never through a Zeitwerk-only one, and the static tier sees neither.
      context "when a model's name spells an acronym" do
        let(:models) { { "HTMLPage" => { table_name: "html_pages" }, "Site" => { table_name: "sites" } } }

        [ true, false ].each do |static|
          it "names it where this process camelizes the name another way (static tier: #{static})" do
            allow(RailsAiContext).to receive(:static_tier?).and_return(static)
            text = advice(table: "sites", column: "html_page", type: "html_pages")

            expect(text).to include("# app/models/site.rb\nbelongs_to :html_page, class_name: \"HTMLPage\"")
          end
        end
      end

      # `check_in` camelizes to CheckIn, which no acronym turns into Checkin.
      context "when a model's name joins the words of the association's" do
        let(:models) { { "Checkin" => { table_name: "checkins" }, "Listing" => { table_name: "listings" } } }

        [ true, false ].each do |static|
          it "names it (static tier: #{static})" do
            allow(RailsAiContext).to receive(:static_tier?).and_return(static)
            text = advice(table: "listings", column: "check_in", type: "checkins")

            expect(text).to include("# app/models/listing.rb\nbelongs_to :check_in, class_name: \"Checkin\"")
          end
        end
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

    it "rejects a new_name or a create_table column name that is not an identifier" do
      [
        { action: "rename_column", table: "users", column: "name", new_name: "Full Name" },
        { action: "rename_column", table: "users", column: "name", new_name: "full-name" },
        { action: "rename_column", table: "users", column: "name", type: "Full Name" },
        { action: "create_table", table: "widgets", column: "full name:string,title:string" }
      ].each do |args|
        text = described_class.call(**args).content.first[:text]

        expect(text).to match(/\*\*Error:\*\* Invalid column name `(Full Name|full-name|full name)`\. Use lowercase letters, digits, and underscores only\./)
        expect(text).not_to include("```ruby")
      end
    end

    # Rails' generator reads `title:string:index` as an indexed column and `:uniq` as a unique one.
    it "writes the index a create_table definition asks for" do
      text = described_class.call(action: "create_table", table: "widgets", column: "title:string:index,slug:string:uniq").content.first[:text]

      expect(text).to include("      t.string :title\n      t.index :title\n      t.string :slug\n      t.index :slug, unique: true\n")
    end

    # GeneratedAttribute.parse: `name:index` is an indexed string, and a reference's `uniq` is `index: { unique: true }`.
    it "reads a create_table index modifier the way the Rails generator does" do
      text = described_class.call(action: "create_table", table: "widgets", column: "title:index,user:references:uniq,post:references:index").content.first[:text]

      expect(text).to include("      t.string :title\n      t.index :title\n")
      expect(text).to include("      t.references :user, index: { unique: true }, foreign_key: true\n")
      expect(text).to include("      t.references :post, foreign_key: true\n")
    end

    it "refuses a create_table modifier it cannot write" do
      text = described_class.call(action: "create_table", table: "widgets", column: "title:string:indexed").content.first[:text]

      expect(text).to include("**Error:** `title:string:indexed`")
      expect(text).not_to include("```ruby")
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

      context "with an association to another table" do
        before do
          allow(described_class).to receive(:cached_context).and_return({
            schema: { adapter: "PostgreSQL", tables: {
              "users" => { columns: [ { name: "email", type: "string" } ] },
              "listings" => { columns: [ { name: "title", type: "string" } ] }
            } },
            models: {}
          })
        end

        it "rewrites the add_reference it wrote with a concurrent index and an unvalidated key, then validates that key" do
          text = described_class.call(action: "add_association", table: "listings", column: "owner", type: "users").content.first[:text]
          expect(text).to include("`add_reference :listings, :owner, index: { algorithm: :concurrently }` and `add_foreign_key :listings, :users, column: :owner_id, validate: false`")
          expect(text).not_to include("validate: false }")
          expect(text).to include("disable_ddl_transaction!")
          expect(text).to include("`validate_foreign_key :listings, :users, column: :owner_id`")
          expect(text).not_to include("add_foreign_key :listings, :owner")
        end

        it "describes no foreign key when the options turn it off" do
          text = described_class.call(action: "add_association", table: "listings", column: "owner", type: "users", options: "foreign_key: false").content.first[:text]
          expect(text).to include("which blocks writes. Instead:")
          expect(text).to include("`add_reference :listings, :owner, foreign_key: false, index: { algorithm: :concurrently }`")
          expect(text).not_to match(/add_foreign_key|validate_foreign_key|SHARE ROW EXCLUSIVE/)
        end

        it "names the table a plain reference points at" do
          text = described_class.call(action: "add_association", table: "listings", column: "user").content.first[:text]
          expect(text).to include("`add_reference :listings, :user, index: { algorithm: :concurrently }` and `add_foreign_key :listings, :users, column: :user_id, validate: false`")
          expect(text).to include("`validate_foreign_key :listings, :users, column: :user_id`")
        end

        it "has nothing to rewrite when the reference's column already exists" do
          allow(described_class).to receive(:cached_context).and_return({
            schema: { adapter: "PostgreSQL", tables: {
              "users" => { columns: [ { name: "email", type: "string" } ] },
              "listings" => { columns: [ { name: "user_id", type: "bigint" } ] }
            } },
            models: {}
          })

          text = described_class.call(action: "add_association", table: "listings", column: "user").content.first[:text]
          expect(text).to include("Column `user_id` already exists on `listings`")
          expect(text).not_to include("Strong Migrations Warnings")
        end

        it "keeps a self-reference's table in the rewrite" do
          text = described_class.call(action: "add_association", table: "listings", column: "parent").content.first[:text]
          expect(text).to include("`add_reference :listings, :parent, index: { algorithm: :concurrently }` and `add_foreign_key :listings, :listings, column: :parent_id, validate: false`")
          expect(text).to include("`validate_foreign_key :listings, :listings, column: :parent_id`")
        end
      end

      it "keeps the key type and the primary key of a table keyed by a uuid column not named id" do
        allow(described_class).to receive(:cached_context).and_return({
          schema: { adapter: "PostgreSQL", tables: {
            "users" => { columns: [ { name: "uid", type: "uuid", primary_key: true } ], primary_key: "uid" },
            "listings" => { columns: [ { name: "title", type: "string" } ] }
          } },
          models: {}
        })

        text = described_class.call(action: "add_association", table: "listings", column: "user").content.first[:text]
        expect(text).to include("`add_reference :listings, :user, type: :uuid, index: { algorithm: :concurrently }` and `add_foreign_key :listings, :users, column: :user_id, primary_key: :uid, validate: false`")
        expect(text).to include("`validate_foreign_key :listings, :users, column: :user_id`")
      end

      it "asks only for the concurrent index when the reference has no foreign key" do
        text = described_class.call(action: "add_association", table: "users", column: "tenant").content.first[:text]
        expect(text).to include("`add_reference :users, :tenant, index: { algorithm: :concurrently }`")
        expect(text).not_to include("validate_foreign_key")
        expect(text).not_to include("validate: false")
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
          schema: { adapter: "Trilogy", tables: {
            "users" => { columns: [ { name: "email", type: "string" } ] },
            "listings" => { columns: [ { name: "title", type: "string" } ] }
          } },
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

      it "moves the foreign key out of add_reference and adds it with foreign_key_checks off" do
        allow(RailsAiContext::GemLock).to receive(:for).and_return(instance_double(RailsAiContext::GemLock::Spec, version: "2.7.0"))
        allow(described_class).to receive(:cached_context).and_return({
          schema: { adapter: "Trilogy", tables: {
            "users" => { columns: [ { name: "email", type: "string" } ], primary_key: "uuid" },
            "listings" => { columns: [ { name: "title", type: "string" } ] }
          } },
          models: {}
        })

        text = described_class.call(action: "add_association", table: "listings", column: "owner", type: "users").content.first[:text]
        expect(text).to include("Add the reference without one, `add_reference :listings, :owner`")
        expect(text).to include("class AddOwnerForeignKeyToListings < ActiveRecord::Migration[")
        expect(text).to include("      add_foreign_key :listings, :users, column: :owner_id, primary_key: :uuid\n    ensure\n      execute \"SET SESSION foreign_key_checks = 1\"")
        expect(text).to include("    remove_foreign_key :listings, column: :owner_id")
        expect(text).not_to include("validate_foreign_key")
      end

      it "gives no warning for a reference with no foreign key" do
        text = described_class.call(action: "add_association", table: "users", column: "tenant").content.first[:text]
        expect(text).not_to include("Strong Migrations Warnings")
      end

      it "has nothing to rewrite when the reference's column already exists" do
        allow(described_class).to receive(:cached_context).and_return({
          schema: { adapter: "Trilogy", tables: {
            "users" => { columns: [ { name: "email", type: "string" } ] },
            "listings" => { columns: [ { name: "owner_id", type: "bigint" } ] }
          } },
          models: {}
        })

        text = described_class.call(action: "add_association", table: "listings", column: "owner", type: "users").content.first[:text]
        expect(text).to include("Column `owner_id` already exists on `listings`")
        expect(text).not_to include("Strong Migrations Warnings")
      end

      it "gives no foreign key warning when the locked strong_migrations predates its MySQL check" do
        allow(RailsAiContext::GemLock).to receive(:for).and_return(instance_double(RailsAiContext::GemLock::Spec, version: "2.6.0"))

        text = described_class.call(action: "add_association", table: "listings", column: "owner", type: "users").content.first[:text]
        expect(text).to include("add_reference :listings, :owner, foreign_key: { to_table: :users }")
        expect(text).not_to include("Strong Migrations Warnings")
      end

      [ nil, "not-a-version", "2.7.0.rc1" ].each do |version|
        it "keeps the foreign key warning when the locked strong_migrations is #{version.inspect}" do
          allow(RailsAiContext::GemLock).to receive(:for).and_return(instance_double(RailsAiContext::GemLock::Spec, version: version))

          text = described_class.call(action: "add_association", table: "listings", column: "owner", type: "users").content.first[:text]
          expect(text).to include("class AddOwnerForeignKeyToListings")
        end
      end
    end

    context "when strong_migrations gem is present on a SQLite app" do
      before do
        allow(described_class).to receive(:strong_migrations_gem_present?).and_return(true)
        allow(described_class).to receive(:cached_context).and_return({
          schema: { adapter: "SQLite", tables: {
            "users" => { columns: [ { name: "email", type: "string" } ] },
            "listings" => { columns: [ { name: "title", type: "string" } ] }
          } },
          models: {}
        })
      end

      it "gives no warning for an association, which strong_migrations does not check there" do
        text = described_class.call(action: "add_association", table: "listings", column: "user").content.first[:text]
        expect(text).to include("add_reference :listings, :user, foreign_key: true")
        expect(text).not_to include("Strong Migrations Warnings")
      end
    end

    context "when the app's database is undecided between two families" do
      before do
        allow(described_class).to receive(:strong_migrations_gem_present?).and_return(true)
        allow(described_class).to receive(:cached_context).and_return({
          schema: { adapter: "PostgreSQL or MySQL", tables: {
            "users" => { columns: [ { name: "email", type: "string" } ] },
            "listings" => { columns: [ { name: "title", type: "string" } ] }
          } },
          models: {}
        })
      end

      [
        { action: "add_index", table: "users", column: "email" },
        { action: "add_association", table: "users", column: "tenant" },
        { action: "change_type", table: "users", column: "email", type: "text" },
        { action: "add_column", table: "users", column: "phone", type: "string", options: "null: false" }
      ].each do |args|
        it "gives #{args[:action]} advice that names no database" do
          text = described_class.call(**args).content.first[:text]
          expect(text).not_to match(/Postgre|MySQL|MariaDB|SQLite|concurrently|validate: false|foreign_key_checks/)
        end
      end

      it "gives a reference with a foreign key the advice every database shares" do
        text = described_class.call(action: "add_association", table: "listings", column: "user").content.first[:text]
        expect(text).to include("The foreign key from `add_reference` validates existing rows")
        expect(text).not_to match(/Postgre|MySQL|MariaDB|SQLite|concurrently|validate: false|foreign_key_checks/)
      end

      it "still warns about a NOT NULL column without a default" do
        text = described_class.call(action: "add_column", table: "users", column: "phone", type: "string", options: "null: false").content.first[:text]
        expect(text).to include("NOT NULL")
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

    # The app databases a test app lists: the running environment's, then production's.
    def stub_databases(here, production = {})
      root = Rails.root.to_s
      environments = { RailsAiContext.environment_name => { "primary" => { "adapter" => "postgresql" } }.merge(here), "production" => production }
      list = RailsAiContext::AppDatabases.build(environments: environments, current: RailsAiContext.environment_name, root: root, dumps: [])
      allow(RailsAiContext::AppDatabases).to receive(:for).and_return(list)
    end

    def shard_context
      tables = { tables: { "orders" => { columns: [ { name: "total_cents", type: "integer" } ] } } }
      { models: {}, schema: { tables: {}, secondary_databases: { "analytics" => { tables: { "page_views" => { columns: [] } } }, "shard_one" => tables, "shard_two" => tables } } }
    end

    it "generates the migration into the database that holds the table" do
      allow(described_class).to receive(:cached_context).and_return(shard_context)
      stub_databases("analytics" => { "database" => "x" }, "shard_one" => {}, "shard_two" => {})
      text = described_class.call(action: "add_column", table: "page_views", column: "referrer", type: "string").content.first[:text]
      expect(text).to include("`page_views` is in analytics: generate with `--database analytics`",
                              "**Run:** `bin/rails generate migration AddReferrerToPageViews referrer:string --database analytics`")
    end

    it "names every database a table is in, and one command when they share migrations_paths" do
      allow(described_class).to receive(:cached_context).and_return(shard_context)
      stub_databases("analytics" => {}, "shard_one" => { "migrations_paths" => "db/shard_migrate" }, "shard_two" => { "migrations_paths" => "db/shard_migrate" })
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

      allow(described_class).to receive(:strong_migrations_gem_present?).and_return(true)
      across = described_class.call(action: "add_association", table: "page_views", column: "user").content.first[:text]
      expect(across).not_to match(/add_foreign_key|validate_foreign_key|foreign key from/)
    end

    it "keeps unsigned off a reference from a database that has no unsigned type" do
      context = shard_context
      context[:schema][:adapter] = "Mysql2"
      context[:schema][:tables]["users"] = { columns: [ { name: "id", type: "integer", primary_key: true, unsigned: true } ], primary_key: "id" }
      allow(described_class).to receive(:cached_context).and_return(context)
      stub_databases("analytics" => { "adapter" => "postgresql" })

      text = described_class.call(action: "add_association", table: "page_views", column: "user").content.first[:text]
      expect(text).to include("add_reference :page_views, :user, type: :integer\n")
    end

    it "gives no command for a dump whose database no environment configures" do
      allow(described_class).to receive(:cached_context).and_return(shard_context)
      stub_databases({})
      text = described_class.call(action: "add_column", table: "page_views", column: "referrer", type: "string").content.first[:text]
      expect(text).to include("`page_views` is in the analytics dump, which no environment in config/database.yml configures")
      expect(text).not_to include("--database analytics")
      expect(text).not_to include("bin/rails generate")
    end

    it "generates under the environment that configures a database the running one does not" do
      allow(described_class).to receive(:cached_context).and_return(shard_context)
      stub_databases({}, { "primary" => {}, "shard_one" => { "migrations_paths" => "db/analytics_migrate" }, "shard_two" => { "migrations_paths" => "db/analytics_migrate" } })
      text = described_class.call(action: "remove_column", table: "orders", column: "total_cents").content.first[:text]
      expect(text).to include("`orders` is in shard_one and shard_two, which production configures and this environment does not: generate with `RAILS_ENV=production` and `--database shard_one` so the migration lands in db/analytics_migrate and production's `bin/rails db:migrate`",
                              "**Run:** `RAILS_ENV=production bin/rails generate migration RemoveTotalCentsFromOrders total_cents:integer --database shard_one`")
    end

    it "names every environment that configures the database" do
      allow(described_class).to receive(:cached_context).and_return(shard_context)
      elsewhere = { "primary" => {}, "shard_one" => { "migrations_paths" => "db/analytics_migrate" } }
      here = RailsAiContext.environment_name
      list = RailsAiContext::AppDatabases.build(
        environments: { here => { "primary" => { "adapter" => "postgresql" } }, "staging" => elsewhere, "production" => elsewhere },
        current: here, root: Rails.root.to_s, dumps: []
      )
      allow(RailsAiContext::AppDatabases).to receive(:for).and_return(list)

      text = described_class.call(action: "remove_column", table: "orders", column: "total_cents").content.first[:text]

      expect(text).to include("`orders` is in shard_one, which staging and production configure and this environment does not: " \
                              "generate with `RAILS_ENV=staging` and `--database shard_one`")
    end

    it "gives index advice for the family of the database that holds the table" do
      context = shard_context
      context[:schema][:adapter] = "postgresql"
      allow(described_class).to receive(:cached_context).and_return(context)
      stub_databases("analytics" => { "adapter" => "mysql2" })

      held_elsewhere = described_class.call(action: "add_index", table: "page_views", column: "path").content.first[:text]
      on_primary = described_class.call(action: "add_index", table: "users", column: "email").content.first[:text]

      expect(held_elsewhere).to include("MySQL/MariaDB add indexes to InnoDB tables via online DDL")
      expect(held_elsewhere).not_to include("consider `algorithm: :concurrently`")
      expect(on_primary).to include("consider `algorithm: :concurrently` (PostgreSQL)")
    end

    # The database's statistics are the primary's, so they say nothing about a table on another database.
    it "does not count a secondary database's rows from the primary's statistics" do
      context = shard_context.merge(database_stats: { tables: [ { table: "page_views", approximate_rows: 12 } ] })
      allow(described_class).to receive(:cached_context).and_return(context)
      stub_databases("analytics" => {})

      text = described_class.call(action: "add_column", table: "page_views", column: "sku", type: "string", options: "null: false").content.first[:text]
      expect(text).to include("**Warning:** `null: false` without a default fails if `page_views` holds any rows")
      expect(text).not_to include("12 rows")
    end

    it "asks for one migration per database when their migrations_paths differ" do
      allow(described_class).to receive(:cached_context).and_return(shard_context)
      stub_databases("shard_one" => { "migrations_paths" => "db/shard_one_migrate" }, "shard_two" => { "migrations_paths" => "db/shard_two_migrate" })
      text = described_class.call(action: "remove_column", table: "orders", column: "total_cents").content.first[:text]
      expect(text).to include("generate it once per database: `--database shard_one`, `--database shard_two`")
    end
  end

  describe "a table whose primary key is not id" do
    before do
      tables = {
        "batch_jobs" => { columns: [ { name: "bid", type: "string", primary_key: true }, { name: "state", type: "string" } ], primary_key: "bid" },
        "listings" => { columns: [ { name: "id", type: "bigint", primary_key: true } ], primary_key: "id" },
        "skus" => { columns: [ { name: "shop_id", type: "bigint", primary_key: true }, { name: "code", type: "bigint", primary_key: true } ],
                    primary_key: %w[shop_id code] }
      }
      allow(described_class).to receive(:cached_context).and_return({ schema: { tables: tables }, models: {} })
    end

    def advise(**params) = described_class.call(**params).content.first[:text]

    it "points a reference's foreign key at that key" do
      text = advise(action: "add_association", table: "listings", column: "batch_job", type: "batch_jobs")

      expect(text).to include("add_reference :listings, :batch_job, type: :string, foreign_key: { primary_key: :bid }")
    end

    it "points a role's foreign key at that key" do
      text = advise(action: "add_association", table: "listings", column: "job", type: "batch_jobs")

      expect(text).to include("add_reference :listings, :job, type: :string, foreign_key: { to_table: :batch_jobs, primary_key: :bid }")
    end

    it "points a created table's reference at that key" do
      text = advise(action: "create_table", table: "runs", column: "batch_job:references")

      expect(text).to include("t.references :batch_job, type: :string, foreign_key: { primary_key: :bid }")
    end

    it "writes no foreign key to a table with a composite primary key, and says why" do
      added = advise(action: "add_association", table: "listings", column: "sku")
      created = advise(action: "create_table", table: "runs", column: "sku:references")

      expect(added).to include("`skus` has the composite primary key (shop_id, code), which one column cannot reference")
      expect(added).to include("add_reference :listings, :sku\n")
      expect(created).to include("t.references :sku # no foreign key: skus has the composite primary key (shop_id, code)")

      allow(described_class).to receive(:strong_migrations_gem_present?).and_return(true)
      expect(advise(action: "add_association", table: "listings", column: "sku")).not_to match(/add_foreign_key|validate_foreign_key|foreign key from/)
    end
  end

  describe "an app whose tables use uuid primary keys" do
    def keyed(type)
      { columns: [ { name: "id", type: type, primary_key: true }, { name: "name", type: "string" } ], primary_key: "id" }
    end

    def advise(key_types, **params)
      tables = key_types.transform_values { |type| keyed(type) }
      allow(described_class).to receive(:cached_context).and_return({ schema: { tables: tables }, models: {} })
      described_class.call(**params).content.first[:text]
    end

    let(:uuid_app) { { "users" => "uuid", "widgets" => "uuid" } }

    it "gives a reference the key type of the table it points at" do
      text = advise(uuid_app, action: "add_association", table: "widgets", column: "owner", type: "users")

      expect(text).to include("add_reference :widgets, :owner, type: :uuid, foreign_key: { to_table: :users }")
    end

    it "gives a reference to a table with the default key no type" do
      text = advise({ "users" => "bigint", "widgets" => "uuid" }, action: "add_association", table: "widgets", column: "owner", type: "users")

      expect(text).to include("add_reference :widgets, :owner, foreign_key: { to_table: :users }")
    end

    it "creates a table with the key type most of the app's tables use" do
      text = advise(uuid_app, action: "create_table", table: "gadgets", column: "name:string")

      expect(text).to include("create_table :gadgets, id: :uuid do |t|")
    end

    it "keeps the app's key type when only a string option's text reads id:" do
      text = advise(uuid_app, action: "create_table", table: "gadgets", column: "name:string", options: 'comment: "keyed by id: slug"')

      expect(text).to include(%(create_table :gadgets, id: :uuid, comment: "keyed by id: slug" do |t|))
    end

    it "keys the references of a created table the way the tables they point at are keyed" do
      text = advise(uuid_app, action: "create_table", table: "gadgets", column: "user:references")

      expect(text).to include("t.references :user, type: :uuid, foreign_key: true")
    end

    it "keys a reference to a table the schema lacks the way the app's tables are keyed" do
      text = advise(uuid_app, action: "create_table", table: "gadgets", column: "owner:references")

      expect(text).to include("t.references :owner, type: :uuid # no foreign key: the schema has no owners table")
    end

    it "keys a reference to an integer-keyed table as integer outside SQLite, and leaves a created table's own key alone" do
      integer_app = { "users" => "integer", "widgets" => "integer" }

      expect(advise(integer_app, action: "add_association", table: "widgets", column: "owner", type: "users"))
        .to include("add_reference :widgets, :owner, type: :integer, foreign_key: { to_table: :users }")
      expect(advise(integer_app, action: "create_table", table: "gadgets", column: "user:references"))
        .to include("t.references :user, type: :integer, foreign_key: true")
      expect(advise(integer_app, action: "create_table", table: "gadgets", column: "name:string")).not_to include("id: :integer")
    end

    it "keys a reference to a serial key by the column type, not by a sequence of its own" do
      serial_app = { "users" => "serial", "widgets" => "serial" }

      expect(advise(serial_app, action: "add_association", table: "widgets", column: "owner", type: "users"))
        .to include("add_reference :widgets, :owner, type: :integer, foreign_key: { to_table: :users }")
      expect(advise(serial_app, action: "create_table", table: "gadgets", column: "owner:references"))
        .to include("t.references :owner, type: :integer # no foreign key")
      expect(advise(serial_app, action: "create_table", table: "gadgets", column: "name:string")).to include("create_table :gadgets, id: :serial do |t|")
      expect(advise({ "users" => "bigserial", "widgets" => "bigserial" }, action: "add_association", table: "widgets", column: "owner", type: "users"))
        .to include("add_reference :widgets, :owner, foreign_key: { to_table: :users }")
      expect(advise({ "users" => "smallserial", "widgets" => "bigserial" }, action: "add_association", table: "widgets", column: "owner", type: "users"))
        .to include("add_reference :widgets, :owner, type: :smallint, foreign_key: { to_table: :users }")
    end

    it "keeps a small integer key's limit on the reference" do
      tables = { "users" => { columns: [ { name: "id", type: "integer", limit: 2, primary_key: true } ], primary_key: "id" }, "widgets" => keyed("integer") }
      allow(described_class).to receive(:cached_context).and_return({ schema: { adapter: "Mysql2", tables: tables }, models: {} })

      text = described_class.call(action: "add_association", table: "widgets", column: "owner", type: "users").content.first[:text]
      expect(text).to include("add_reference :widgets, :owner, type: :integer, limit: 2, foreign_key: { to_table: :users }")
    end

    it "keys a reference to an unsigned key as unsigned, which MySQL needs for the foreign key" do
      tables = {
        "users" => { columns: [ { name: "id", type: "integer", primary_key: true, unsigned: true } ], primary_key: "id" },
        "teams" => { columns: [ { name: "id", type: "bigint", primary_key: true, unsigned: true } ], primary_key: "id" },
        "editions" => keyed("integer")
      }
      allow(described_class).to receive(:cached_context).and_return({ schema: { adapter: "Mysql2", tables: tables }, models: {} })
      allow(described_class).to receive(:strong_migrations_gem_present?).and_return(true)

      owner = described_class.call(action: "add_association", table: "editions", column: "owner", type: "users").content.first[:text]
      expect(owner).to include("add_reference :editions, :owner, type: :integer, unsigned: true, foreign_key: { to_table: :users }")
      expect(owner).to include("Add the reference without one, `add_reference :editions, :owner, type: :integer, unsigned: true`")
      team = described_class.call(action: "add_association", table: "editions", column: "team").content.first[:text]
      expect(team).to include("add_reference :editions, :team, unsigned: true, foreign_key: true")
    end

    it "gives a reference to an integer-keyed table no type on SQLite, where every key is an integer" do
      tables = { "users" => keyed("integer"), "widgets" => keyed("integer") }
      allow(described_class).to receive(:cached_context).and_return({ schema: { adapter: "SQLite", tables: tables }, models: {} })

      text = described_class.call(action: "add_association", table: "widgets", column: "owner", type: "users").content.first[:text]
      expect(text).to include("add_reference :widgets, :owner, foreign_key: { to_table: :users }")
    end

    it "creates a table with the default key where the tables are not keyed alike" do
      text = advise({ "users" => "uuid", "widgets" => "bigint" }, action: "create_table", table: "gadgets", column: "name:string")

      expect(text).to include("create_table :gadgets do |t|")
    end
  end
end
