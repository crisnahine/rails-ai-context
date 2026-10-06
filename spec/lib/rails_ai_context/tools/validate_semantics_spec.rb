# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The one tool file that had no spec of its own. These drive the dispatcher
# through its public seam; the rules gain coverage as they change.
RSpec.describe RailsAiContext::Tools::ValidateSemantics do
  def with_app_file(relative, content)
    Dir.mktmpdir do |root|
      full = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      yield relative, full
    end
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({
      routes: { by_controller: {} },
      schema: { tables: {} },
      models: {}
    })
  end

  # OFN's Spree views call the engine's helpers bare, and its Spree
  # controllers answer routes in the engine's table.
  describe "routes an app draws into an engine" do
    let(:engine_routes) do
      [ { engine: "Spree::Core::Engine", mount: "/", routes: [
        { verb: "GET", path: "/admin/orders", controller: "spree/admin/orders", action: "index", name: "spree.admin_orders" },
        { verb: "GET", path: "/admin/orders/:id/fire", controller: "spree/admin/orders", action: "fire" }
      ] } ]
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({
        routes: { by_controller: { "posts" => [ { verb: "GET", action: "index", name: "posts" } ] }, engine_routes: engine_routes },
        controllers: { controllers: { "Spree::Admin::OrdersController" => { actions: %w[index] } } },
        schema: { tables: {} }, models: {}
      })
    end

    it "knows the engine's route helpers" do
      with_app_file("app/views/spree/admin/orders/_x.html.erb", "<%= link_to 'x', admin_orders_path %>\n") do |file, path|
        expect(described_class.check_rails_semantics(file, path).join).not_to include("admin_orders_path")
      end
    end

    it "checks an engine controller against the engine's routes" do
      with_app_file("app/controllers/spree/admin/orders_controller.rb",
                    "module Spree\n  module Admin\n    class OrdersController < BaseController\n      def index; end\n    end\n  end\nend\n") do |file, path|
        root = path.delete_suffix(file)
        File.write(File.join(root, "app/controllers/spree/admin/base_controller.rb"),
                   "module Spree\n  module Admin\n    class BaseController < ApplicationController\n    end\n  end\nend\n")
        File.write(File.join(root, "app/controllers/application_controller.rb"), "class ApplicationController < ActionController::Base\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))

        expect(described_class.check_rails_semantics(file, path).join).to include("fire - action not found")
      end
    end
  end

  # OFN's ApplicationController includes Pagy::Backend, a gem module this
  # check never reads, so it cannot say the gem defines no `show`.
  describe "a routed action no source the app holds defines" do
    def check(app_controller, extra = {}, predicate: false)
      Dir.mktmpdir do |root|
        files = {
          "app/controllers/orders_controller.rb" => "class OrdersController < ApplicationController\n  def index; end\nend\n",
          "app/controllers/application_controller.rb" => app_controller
        }.merge(extra)
        files.each do |relative, body|
          FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
          File.write(File.join(root, relative), body)
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          routes: { by_controller: { "orders" => [ { verb: "GET", path: "/orders", action: "index" },
                                                   { verb: "GET", path: "/orders/:id", action: "show" },
                                                   { verb: "GET", path: "/orders/managed", action: predicate ? "managed?" : "managed" } ] } },
          controllers: { controllers: { "OrdersController" => { actions: %w[index] } } },
          schema: { tables: {} }, models: {}
        })
        file = "app/controllers/orders_controller.rb"
        return described_class.check_rails_semantics(file, File.join(root, file)).join("\n")
      end
    end

    it "names it missing when the app holds every ancestor and mixin" do
      text = check("class ApplicationController < ActionController::Base\nend\n")

      expect(text).to include("show - action not found").and include("managed - action not found")
    end

    it "says it is unverified when an ancestor includes a module the app does not hold" do
      text = check("class ApplicationController < ActionController::Base\n  include Pagy::Backend\nend\n")

      expect(text).not_to include("action not found")
      expect(text).to include("show, managed").and include("Pagy::Backend")
    end

    it "says it is unverified when an ancestor is a gem's class" do
      text = check("class ApplicationController < Spree::BaseController\nend\n")

      expect(text).not_to include("action not found")
      expect(text).to include("Spree::BaseController")
    end

    # Mastodon routes `get :merged, to: "requests#merged?"`.
    it "finds a predicate-named action an ancestor defines" do
      text = check("class ApplicationController < ActionController::Base\n  def show; end\n  def managed?; end\nend\n", predicate: true)

      expect(text).not_to match(/show|managed/)
    end

    it "finds an action an app concern included by an ancestor defines, and one a template renders" do
      text = check("class ApplicationController < ActionController::Base\n  include Managing\nend\n",
                   { "app/controllers/concerns/managing.rb" => "module Managing\n  def managed; end\nend\n",
                     "app/views/orders/show.html.erb" => "" })

      expect(text).not_to match(/show|managed/)
    end
  end

  describe "a foreign key over two columns" do
    def fk_warnings(indexes, primary_key: "id")
      context = {
        schema: { tables: { "event_refs" => { columns: [], indexes: indexes, primary_key: primary_key,
                                              foreign_keys: [ { column: %w[event_id event_day], to_table: "events" } ] } } },
        models: { "EventRef" => { table_name: "event_refs", file: "app/models/event_ref.rb", associations: [] } }
      }
      described_class.send(:check_missing_fk_index, "app/models/event_ref.rb", context)
    end

    it "counts an index leading with its columns" do
      expect(fk_warnings([ { columns: %w[event_day event_id] } ])).to eq([])
    end

    # connection.indexes leaves out the primary key's own index.
    it "counts a primary key over its columns" do
      expect(fk_warnings([], primary_key: %w[event_id event_day])).to eq([])
    end

    it "suggests one index over its columns when none leads with them" do
      expect(fk_warnings([]).join).to include("add_index :event_refs, [:event_id, :event_day]")
    end
  end

  describe "a polymorphic belongs_to" do
    def poly_warnings(indexes)
      assoc = { type: "belongs_to", name: "commentable", polymorphic: true, foreign_key: "commentable_id" }
      context = {
        schema: { tables: { "comments" => { columns: [], indexes: indexes, foreign_keys: [] } } },
        models: { "Comment" => { table_name: "comments", file: "app/models/comment.rb", associations: [ assoc ] } }
      }
      described_class.send(:check_missing_fk_index, "app/models/comment.rb", context)
    end

    it "counts the type and id index the reference creates, in either order" do
      expect(poly_warnings([ { columns: %w[commentable_type commentable_id] } ])).to eq([])
      expect(poly_warnings([ { columns: %w[commentable_id commentable_type] } ])).to eq([])
    end

    it "warns when no index covers the key" do
      expect(poly_warnings([]).join).to include("commentable_id in comments - foreign key without index")
    end
  end

  describe "a belongs_to whose key column the table does not have" do
    def key_warnings(columns)
      assoc = { type: "belongs_to", name: "owner", foreign_key: "owner_id" }
      context = {
        schema: { tables: { "predictions" => { columns: columns.map { |c| { name: c } }, indexes: [], foreign_keys: [] } } },
        models: { "Prediction" => { table_name: "predictions", file: "app/models/prediction.rb", associations: [ assoc ] } }
      }
      described_class.send(:check_missing_fk_index, "app/models/prediction.rb", context)
    end

    it "says the column is missing, not that it is unindexed" do
      text = key_warnings(%w[id owner_user_id]).join("\n")

      expect(text).not_to include("without index")
      expect(text).to include("belongs_to :owner - column \"owner_id\" not found in predictions table")
    end

    it "still asks for an index on a key column the table has" do
      expect(key_warnings(%w[id owner_id]).join).to include("owner_id in predictions - foreign key without index")
    end
  end

  describe "a belongs_to whose key is not a plain column name" do
    def warnings_for(assoc, columns: %w[id shop_id order_id], indexes: [])
      context = {
        schema: { tables: { "lines" => { columns: columns.map { |c| { name: c } }, indexes: indexes, foreign_keys: [] } } },
        models: { "Line" => { table_name: "lines", file: "app/models/line.rb", associations: [ { type: "belongs_to", name: "order" }.merge(assoc) ] } }
      }
      described_class.send(:check_missing_fk_index, "app/models/line.rb", context)
    end

    it "says nothing about a key a constant or an expression names, or one declared in a block of unknown owner" do
      expect(warnings_for({ foreign_key: "AUTHOR_KEY", computed_foreign_key: true })).to eq([])
      expect(warnings_for({ foreign_key: "parent_id", scope_uncertain: true })).to eq([])
      expect(warnings_for({ foreign_key: "\"\#{PREFIX}_id\"" })).to eq([])
    end

    it "checks each column of a composite key and an index leading with them" do
      expect(warnings_for({ foreign_key: %w[shop_id order_id] }, indexes: [ { columns: %w[shop_id order_id] } ])).to eq([])
      expect(warnings_for({ foreign_key: %w[shop_id order_id] }).join).to include("(shop_id, order_id) in lines - foreign key without an index")
      expect(warnings_for({ foreign_key: %w[shop_id order_id] }, columns: %w[id shop_id]).join)
        .to include("column \"(shop_id, order_id)\" not found in lines table")
    end
  end

  # Canvas's `t.replica_identity_index` indexes root_account_id through an app
  # method the static schema cannot read, so its index list may be short.
  describe "a table whose schema block called a method no reader interprets" do
    it "claims neither a missing index nor a missing column" do
      assoc = { type: "belongs_to", name: "root_account", foreign_key: "root_account_id" }
      table = { columns: [ { name: "id" }, { name: "root_account_id" } ], indexes: [], foreign_keys: [],
                unread_calls: %w[replica_identity_index] }
      context = {
        schema: { tables: { "summaries" => table } },
        models: { "Summary" => { table_name: "summaries", file: "app/models/summary.rb",
                                 associations: [ assoc, assoc.merge(name: "user", foreign_key: "user_id") ] } }
      }

      expect(described_class.send(:check_missing_fk_index, "app/models/summary.rb", context)).to eq([])
    end
  end

  describe "a model backed by a view, a virtual table or a table the dump left out" do
    def context_for(table)
      {
        schema: { tables: { "published_posts" => table } },
        models: { "PublishedPost" => { table_name: "published_posts", file: "app/models/published_post.rb",
                                       associations: [ { type: "belongs_to", name: "user", foreign_key: "user_id" } ] } }
      }
    end

    let(:view) { { kind: "view", columns: [], indexes: [], foreign_keys: [], sql: "SELECT id, title, user_id FROM posts" } }
    let(:booted_view) { view.merge(columns: %w[id title user_id].map { |c| { name: c } }) }
    let(:not_dumped) { { columns: [], indexes: [], foreign_keys: [], not_dumped: "ignored" } }
    let(:permit) { double(permit_calls: [ { require_key: :published_post, params: %w[title user_id] } ]) }

    it "asks for no index on it" do
      [ view, booted_view, not_dumped, { kind: "virtual_table", columns: [ { name: "user_id" } ], indexes: [], foreign_keys: [] } ].each do |table|
        expect(described_class.send(:check_missing_fk_index, "app/models/published_post.rb", context_for(table))).to eq([])
      end
    end

    it "still checks a materialized view whose indexes the dump records" do
      table = view.merge(kind: "materialized_view", columns: [ { name: "user_id" } ], indexes: [ { columns: %w[title] } ])
      expect(described_class.send(:check_missing_fk_index, "app/models/published_post.rb", context_for(table)).join)
        .to include("user_id in published_posts - foreign key without index")
    end

    it "flags no permitted param when the columns are not known" do
      [ view, not_dumped ].each do |table|
        expect(described_class.send(:check_strong_params_ast, "app/controllers/published_posts_controller.rb", permit, context_for(table))).to eq([])
      end
    end

    it "checks permitted params against a view's columns when the connection listed them" do
      table = booted_view.merge(columns: [ { name: "id" }, { name: "user_id" } ])
      expect(described_class.send(:check_strong_params_ast, "app/controllers/published_posts_controller.rb", permit, context_for(table)).join)
        .to include("permits :title - not a column in published_posts")
    end
  end

  describe ".check_rails_semantics" do
    it "answers cleanly for a plain file" do
      with_app_file("app/models/widget.rb", "class Widget < ApplicationRecord\nend\n") do |file, path|
        warnings = described_class.check_rails_semantics(file, path)
        expect(warnings).to eq([])
      end
    end

    it "says which checks were skipped when the AST parse fails, instead of reading as clean" do
      allow(RailsAiContext::AstCache).to receive(:parse_string).and_raise(RuntimeError, "prism exploded")

      with_app_file("app/models/widget.rb", "class Widget < ApplicationRecord\nend\n") do |file, path|
        warnings = described_class.check_rails_semantics(file, path)
        expect(warnings.join).to include("AST parse failed")
        expect(warnings.join).to include("skipped")
      end
    end

    # ActiveModel's AcceptanceValidator defines the reader and the writer
    # when no column exists, so the suggested migration adds a column nobody
    # wants.
    context "a model whose attribute has no column" do
      let(:context_with_schema) do
        {
          routes: { by_controller: {} },
          schema: { tables: { "subscriptions" => { columns: [ { name: "id" }, { name: "account_id" } ] } } },
          models: { "Subscription" => { table_name: "subscriptions", file: "app/models/subscription.rb",
                                        associations: [ { name: "account", foreign_key: "account_id" } ] } }
        }
      end

      before { allow(described_class).to receive(:cached_context).and_return(context_with_schema) }

      it "says nothing about an acceptance attribute" do
        source = <<~RUBY
          class Subscription < ApplicationRecord
            belongs_to :account
            validates :terms_of_use, acceptance: { accept: true }, allow_nil: false, on: :user_create
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          expect(described_class.check_rails_semantics(file, path).join).not_to include("terms_of_use")
        end
      end

      it "says nothing about an attribute the model declares itself" do
        source = <<~RUBY
          class Subscription < ApplicationRecord
            attr_accessor :confirm_terms
            attribute :promo_code, :string
            attr_reader :config_url
            alias_attribute :title, :account_id
            validates :confirm_terms, presence: true
            validates :promo_code, presence: true
            validates :config_url, :title, presence: true
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          warnings = described_class.check_rails_semantics(file, path).join
          expect(warnings).not_to include("confirm_terms")
          expect(warnings).not_to include("promo_code")
          expect(warnings).not_to include("config_url")
          expect(warnings).not_to include("title")
        end
      end

      # OpenProject's `has_details_table do` class_evals its block on a detail
      # class, so a validation there reads that class's table.
      it "says nothing about a validation inside a block run on another class" do
        source = <<~RUBY
          class Subscription < ApplicationRecord
            has_details_table(foreign_key: :subscription_id) do
              validates :parent, presence: true
            end
            validates :headline, presence: true
            with_options on: :create do
              validates :byline, presence: true
            end
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          warnings = described_class.check_rails_semantics(file, path).join
          expect(warnings).not_to include("parent")
          expect(warnings).to include("validates :headline").and include("validates :byline")
        end
      end

      it "judges a validation in a mixin hook's class_eval and in a state_machine state block" do
        source = <<~RUBY
          class Subscription < ApplicationRecord
            def self.included(base)
              base.class_eval do
                validates :headline, presence: true
              end
            end
            state_machine :status do
              state :done do
                validates :byline, presence: true
              end
            end
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          warnings = described_class.check_rails_semantics(file, path).join
          expect(warnings).to include("validates :headline").and include("validates :byline")
        end
      end

      # Lockbox's `has_encrypted :document_id` keeps a `_ciphertext` column.
      it "says nothing about an encrypted attribute or a store key" do
        source = <<~RUBY
          class Subscription < ApplicationRecord
            has_encrypted :document_id
            encrypts :ssn
            attr_encrypted :tax_id
            store_accessor :settings, :color
            store :prefs, accessors: [ :theme ], coder: JSON
            validates :document_id, :ssn, :tax_id, :color, :theme, presence: true
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          warnings = described_class.check_rails_semantics(file, path).join
          %w[document_id ssn tax_id color theme].each { |name| expect(warnings).not_to include(name) }
        end
      end

      it "reads an escaped symbol as the column name the schema carries" do
        context = context_with_schema.dup
        context[:schema] = { tables: { "subscriptions" => { columns: [ { name: "id" }, { name: "first\tname" } ] } } }
        allow(described_class).to receive(:cached_context).and_return(context)
        source = <<~'RUBY'
          class Subscription < ApplicationRecord
            validates :"first\tname", presence: true
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          expect(described_class.check_rails_semantics(file, path).join).not_to include("not found")
        end
      end

      it "still flags a column the table does not have" do
        source = <<~RUBY
          class Subscription < ApplicationRecord
            validates :nickname, presence: true
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          expect(described_class.check_rails_semantics(file, path).join).to include("nickname")
        end
      end
    end

    # A `<%#` comment body is not code, so an ivar inside one is not used.
    context "a view with a commented-out instance variable" do
      around do |example|
        Dir.mktmpdir do |root|
          @root = root
          FileUtils.mkdir_p(File.join(root, "app/views/widgets"))
          FileUtils.mkdir_p(File.join(root, "app/controllers"))
          File.write(File.join(root, "app/controllers/widgets_controller.rb"),
                     "class WidgetsController < ApplicationController\n  def show\n  end\nend\n")
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return({
          routes: { by_controller: {} },
          schema: { tables: {} },
          models: {},
          controllers: { controllers: { "WidgetsController" => { file: "app/controllers/widgets_controller.rb" } } }
        })
      end

      def warnings_for(view_source)
        file = "app/views/widgets/show.html.erb"
        full = File.join(@root, file)
        File.write(full, view_source)
        described_class.check_rails_semantics(file, full).join("\n")
      end

      it "says nothing about an ivar that only appears in a comment tag" do
        expect(warnings_for("<%# @ghost %>\n")).not_to include("@ghost")
      end

      it "still flags an ivar the template really reads" do
        expect(warnings_for("<%= @real %>\n")).to include("@real used in view but not set in WidgetsController")
      end
    end

    # The payload lists thirty instance methods, so a callback naming one the
    # model inherits past that cap is not missing. Booted, the loaded class
    # answers; statically, a truncated list cannot say it is absent.
    context "a callback method the capped method list leaves out" do
      let(:source) { "class CallbackWidget < ApplicationRecord\n  before_save :normalize_email\nend\n" }

      def context_with(count)
        {
          routes: { by_controller: {} },
          schema: { tables: {} },
          models: { "CallbackWidget" => { file: "app/models/callback_widget.rb", concerns: [],
                                          instance_methods: (1..30).map { |i| "step_#{i}" },
                                          instance_method_count: count } }
        }
      end

      def warnings_for(context)
        allow(described_class).to receive(:cached_context).and_return(context)
        with_app_file("app/models/callback_widget.rb", source) do |file, path|
          described_class.check_rails_semantics(file, path).join("\n")
        end
      end

      it "asks the loaded class on the booted tier" do
        stub_const("CallbackWidget", Class.new(ActiveRecord::Base) { def normalize_email; end })

        expect(warnings_for(context_with(40))).not_to include("normalize_email")
      end

      # Callbacks run private methods, and a base class usually keeps them
      # private.
      it "counts a private method the class inherits" do
        parent = Class.new(ActiveRecord::Base) do
          self.abstract_class = true

          private

          def normalize_email; end
        end
        stub_const("CallbackWidget", Class.new(parent))

        expect(warnings_for(context_with(40))).not_to include("normalize_email")
      end

      it "still flags a method the loaded class lacks" do
        stub_const("CallbackWidget", Class.new(ActiveRecord::Base))

        expect(warnings_for(context_with(40))).to include("before_save :normalize_email - method not found")
      end

      it "makes no claim from a truncated list on the static tier" do
        allow(RailsAiContext).to receive(:static_tier?).and_return(true)

        expect(warnings_for(context_with(40))).not_to include("normalize_email")
      end

      it "still flags a method a complete list lacks on the static tier" do
        allow(RailsAiContext).to receive(:static_tier?).and_return(true)

        expect(warnings_for(context_with(30))).to include("before_save :normalize_email - method not found")
      end
    end

    it "flags a scope chain that loads every record into memory" do
      source = <<~RUBY
        class WidgetsController < ApplicationController
          def index
            @names = Widget.active.map { |w| w.name }
          end
        end
      RUBY

      with_app_file("app/controllers/widgets_controller.rb", source) do |file, path|
        warnings = described_class.check_rails_semantics(file, path)
        expect(warnings.join).to include("may load all records into memory")
      end
    end
  end
end
