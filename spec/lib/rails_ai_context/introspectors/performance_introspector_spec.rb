# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::PerformanceIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns n_plus_one_risks as array" do
      expect(result[:n_plus_one_risks]).to be_an(Array)
    end

    it "returns missing_counter_cache as array" do
      expect(result[:missing_counter_cache]).to be_an(Array)
    end

    it "returns missing_fk_indexes as array" do
      expect(result[:missing_fk_indexes]).to be_an(Array)
    end

    context "missing foreign key indexes" do
      def missing_for(schema_source, models = {})
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"), schema_source)
          FileUtils.mkdir_p(File.join(dir, "app", "models"))
          models.each do |file, source|
            path = File.join(dir, "app", "models", file)
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, source)
          end
          described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_fk_indexes]
        end
      end

      it "reports an unindexed foreign key column" do
        missing = missing_for(<<~RUBY)
          create_table "posts" do |t|
            t.integer "author_id"
          end

          add_foreign_key "posts", "authors"
        RUBY

        expect(missing).to contain_exactly(a_hash_including(table: "posts", column: "author_id"))
      end

      it "stays quiet when an index covers the column" do
        missing = missing_for(<<~RUBY)
          create_table "posts" do |t|
            t.integer "author_id"
            t.index [ "author_id" ]
          end
        RUBY

        expect(missing).to be_empty
      end

      # A query on author_id alone cannot use an index that leads with
      # blog_id; rails_validate already said so and this check did not.
      it "reports a foreign key that only trails another column in an index" do
        missing = missing_for(<<~RUBY)
          create_table "posts" do |t|
            t.integer "blog_id"
            t.integer "author_id"
            t.index [ "blog_id", "author_id" ]
          end

          add_foreign_key "posts", "authors"
        RUBY

        expect(missing).to contain_exactly(a_hash_including(table: "posts", column: "author_id"))
      end

      it "stays quiet for a foreign key that leads a composite index" do
        missing = missing_for(<<~RUBY)
          create_table "posts" do |t|
            t.integer "author_id"
            t.integer "blog_id"
            t.index [ "author_id", "blog_id" ]
            t.index [ "blog_id" ]
          end
        RUBY

        expect(missing).to be_empty
      end

      # type and id are looked up together, so they must lead the index
      # together; behind tenant_id the pair cannot be reached.
      it "reports a polymorphic pair that does not lead its index" do
        missing = missing_for(<<~RUBY, { "comment.rb" => "class Comment < ApplicationRecord\n  belongs_to :commentable, polymorphic: true\nend\n" })
          create_table "comments" do |t|
            t.integer "tenant_id"
            t.string "commentable_type"
            t.integer "commentable_id"
            t.index [ "tenant_id", "commentable_type", "commentable_id" ]
            t.index [ "tenant_id" ]
          end
        RUBY

        expect(missing).to contain_exactly(a_hash_including(table: "comments", polymorphic: true))
      end

      it "stays quiet for a polymorphic pair that leads its index" do
        missing = missing_for(<<~RUBY, { "comment.rb" => "class Comment < ApplicationRecord\n  belongs_to :commentable, polymorphic: true\nend\n" })
          create_table "comments" do |t|
            t.string "commentable_type"
            t.integer "commentable_id"
            t.index [ "commentable_type", "commentable_id" ]
          end
        RUBY

        expect(missing).to be_empty
      end

      let(:accounts_tags_models) do
        { "tag.rb" => "class Tag < ApplicationRecord\n  has_and_belongs_to_many :accounts\nend\n",
          "account.rb" => "class Account < ApplicationRecord\n  has_and_belongs_to_many :tags\nend\n" }
      end

      # Mastodon's accounts_tags has primary_key: ["tag_id", "account_id"]; the
      # key's index serves tag_id, and the check suggested adding one.
      it "counts a composite primary key's leading column as indexed" do
        missing = missing_for(<<~RUBY, accounts_tags_models)
          create_table "accounts", force: :cascade do |t|
          end
          create_table "tags", force: :cascade do |t|
            t.string "name"
          end
          create_table "accounts_tags", primary_key: ["tag_id", "account_id"], force: :cascade do |t|
            t.bigint "account_id", null: false
            t.bigint "tag_id", null: false
            t.index ["account_id", "tag_id"], name: "index_accounts_tags_on_account_id_and_tag_id"
          end
        RUBY

        expect(missing).to be_empty
      end

      it "still reports a key column that only trails in the primary key" do
        missing = missing_for(<<~RUBY, accounts_tags_models)
          create_table "accounts", force: :cascade do |t|
          end
          create_table "tags", force: :cascade do |t|
            t.string "name"
          end
          create_table "accounts_tags", primary_key: ["tag_id", "account_id"], force: :cascade do |t|
            t.bigint "account_id", null: false
            t.bigint "tag_id", null: false
          end
        RUBY

        expect(missing).to contain_exactly(a_hash_including(table: "accounts_tags", column: "account_id"))
      end

      it "does not mistake a wider column name for an index on it" do
        missing = missing_for(<<~RUBY)
          create_table "posts" do |t|
            t.integer "id_verified"
            t.integer "author_id"
            t.index [ "id_verified" ]
          end

          add_foreign_key "posts", "authors"
        RUBY

        expect(missing).to contain_exactly(a_hash_including(column: "author_id"))
      end

      it "skips reference and belongs_to columns, which Rails indexes itself" do
        missing = missing_for(<<~RUBY)
          create_table "posts" do |t|
            t.references "author"
            t.belongs_to "editor"
          end
        RUBY

        expect(missing).to be_empty
      end

      # On an app with uuid primary keys, a string `stripe_customer_id` and an
      # integer `partner_app_id` cannot reference any row in the database.
      it "leaves an external id alone when no table has a key of that type" do
        missing = missing_for(<<~RUBY)
          create_table "users", id: :uuid do |t|
            t.string "stripe_customer_id"
            t.integer "partner_app_id"
          end
        RUBY

        expect(missing).to be_empty
      end

      it "still reports one a foreign key declares" do
        missing = missing_for(<<~RUBY)
          create_table "users", id: :uuid do |t|
            t.string "stripe_customer_id"
          end

          create_table "orders", id: :uuid do |t|
            t.string "owner_id"
          end

          add_foreign_key "orders", "users", column: "owner_id"
        RUBY

        expect(missing).to contain_exactly(a_hash_including(table: "orders", column: "owner_id"))
      end

      # A private API app keeps bigint keys, so every integer external id -
      # imported_orders.order_id, ledger_accounts.company_id - matched "a key of
      # this type exists" and 115 of them were reported.
      it "leaves an _id column alone when no association or foreign key uses it" do
        missing = missing_for(<<~RUBY)
          create_table "sync_batches", id: false do |t|
            t.string "bid", primary_key: true
          end

          create_table "imported_orders" do |t|
            t.bigint "order_id"
            t.string "stripe_customer_id"
          end
        RUBY

        expect(missing).to be_empty
      end

      it "reports the column a has_many names from the other side" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "models"))
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "app", "models", "user.rb"), <<~RUBY)
            class User < ApplicationRecord
              has_many :posts
              has_one :profile, foreign_key: "owner_id"
            end
          RUBY
          File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\nend\n")
          File.write(File.join(dir, "app", "models", "profile.rb"), "class Profile < ApplicationRecord\nend\n")
          File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
            create_table "users" do |t|
            end

            create_table "posts" do |t|
              t.bigint "user_id"
              t.bigint "external_id"
            end

            create_table "profiles" do |t|
              t.bigint "owner_id"
            end
          RUBY

          missing = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_fk_indexes]

          expect(missing.map { |m| [ m[:table], m[:column] ] })
            .to contain_exactly([ "posts", "user_id" ], [ "profiles", "owner_id" ])
        end
      end

      # marketplace_transactions keeps the marketplace's own charge_id and
      # charge_type: a pair shaped like a polymorphic association that
      # no association reads.
      it "leaves a type and id pair alone when no association reads it" do
        missing = missing_for(<<~RUBY)
          create_table "marketplace_transactions" do |t|
            t.string "charge_id"
            t.string "charge_type"
          end
        RUBY

        expect(missing).to be_empty
      end

      # Mastodon's accounts_tags holds Tag's has_and_belongs_to_many :accounts.
      it "reports the join table columns a has_and_belongs_to_many reads" do
        models = { "tag.rb" => "class Tag < ApplicationRecord\n  has_and_belongs_to_many :accounts\nend\n",
                   "account.rb" => "class Account < ApplicationRecord\nend\n" }
        missing = missing_for(<<~RUBY, models)
          create_table "tags" do |t|
          end

          create_table "accounts" do |t|
          end

          create_table "accounts_tags", id: false do |t|
            t.bigint "account_id"
            t.bigint "tag_id"
          end
        RUBY

        expect(missing.map { |m| m[:column] }).to contain_exactly("account_id", "tag_id")
      end

      # structure.sql and the migration replay name a key's tables from_table
      # and to_table, and a check reading `from` counted none of them: Diaspora's
      # three signature_order_id keys, declared and unindexed, went unreported.
      it "reports a column a structure.sql foreign key declares" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "structure.sql"), <<~SQL)
            CREATE TABLE public.signature_orders (
                id bigint NOT NULL
            );

            CREATE TABLE public.like_signatures (
                id bigint NOT NULL,
                signature_order_id integer NOT NULL
            );

            ALTER TABLE ONLY public.like_signatures
                ADD CONSTRAINT like_signatures_signature_orders_id_fk FOREIGN KEY (signature_order_id) REFERENCES public.signature_orders(id);
          SQL

          missing = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_fk_indexes]

          expect(missing).to contain_exactly(a_hash_including(table: "like_signatures", column: "signature_order_id"))
        end
      end

      it "reports a column a replayed add_foreign_key declares" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db", "migrate"))
          File.write(File.join(dir, "db", "migrate", "20200101000000_create_schema.rb"), <<~RUBY)
            class CreateSchema < ActiveRecord::Migration[6.1]
              def change
                create_table :signature_orders
                create_table :like_signatures do |t|
                  t.integer :signature_order_id, null: false
                end
                add_foreign_key :like_signatures, :signature_orders
              end
            end
          RUBY

          missing = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_fk_indexes]

          expect(missing).to contain_exactly(a_hash_including(table: "like_signatures", column: "signature_order_id"))
        end
      end

      # The check read the model file alone: Diaspora's belongs_to
      # :signature_order sits in a concern, and OpenProject's parent_id columns
      # come from acts_as_tree and from an acts_as_nested_set in a concern.
      it "reads associations from concerns and parent keys from tree macros" do
        models = {
          "concerns/signature.rb" => "module Signature\n  extend ActiveSupport::Concern\n  included do\n    belongs_to :signature_order\n  end\nend\n",
          "like_signature.rb" => "class LikeSignature < ApplicationRecord\n  include Signature\nend\n",
          "enumeration.rb" => "class Enumeration < ApplicationRecord\n  acts_as_tree order: \"position ASC\"\nend\n",
          "concerns/hierarchy.rb" => "module Hierarchy\n  extend ActiveSupport::Concern\n  included do\n    acts_as_nested_set parent_column: :owner_id\n  end\nend\n",
          "project.rb" => "class Project < ApplicationRecord\n  include Hierarchy\nend\n"
        }
        missing = missing_for(<<~RUBY, models)
          create_table "like_signatures" do |t|
            t.integer "signature_order_id"
          end

          create_table "enumerations" do |t|
            t.integer "parent_id"
          end

          create_table "projects" do |t|
            t.integer "owner_id"
            t.integer "parent_id"
          end
        RUBY

        expect(missing.map { |m| [ m[:table], m[:column] ] })
          .to contain_exactly([ "like_signatures", "signature_order_id" ], [ "enumerations", "parent_id" ],
                              [ "projects", "owner_id" ])
      end

      # Rails strips the shared prefix: spree_roles and spree_users join
      # through spree_roles_users, not spree_roles_spree_users.
      it "names a habtm join table the way Rails does" do
        models = {
          "spree/role.rb" => "module Spree\n  class Role < ApplicationRecord\n    self.table_name = \"spree_roles\"\n    has_and_belongs_to_many :users, class_name: \"Spree::User\"\n  end\nend\n",
          "spree/user.rb" => "module Spree\n  class User < ApplicationRecord\n    self.table_name = \"spree_users\"\n  end\nend\n"
        }
        missing = missing_for(<<~RUBY, models)
          create_table "spree_roles_users", id: false do |t|
            t.integer "role_id"
            t.integer "user_id"
          end
        RUBY

        expect(missing.map { |m| [ m[:table], m[:column] ] })
          .to contain_exactly([ "spree_roles_users", "role_id" ], [ "spree_roles_users", "user_id" ])
      end

      # OpenProject's journal tables inherit belongs_to :author from an
      # abstract Journal::BaseJournal: the check reads the association list
      # the models section resolves, bases included.
      it "reads an association a model inherits from its abstract base" do
        models = {
          "journal/base_journal.rb" => "class Journal::BaseJournal < ApplicationRecord\n  self.abstract_class = true\n  belongs_to :author, class_name: \"User\"\nend\n",
          "journal/attachment_journal.rb" => "class Journal::AttachmentJournal < Journal::BaseJournal\n  self.table_name = \"attachment_journals\"\nend\n",
          "user.rb" => "class User < ApplicationRecord\nend\n"
        }
        missing = missing_for(<<~RUBY, models)
          create_table "attachment_journals" do |t|
            t.bigint "author_id"
            t.bigint "external_id"
          end
        RUBY

        expect(missing.map { |m| [ m[:table], m[:column] ] }).to contain_exactly([ "attachment_journals", "author_id" ])
      end

      it "takes the models section of the run instead of reading the models again" do
        allow(RailsAiContext::Introspectors::ModelIntrospector).to receive(:new).and_call_original
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"), "create_table \"posts\" do |t|\n  t.bigint \"user_id\"\nend\n")
          introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
          introspector.context = { models: { "Post" => { table_name: "posts", associations: [ { type: "belongs_to", name: "user" } ] } } }

          expect(introspector.call[:missing_fk_indexes]).to contain_exactly(a_hash_including(table: "posts", column: "user_id"))
        end
        expect(RailsAiContext::Introspectors::ModelIntrospector).not_to have_received(:new)
      end

      # The booted models section lifts a habtm's join_table and keys onto the
      # record with no options hash, as the static tier also does.
      it "reads a habtm's custom join table and keys off the models section" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
            create_table "post_labels", id: false do |t|
              t.bigint "article_id"
              t.bigint "label_id"
              t.bigint "other_id"
            end
          RUBY
          introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
          introspector.context = { models: {
            "Post" => { table_name: "posts", associations: [
              { type: "has_and_belongs_to_many", name: "labels", class_name: "Tag", join_table: "post_labels",
                foreign_key: "article_id", association_foreign_key: "label_id" }
            ] }
          } }

          expect(introspector.call[:missing_fk_indexes].map { |m| m[:column] }).to contain_exactly("article_id", "label_id")
        end
      end

      # `has_many :payments` inside Spree::Order is Spree::Payment, as Rails
      # and the dependency graph read it, so the unindexed key to report is
      # spree_payments.order_id, not the top-level Payment's.
      it "credits a has_many's key to the class the owner's namespace resolves" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
            create_table "spree_payments" do |t|
              t.bigint "order_id"
            end
            create_table "payments" do |t|
              t.bigint "order_id"
            end
          RUBY
          introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
          introspector.context = { models: {
            "Spree::Order" => { table_name: "spree_orders", associations: [ { type: "has_many", name: "payments" } ] },
            "Spree::Payment" => { table_name: "spree_payments", associations: [] },
            "Payment" => { table_name: "payments", associations: [] }
          } }

          missing = introspector.call[:missing_fk_indexes].map { |m| [ m[:table], m[:column] ] }

          expect(missing).to eq([ %w[spree_payments order_id] ])
        end
      end

      it "still reports one a belongs_to names" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "models"))
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "app", "models", "order.rb"), <<~RUBY)
            class Order < ApplicationRecord
              belongs_to :owner, class_name: "User", foreign_key: "owner_id"
            end
          RUBY
          File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
            create_table "orders", id: :uuid do |t|
              t.string "owner_id"
            end
          RUBY

          missing = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_fk_indexes]

          expect(missing).to contain_exactly(a_hash_including(table: "orders", column: "owner_id"))
        end
      end
    end

    # This check reads the table off the model itself, and underscoring the
    # class name asks for o_auth_client_configs - a table no app has, so every
    # model whose name carries an acronym was skipped in silence.
    context "missing counter_cache" do
      def counter_cache_for(model_path, model_source, schema_source, application: nil)
        Dir.mktmpdir do |dir|
          if application
            FileUtils.mkdir_p(File.join(dir, "config"))
            File.write(File.join(dir, "config", "application.rb"), application)
            RailsAiContext::Introspectors::TableName.clear_namespace_prefixes
          end
          FileUtils.mkdir_p(File.dirname(File.join(dir, "app", "models", model_path)))
          File.write(File.join(dir, "app", "models", model_path), model_source)
          File.write(File.join(dir, "app", "models", "token.rb"), "class Token < ApplicationRecord\nend\n")
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"), schema_source)
          described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_counter_cache]
        end
      end

      it "finds the table through the file name, not the underscored class name" do
        missing = counter_cache_for(
          "oauth_client_config.rb",
          "class OAuthClientConfig < ApplicationRecord\n  has_many :tokens\nend\n",
          "create_table \"oauth_client_configs\" do |t|\n  t.integer \"tokens_count\"\nend\n"
        )

        expect(missing).to contain_exactly(a_hash_including(model: "OAuthClientConfig", association: "tokens"))
      end

      it "wraps the file's table in the app's configured prefix" do
        missing = counter_cache_for(
          "post.rb",
          "class Post < ApplicationRecord\n  has_many :tokens\nend\n",
          "create_table \"op_posts\" do |t|\n  t.integer \"tokens_count\"\nend\n",
          application: "config.active_record.table_name_prefix = \"op_\"\n"
        )

        expect(missing).to contain_exactly(a_hash_including(model: "Post", association: "tokens"))
      end

      # The section derived tables its own way and could not see an enclosing
      # module's table_name_prefix, which the model tier resolves.
      it "reads the table the model tier resolves, an enclosing module's prefix included" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "models", "billing"))
          File.write(File.join(dir, "app", "models", "billing.rb"),
                     "module Billing\n  def self.table_name_prefix\n    \"billing_\"\n  end\nend\n")
          File.write(File.join(dir, "app", "models", "billing", "invoice.rb"),
                     "module Billing\n  class Invoice < ApplicationRecord\n    has_many :tokens\n  end\nend\n")
          File.write(File.join(dir, "app", "models", "token.rb"), "class Token < ApplicationRecord\nend\n")
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"), "create_table \"billing_invoices\" do |t|\n  t.integer \"tokens_count\"\nend\n")

          missing = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_counter_cache]

          expect(missing).to contain_exactly(a_hash_including(model: "Billing::Invoice", association: "tokens"))
        end
      end

      it "reads the table a model assigns itself" do
        missing = counter_cache_for(
          "tagging.rb",
          "class Tagging < ApplicationRecord\n  self.table_name = 'comments'\n  has_many :tokens\nend\n",
          "create_table \"comments\" do |t|\n  t.integer \"tokens_count\"\nend\n"
        )

        expect(missing).to contain_exactly(a_hash_including(model: "Tagging", association: "tokens"))
      end

      # The listener names the class node alone, so a model written inside a
      # module body was looked up as "Invoice" while its declaration reads
      # "Billing::Invoice", and its assigned table went unread.
      it "reads the assigned table of a model nested in a module body" do
        missing = counter_cache_for(
          File.join("billing", "invoice.rb"),
          "module Billing\n  class Invoice < ApplicationRecord\n    self.table_name = 'legacy_bills'\n" \
          "    has_many :tokens\n  end\nend\n",
          "create_table \"legacy_bills\" do |t|\n  t.integer \"tokens_count\"\nend\n"
        )

        expect(missing).to contain_exactly(a_hash_including(association: "tokens"))
      end

      def counter_culture_missing(post_body)
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "models"))
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "app", "models", "user.rb"), "class User < ApplicationRecord\n  has_many :posts\nend\n")
          File.write(File.join(dir, "app", "models", "post.rb"), "class Post < ApplicationRecord\n  belongs_to :user\n#{post_body}end\n")
          File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
            create_table "users" do |t|
              t.integer "posts_count", default: 0
            end
            create_table "posts" do |t|
              t.integer "user_id"
            end
          RUBY
          described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_counter_cache]
        end
      end

      # counter_culture keeps the column; counter_cache: true on top counts every create twice.
      it "says nothing about a column counter_culture keeps" do
        expect(counter_culture_missing("  counter_culture :user\n")).to eq([])
        expect(counter_culture_missing("  counter_culture :user, column_name: \"posts_count\"\n")).to eq([])
        expect(counter_culture_missing("  counter_culture :user, column_name: proc { |p| p.live? ? \"posts_count\" : nil }\n")).to eq([])
      end

      it "still flags a column counter_culture does not keep" do
        expect(counter_culture_missing("  counter_culture :user, column_name: \"live_posts_count\"\n"))
          .to contain_exactly(a_hash_including(model: "User", column: "posts_count"))
        expect(counter_culture_missing("")).to contain_exactly(a_hash_including(model: "User", column: "posts_count"))
      end

      # Following the hint on a counter the app maintains itself double-counts
      # every create and makes a reset stick only until the next destroy.
      it "says nothing about a counter the app writes itself" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "models"))
          FileUtils.mkdir_p(File.join(dir, "app", "services", "notifications"))
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "app", "models", "user.rb"),
                     "class User < ApplicationRecord
  has_many :notifications
end
")
          File.write(File.join(dir, "app", "models", "notification.rb"),
                     "class Notification < ApplicationRecord
  belongs_to :user
end
")
          File.write(File.join(dir, "app", "services", "notifications", "increment.rb"), <<~RUBY)
            class Notifications::Increment < ActiveInteraction::Base
              object :user

              def execute
                user.update_columns(notifications_count: user.notifications_count + 1)
              end
            end
          RUBY
          File.write(File.join(dir, "db", "schema.rb"),
                     "create_table \"users\" do |t|\n  t.integer \"notifications_count\"\nend\n")

          missing = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_counter_cache]

          expect(missing).to be_empty
        end
      end

      # The row is keyed by the constant the app has, or the same tool then
      # answers "Model 'Invoice' not found" for a row it just printed.
      it "names a model nested in a module body by its qualified constant" do
        missing = counter_cache_for(
          File.join("billing", "invoice.rb"),
          "module Billing\n  class Invoice < ApplicationRecord\n    has_many :tokens\n  end\nend\n",
          "create_table \"invoices\" do |t|\n  t.integer \"tokens_count\"\nend\n"
        )

        expect(missing).to contain_exactly(
          a_hash_including(model: "Billing::Invoice",
                           suggestion: "Add counter_cache: true to belongs_to :invoice in Token")
        )
      end

      # The suggestion has to name the class the app can look up, or it sends
      # the reader to a constant a namespaced app does not have.
      it "names the resolved belongs_to side by its qualified constant" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "models", "billing"))
          File.write(File.join(dir, "app", "models", "billing", "invoice.rb"),
                     "module Billing\n  class Invoice < ApplicationRecord\n    has_many :tokens\n  end\nend\n")
          File.write(File.join(dir, "app", "models", "billing", "token.rb"),
                     "module Billing\n  class Token < ApplicationRecord\n    belongs_to :invoice\n  end\nend\n")
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"),
                     "create_table \"invoices\" do |t|\n  t.integer \"tokens_count\"\nend\n")

          missing = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_counter_cache]

          expect(missing).to contain_exactly(
            a_hash_including(model: "Billing::Invoice",
                             suggestion: "Add counter_cache: true to belongs_to :invoice in Billing::Token")
          )
        end
      end

      it "finds the declared counter cache on a child nested in the same module body" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "models", "billing"))
          File.write(File.join(dir, "app", "models", "billing", "invoice.rb"),
                     "module Billing\n  class Invoice < ApplicationRecord\n    has_many :tokens\n  end\nend\n")
          File.write(File.join(dir, "app", "models", "billing", "token.rb"),
                     "module Billing\n  class Token < ApplicationRecord\n" \
                     "    belongs_to :invoice, counter_cache: true\n  end\nend\n")
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"),
                     "create_table \"invoices\" do |t|\n  t.integer \"tokens_count\"\nend\n")

          missing = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_counter_cache]

          expect(missing).to be_empty
        end
      end

      # The association's own class_name is the answer; the name it is
      # written under is only the fallback.
      it "names the class the association declares" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "models"))
          File.write(File.join(dir, "app", "models", "post.rb"),
                     "class Post < ApplicationRecord\n  has_many :remarks, class_name: 'Comment'\nend\n")
          File.write(File.join(dir, "app", "models", "comment.rb"),
                     "class Comment < ApplicationRecord\n  belongs_to :post\nend\n")
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"),
                     "create_table \"posts\" do |t|\n  t.integer \"remarks_count\"\nend\n")

          missing = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:missing_counter_cache]

          expect(missing).to contain_exactly(
            a_hash_including(suggestion: "Add counter_cache: true to belongs_to :post in Comment")
          )
        end
      end

      it "leaves the row out when the declared class is not a model in the app" do
        missing = counter_cache_for(
          "post.rb",
          "class Post < ApplicationRecord\n  has_many :remarks, class_name: 'Comment'\nend\n",
          "create_table \"posts\" do |t|\n  t.integer \"remarks_count\"\nend\n"
        )

        expect(missing).to be_empty
      end

      it "leaves the row out when nothing in the app answers the association name" do
        missing = counter_cache_for(
          "post.rb",
          "class Post < ApplicationRecord\n  has_many :remarks\nend\n",
          "create_table \"posts\" do |t|\n  t.integer \"remarks_count\"\nend\n"
        )

        expect(missing).to be_empty
      end

      # A :through association reaches its records over another one, so there
      # is no belongs_to on the far side to hold the counter.
      it "skips a has_many :through" do
        missing = counter_cache_for(
          "post.rb",
          "class Post < ApplicationRecord\n  has_many :tokens, through: :sessions\nend\n",
          "create_table \"posts\" do |t|\n  t.integer \"tokens_count\"\nend\n"
        )

        expect(missing).to be_empty
      end

      it "names the polymorphic belongs_to by the association's :as option" do
        missing = counter_cache_for(
          "post.rb",
          "class Post < ApplicationRecord\n  has_many :tokens, as: :holder\nend\n",
          "create_table \"posts\" do |t|\n  t.integer \"tokens_count\"\nend\n"
        )

        expect(missing).to contain_exactly(
          a_hash_including(suggestion: "Add counter_cache: true to belongs_to :holder in Token")
        )
      end
    end

    # Two models can demodulize to one word. The bare key is what the scan
    # captures, so the controller's own namespace has to break the tie, or the
    # row names whichever model happened to be written last.
    describe "two models sharing one demodulized name" do
      def n1_for(controller_path, controller_source)
        Dir.mktmpdir do |dir|
          %w[billing legacy].each do |ns|
            FileUtils.mkdir_p(File.join(dir, "app", "models", ns))
            File.write(File.join(dir, "app", "models", ns, "invoice.rb"),
                       "module #{ns.capitalize}\n  class Invoice < ApplicationRecord\n" \
                       "    has_many :lines\n  end\nend\n")
          end
          FileUtils.mkdir_p(File.dirname(File.join(dir, "app", "controllers", controller_path)))
          File.write(File.join(dir, "app", "controllers", controller_path), controller_source)
          described_class.new(RailsAiContext::StaticApp.new(dir)).call[:n_plus_one_risks]
        end
      end

      it "takes the model in the controller's own namespace" do
        risks = n1_for(File.join("billing", "invoices_controller.rb"), <<~RUBY)
          module Billing
            class InvoicesController < ApplicationController
              def index
                @invoices = Invoice.all
                @invoices.each { |invoice| logger.info(invoice.lines.size) }
              end
            end
          end
        RUBY

        expect(risks).to contain_exactly(a_hash_including(model: "Billing::Invoice", association: "lines"))
      end

      it "leaves the row out when no namespace picks one of them" do
        risks = n1_for("invoices_controller.rb", <<~RUBY)
          class InvoicesController < ApplicationController
            def index
              @invoices = Invoice.all
              @invoices.each { |invoice| logger.info(invoice.lines.size) }
            end
          end
        RUBY

        expect(risks).to be_empty
      end
    end

    it "names an eager-load candidate nested in a module body by its qualified constant" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "billing"))
        File.write(File.join(dir, "app", "models", "billing", "invoice.rb"),
                   "module Billing\n  class Invoice < ApplicationRecord\n" \
                   "    has_many :tokens\n    has_many :notes\n  end\nend\n")

        candidates = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:eager_load_candidates]

        expect(candidates).to contain_exactly(a_hash_including(model: "Billing::Invoice"))
      end
    end

    it "detects Model.all in controllers" do
      expect(result[:model_all_in_controllers]).to be_an(Array)
      models = result[:model_all_in_controllers].map { |f| f[:model] }
      expect(models).to include("Post")
    end

    it "provides suggestions for Model.all findings" do
      finding = result[:model_all_in_controllers].find { |f| f[:model] == "Post" }
      expect(finding[:suggestion]).to include("pagination")
    end

    it "detects eager load candidates" do
      expect(result[:eager_load_candidates]).to be_an(Array)
    end

    it "builds a summary with counts" do
      expect(result[:summary]).to be_a(Hash)
      expect(result[:summary][:total_issues]).to be_an(Integer)
      expect(result[:summary][:model_all_in_controllers]).to be >= 1
    end
  end

  describe "N+1 risk level detection" do
    let(:controllers_dir) { File.join(Rails.root, "app/controllers") }
    let(:views_dir) { File.join(Rails.root, "app/views/n1_test") }
    let(:fixture_ctrl) { File.join(controllers_dir, "n1_test_controller.rb") }
    let(:fixture_view) { File.join(views_dir, "index.html.erb") }

    before do
      FileUtils.mkdir_p(views_dir)
    end

    after do
      FileUtils.rm_f(fixture_ctrl)
      FileUtils.rm_rf(views_dir)
    end

    def n1_risks
      introspector.call[:n_plus_one_risks].select { |r| r[:controller]&.include?("n1_test") }
    end

    context "high risk: collection query + view association access, no preloading" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @posts = Post.all
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @posts.each do |post| %>
            <p><%= post.comments.count %></p>
          <% end %>
        ERB
      end

      it "detects high risk" do
        risks = n1_risks
        expect(risks).not_to be_empty
        risk = risks.find { |r| r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("high")
      end

      it "includes action name" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk[:action]).to eq("index")
      end

      it "provides preloading suggestion" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk[:suggestion]).to include("includes(:comments)")
        expect(risk[:suggestion]).to include("Post")
      end
    end

    context "medium risk: has preloading but not for target association" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @users = User.where(active: true).includes(:posts)
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @users.each do |user| %>
            <p><%= user.comments.count %></p>
          <% end %>
        ERB
      end

      it "detects medium risk when wrong association is preloaded" do
        risks = n1_risks
        risk = risks.find { |r| r[:model] == "User" && r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("medium")
      end

      it "suggests adding to includes list" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk[:suggestion]).to include("missing :comments")
      end
    end

    context "low risk: association is already preloaded" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @posts = Post.all.includes(:comments)
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @posts.each do |post| %>
            <p><%= post.comments.count %></p>
          <% end %>
        ERB
      end

      it "detects low risk when association is preloaded" do
        risks = n1_risks
        risk = risks.find { |r| r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("low")
      end

      it "says no action needed" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk[:suggestion]).to include("no action needed")
      end
    end

    context "with multi-line query chain" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @posts = Post.where(published: true)
                          .order(created_at: :desc)
                          .includes(:comments)
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @posts.each do |post| %>
            <p><%= post.comments.size %></p>
          <% end %>
        ERB
      end

      it "detects preloading in multi-line chain as low risk" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("low")
      end
    end

    context "with eager_load instead of includes" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @posts = Post.all.eager_load(:comments)
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @posts.each do |post| %>
            <p><%= post.comments.size %></p>
          <% end %>
        ERB
      end

      it "recognizes eager_load as preloading" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("low")
      end
    end

    context "with loop in controller body (no view access)" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              @posts = Post.all
              @posts.each do |post|
                post.comments.each { |c| logger.info(c.body) }
              end
            end
          end
        RUBY
      end

      it "detects N+1 from controller loop pattern" do
        risk = n1_risks.find { |r| r[:association] == "comments" }
        expect(risk).not_to be_nil
        expect(risk[:risk]).to eq("high")
      end
    end

    context "with no collection query" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def show
              @post = Post.find(1)
            end
          end
        RUBY
      end

      it "does not flag single-record loads" do
        expect(n1_risks).to be_empty
      end
    end

    context "with private method (not an action)" do
      before do
        File.write(fixture_ctrl, <<~RUBY)
          class N1TestController < ApplicationController
            def index
              render plain: "ok"
            end

            private

            def load_posts
              @posts = Post.all
            end
          end
        RUBY
        File.write(fixture_view, <<~ERB)
          <% @posts.each do |post| %>
            <p><%= post.comments.count %></p>
          <% end %>
        ERB
      end

      it "does not flag queries in private methods" do
        expect(n1_risks).to be_empty
      end
    end
  end

  describe "extract_controller_actions" do
    it "extracts public actions only" do
      source = <<~RUBY
        class FooController < ApplicationController
          def index
            @items = []
          end

          def show
            @item = nil
          end

          private

          def set_item
            @item = nil
          end
        end
      RUBY
      actions = introspector.send(:extract_controller_actions, source)
      expect(actions.keys).to contain_exactly("index", "show")
      expect(actions).not_to have_key("set_item")
    end

    it "captures full action body" do
      source = <<~RUBY
        class FooController < ApplicationController
          def index
            @posts = Post.all
            respond_to do |format|
              format.html
            end
          end
        end
      RUBY
      actions = introspector.send(:extract_controller_actions, source)
      expect(actions["index"]).to include("Post.all")
      expect(actions["index"]).to include("respond_to")
    end

    it "ignores methods defined in a class nested inside the controller" do
      source = <<~RUBY
        class FooController < ApplicationController
          class Helper
            def build
              @things = Thing.all
            end
          end

          def index
            @items = []
          end
        end
      RUBY
      actions = introspector.send(:extract_controller_actions, source)
      expect(actions.keys).to contain_exactly("index")
    end

    it "takes the action's own body when a nested class defines the same name first" do
      source = <<~RUBY
        class FooController < ApplicationController
          class Decorator
            def index
              @nothing = 1
            end
          end

          def index
            @posts = Post.all
          end
        end
      RUBY
      actions = introspector.send(:extract_controller_actions, source)
      expect(actions["index"]).to include("Post.all")
      expect(actions["index"]).not_to include("@nothing")
    end

    it "keeps a one-line private def out of the preceding action" do
      source = <<~RUBY
        class FooController < ApplicationController
          def index
            @posts = Post.all
          end

          private def set_post = @post = Post.where(id: params[:id])
        end
      RUBY
      actions = introspector.send(:extract_controller_actions, source)
      expect(actions.keys).to contain_exactly("index")
      expect(actions["index"]).not_to include("Post.where")
    end
  end

  describe "models and controllers across every source directory" do
    it "reads a pack's model and controller" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "controllers"))
        File.write(File.join(dir, "packs", "billing", "app", "models", "invoice.rb"),
                   "class Invoice < ApplicationRecord\n  has_many :lines\n  has_many :payments\nend\n")
        File.write(File.join(dir, "packs", "billing", "app", "controllers", "invoices_controller.rb"),
                   "class InvoicesController < ApplicationController\n  def index\n    @invoices = Invoice.all\n  end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        expect(result[:eager_load_candidates].map { |c| c[:model] }).to eq([ "Invoice" ])
        expect(result[:model_all_in_controllers].map { |f| f[:controller] })
          .to eq([ "packs/billing/app/controllers/invoices_controller.rb" ])
      end
    end
  end

  # Three separate walks asked app/models for answers two of them could read
  # off the first, and the AST cache holds 500 entries, so a 3,000-model app
  # re-parsed every model twice for nothing.
  describe "model walk cost" do
    it "parses a model once" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            has_many :comments
            has_many :tags
          end
        RUBY

        walks = 0
        allow(RailsAiContext::Introspectors::SourceIntrospector)
          .to receive(:walk_source).and_wrap_original do |original, source, *rest|
          walks += 1 if source.to_s.include?("class Post")
          original.call(source, *rest)
        end

        # The run's models section, as the introspection loop hands it over.
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        introspector.context = { models: { "Post" => { table_name: "posts", associations: [] } } }
        introspector.call

        expect(walks).to eq(1)
      end
    end
  end

  # `belongs_to owner_name` classifies to `OwnerName`, and an app that happens
  # to have that model got a row pointing at the wrong one.
  describe "#association_model with a computed name" do
    let(:introspector) { described_class.new(RailsAiContext::StaticApp.new(Dir.pwd)) }
    let(:models) { [ { name: "OwnerName" }, { name: "Token::API" } ] }

    it "matches no model on a name it cannot read" do
      assoc = { name: "owner_name", computed_name: true, options: {} }

      expect(introspector.send(:association_model, models, assoc, "Account")).to be_nil
    end

    it "still matches the class a computed name declares" do
      assoc = { name: "owner_name", computed_name: true, options: { class_name: "::Token::API" } }

      expect(introspector.send(:association_model, models, assoc, "Account")).to eq(name: "Token::API")
    end

    # `has_many :payments` in Shop::Order is Shop::Payment, as the graph reads it.
    it "resolves from the owner's namespace, as every other reader does" do
      models = [ { name: "Payment" }, { name: "Shop::Payment" } ]
      assoc = { name: "payments", options: {} }

      expect(introspector.send(:association_model, models, assoc, "Shop::Order")).to eq(name: "Shop::Payment")
    end
  end
end
