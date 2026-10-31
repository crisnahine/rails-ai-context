# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"

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

  # An app's engine views call the engine's helpers bare, and its engine
  # controllers answer routes in the engine's table.
  describe "routes an app draws into an engine" do
    let(:engine_routes) do
      [ { engine: "Shop::Core::Engine", mount: "/", routes: [
        { verb: "GET", path: "/admin/orders", controller: "shop/admin/orders", action: "index", name: "shop.admin_orders" },
        { verb: "GET", path: "/admin/orders/:id/fire", controller: "shop/admin/orders", action: "fire" }
      ] } ]
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({
        routes: { by_controller: { "posts" => [ { verb: "GET", action: "index", name: "posts" } ] }, engine_routes: engine_routes },
        controllers: { controllers: { "Shop::Admin::OrdersController" => { actions: %w[index] } } },
        schema: { tables: {} }, models: {}
      })
    end

    it "knows the engine's route helpers" do
      with_app_file("app/views/shop/admin/orders/_x.html.erb", "<%= link_to 'x', admin_orders_path %>\n") do |file, path|
        expect(described_class.check_rails_semantics(file, path).join).not_to include("admin_orders_path")
      end
    end

    it "checks an engine controller against the engine's routes" do
      with_app_file("app/controllers/shop/admin/orders_controller.rb",
                    "module Shop\n  module Admin\n    class OrdersController < BaseController\n      def index; end\n    end\n  end\nend\n") do |file, path|
        root = path.delete_suffix(file)
        File.write(File.join(root, "app/controllers/shop/admin/base_controller.rb"),
                   "module Shop\n  module Admin\n    class BaseController < ApplicationController\n    end\n  end\nend\n")
        File.write(File.join(root, "app/controllers/application_controller.rb"), "class ApplicationController < ActionController::Base\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))

        expect(described_class.check_rails_semantics(file, path).join).to include("fire - action not found")
      end
    end
  end

  # A view calls its helpers bare, and three kinds read as missing routes: a
  # helper the app writes itself, a `direct` route, and the routes Rails'
  # own engines draw (Active Storage's rails_blob_url).
  describe "a *_path or *_url call that is no route of the app's table" do
    let(:view) do
      <<~ERB
        <%= image_tag avatar_url(@user) %>
        <%= link_to "Back", back_path %>
        <%= link_to "Section", current_section_path %>
        <%= link_to "Docs", docs_url %>
        <%= link_to "Blob", rails_blob_url(@post.photo) %>
        <%= link_to "Bogus", bogus_things_path %>
      ERB
    end

    def warnings_for(app: nil, files: {})
      Dir.mktmpdir do |root|
        {
          "app/helpers/application_helper.rb" => "module ApplicationHelper\n  def avatar_url(user) = user.to_s\n  private def back_path = \"/\"\nend\n",
          "app/controllers/application_controller.rb" => "class ApplicationController < ActionController::Base\n  helper_method :current_section_path, :signed_in?\nend\n",
          "config/routes.rb" => "Rails.application.routes.draw do\n  resources :posts\n  direct(:docs) { \"https://docs.example.com\" }\nend\n",
          "app/views/posts/show.html.erb" => view
        }.merge(files).each do |relative, body|
          FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
          File.write(File.join(root, relative), body)
        end
        allow(described_class).to receive(:rails_app).and_return(app || double(root: Pathname.new(root)))
        allow(app).to receive(:root).and_return(Pathname.new(root)) if app
        allow(described_class).to receive(:cached_context).and_return({
          routes: { by_controller: { "posts" => [ { verb: "GET", action: "show", name: "post" } ] } },
          schema: { tables: {} }, models: {}
        })
        file = "app/views/posts/show.html.erb"
        return described_class.check_rails_semantics(file, File.join(root, file)).join("\n")
      end
    end

    it "passes over a helper the app writes, one a controller hands the views, and a direct route" do
      text = warnings_for

      %w[avatar_url back_path current_section_path docs_url].each { |helper| expect(text).not_to include(helper) }
      expect(text).to include("bogus_things_path - route helper not found")
    end

    it "asks the booted app's url_helpers, which hold what Rails' engines draw" do
      helpers = Module.new { def rails_blob_url(*); end }
      app = double(routes: double(url_helpers: helpers), reload_routes_unless_loaded: true)

      text = warnings_for(app: app)

      expect(text).not_to include("rails_blob_url")
      expect(text).to include("bogus_things_path - route helper not found")
    end

    it "passes over a rails_* helper statically, where Rails' engines' routes are not read" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)

      text = warnings_for

      expect(text).not_to include("rails_blob_url")
      expect(text).to include("bogus_things_path - route helper not found")
    end

    it "still flags a rails_* helper the booted app does not define" do
      app = double(routes: double(url_helpers: Module.new), reload_routes_unless_loaded: true)

      expect(warnings_for(app: app)).to include("rails_blob_url - route helper not found")
    end

    it "reads no direct route out of a heredoc or a =begin block in the routes file" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          resources :posts
          NOTE = <<~TEXT
            direct :legacy
          TEXT
        =begin
          direct :retired
        =end
        end
      RUBY
      view = %(<%= link_to "Legacy", legacy_url %>\n<%= link_to "Retired", retired_path %>\n)

      text = warnings_for(files: { "config/routes.rb" => routes, "app/views/posts/show.html.erb" => view })

      expect(text).to include("legacy_url - route helper not found").and include("retired_path - route helper not found")
    end

    it "passes over every helper a helper_method call spread over lines hands the views" do
      controller = "class ApplicationController < ActionController::Base\n  helper_method :current_section_path,\n                :next_section_path\nend\n"
      view = %(<%= link_to "Next", next_section_path %>\n<%= link_to "Bogus", bogus_things_path %>\n)

      text = warnings_for(files: { "app/controllers/application_controller.rb" => controller, "app/views/posts/show.html.erb" => view })

      expect(text).not_to include("next_section_path")
      expect(text).to include("bogus_things_path - route helper not found")
    end

    it "reads no helper method out of a heredoc or a =begin block in app/helpers" do
      helper = <<~RUBY
        module ApplicationHelper
          def avatar_url(user) = user.to_s
          USAGE = <<~TEXT
            def fake_path
          TEXT
        =begin
          def old_path
        =end
        end
      RUBY
      view = %(<%= image_tag avatar_url(@user) %>\n<%= link_to "Fake", fake_path %>\n<%= link_to "Old", old_path %>\n)

      text = warnings_for(files: { "app/helpers/application_helper.rb" => helper, "app/views/posts/show.html.erb" => view })

      expect(text).not_to include("avatar_url")
      expect(text).to include("fake_path - route helper not found").and include("old_path - route helper not found")
    end
  end

  # An ApplicationController can include Pagy::Backend, a gem module this
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
      text = check("class ApplicationController < Shop::BaseController\nend\n")

      expect(text).not_to include("action not found")
      expect(text).to include("Shop::BaseController")
    end

    # An app can route `get :merged, to: "requests#merged?"`.
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

  # A `t.replica_identity_index` call indexes root_account_id through an app
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

    # `turbo_stream_from` subscribes to a channel; broadcasts render their own
    # partials into it, and no action renders a .turbo_stream.erb for it.
    it "asks for no .turbo_stream.erb template beside a view that subscribes with turbo_stream_from" do
      with_app_file("app/views/widgets/show.html.erb", "<%= turbo_stream_from @widget %>\n<h1>Widget</h1>\n") do |file, path|
        expect(described_class.check_rails_semantics(file, path).join).not_to include("turbo_stream")
      end
    end

    context "a view naming Stimulus controllers" do
      before do
        allow(described_class).to receive(:cached_context).and_return({
          routes: { by_controller: {} }, schema: { tables: {} }, models: {},
          stimulus: { controllers: [ { name: "comment_form" } ] }
        })
      end

      def stimulus_warnings(template)
        with_app_file("app/views/widgets/show.html.erb", template) do |file, path|
          described_class.check_rails_semantics(file, path).grep(/Stimulus/)
        end
      end

      it "checks a controller a tag helper's data hash sets, as Rails renders it to data-controller" do
        template = %(<%= tag.div data: { controller: "ghost" } %>\n<%= form_with model: @widget, data: { controller: "comment-form" } do |f| %><% end %>\n)

        expect(stimulus_warnings(template)).to eq([ %(data-controller="ghost" - Stimulus controller not found) ])
      end

      it "checks the literal names of a data-controller and nothing an ERB tag in it writes or comments out" do
        template = %(<div data-controller="ghost <%= extra %>"></div>\n<%# <div data-controller="retired"></div> %>\n)

        expect(stimulus_warnings(template)).to eq([ %(data-controller="ghost" - Stimulus controller not found) ])
      end

      it "checks no controller an HTML comment holds, and still checks a tag helper's that ERB inside one runs" do
        template = %(<!-- <div data-controller="legacy-chart"></div> -->\n<!-- <%= tag.div data: { controller: "live" } %> -->\n)

        expect(stimulus_warnings(template)).to eq([ %(data-controller="live" - Stimulus controller not found) ])
      end
    end

    context "a model that broadcasts to a Turbo Stream channel" do
      def broadcast_warnings(model, views = {})
        Dir.mktmpdir do |root|
          { "app/models/article.rb" => model, "app/views/articles/index.html.erb" => "<h1>Articles</h1>\n" }.merge(views).each do |relative, body|
            FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
            File.write(File.join(root, relative), body)
          end
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
          file = "app/models/article.rb"
          return described_class.check_rails_semantics(file, File.join(root, file)).grep(/broadcast/)
        end
      end

      it "checks no broadcast a comment names" do
        model = <<~RUBY
          class Article < ApplicationRecord
            # broadcast_replace_to("old_channel") was removed
            def announce
              broadcast_replace_to("live_feed")
            end
          end
        RUBY

        expect(broadcast_warnings(model)).to eq([ %(broadcast to "live_feed" - no matching turbo_stream_from found in views) ])
      end

      it "checks no broadcast a heredoc's text holds" do
        model = <<~RUBY
          class Article < ApplicationRecord
            UPGRADE_NOTE = <<~TEXT
              broadcast_replace_to("old_channel") was removed
            TEXT

            def announce
              broadcast_replace_to("live_feed")
            end
          end
        RUBY

        expect(broadcast_warnings(model)).to eq([ %(broadcast to "live_feed" - no matching turbo_stream_from found in views) ])
      end

      it "counts no subscription an ERB comment holds" do
        model = "class Article < ApplicationRecord\n  def announce\n    broadcast_replace_to(\"live_feed\")\n    broadcast_append_to(\"side_feed\")\n  end\nend\n"
        view = %(<%# turbo_stream_from "live_feed" %>\n<%= turbo_stream_from "side_feed" %>\n)

        expect(broadcast_warnings(model, "app/views/articles/index.html.erb" => view))
          .to eq([ %(broadcast to "live_feed" - no matching turbo_stream_from found in views) ])
      end
    end

    # Read without Erubi's trim mode, `<%- if @widget -%>` was a unary minus
    # and the parse lost the render inside it.
    it "reads a template written with trim tags" do
      template = "<%- if @widget -%>\n  <%= render \"shared/nope\" -%>\n<%- end -%>\n"
      with_app_file("app/views/widgets/show.html.erb", template) do |file, path|
        expect(described_class.check_rails_semantics(file, path).join).to include("render \"shared/nope\" - partial not found")
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

      # has_secure_password keeps a digest column, and an attachment or rich
      # text lives in records of its own, so each suggested migration was a
      # column nobody wants.
      it "says nothing about what has_secure_password, an attachment or rich text declares" do
        source = <<~RUBY
          class Subscription < ApplicationRecord
            has_secure_password
            has_secure_password :recovery_password, validations: false
            has_one_attached :avatar
            has_many_attached :documents, dependent: :purge_later
            has_rich_text :bio
            validates :password, length: { minimum: 8 }, allow_nil: true
            validates :password_confirmation, :password_challenge, presence: true
            validates :recovery_password, :recovery_password_confirmation, presence: true
            validates :avatar, :documents, :bio, presence: true
            validates :nickname, presence: true
          end
        RUBY

        with_app_file("app/models/subscription.rb", source) do |file, path|
          warnings = described_class.check_rails_semantics(file, path).join("\n")
          %w[password recovery_password avatar documents bio].each { |name| expect(warnings).not_to include("validates :#{name}") }
          expect(warnings).to include("validates :nickname - column \"nickname\" not found")
        end
      end

      # A `has_details_table do` macro class_evals its block on a detail
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

    # A sign-up form permits the password and the avatar, which the model
    # declares and no column holds.
    it "says nothing about a permitted attribute the model declares without a column" do
      Dir.mktmpdir do |root|
        files = {
          "app/models/user.rb" => "class User < ApplicationRecord\n  has_secure_password\n  has_one_attached :avatar\n  attr_accessor :invite_code\nend\n",
          "app/controllers/users_controller.rb" => <<~RUBY
            class UsersController < ApplicationController
              private

              def user_params
                params.require(:user).permit(:email, :password, :password_confirmation, :avatar, :invite_code, :nickname)
              end
            end
          RUBY
        }
        files.each do |relative, body|
          FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
          File.write(File.join(root, relative), body)
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          routes: { by_controller: {} },
          schema: { tables: { "users" => { columns: [ { name: "id" }, { name: "email" }, { name: "password_digest" } ] } } },
          models: { "User" => { table_name: "users", file: "app/models/user.rb", associations: [] } }
        })

        file = "app/controllers/users_controller.rb"
        warnings = described_class.check_rails_semantics(file, File.join(root, file)).join("\n")

        %w[password password_confirmation avatar invite_code].each { |name| expect(warnings).not_to include("permits :#{name} ") }
        expect(warnings).to include("permits :nickname - not a column in users table")
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

      it "reads no ivar out of a string in a tag" do
        text = warnings_for(%(<%= mail_to "editors@example.com" %>\n<%= "Email @support" %>\n<%= "Hi \#{@real}" %>\n))

        expect(text).not_to include("@example")
        expect(text).not_to include("@support")
        expect(text).to include("@real used in view but not set in WidgetsController")
      end

      it "counts no comparison in the controller as setting the ivar" do
        File.write(File.join(@root, "app/controllers/widgets_controller.rb"), <<~RUBY)
          class WidgetsController < ApplicationController
            def show
              head :gone if @widget == :retired
              redirect_to root_path unless @draft_notice != nil
              @title = "Widget"
            end
          end
        RUBY

        text = warnings_for("<%= @widget %> <%= @draft_notice %> <%= @title %>\n")

        expect(text).to include("@widget used in view but not set").and include("@draft_notice used in view but not set")
        expect(text).not_to include("@title")
      end

      # Only app/views/layouts/ holds the app's layouts; admin/layouts/ is a LayoutsController's views.
      it "checks the views of a controller named layouts, and still skips the layouts folder" do
        FileUtils.mkdir_p(File.join(@root, "app/controllers/admin"))
        File.write(File.join(@root, "app/controllers/admin/layouts_controller.rb"),
                   "module Admin\n  class LayoutsController < ApplicationController\n    def index\n    end\n  end\nend\n")
        controllers = { "Admin::LayoutsController" => { file: "app/controllers/admin/layouts_controller.rb" } }
        allow(described_class).to receive(:cached_context).and_return({ routes: { by_controller: {} }, schema: { tables: {} },
                                                                         models: {}, controllers: { controllers: controllers } })
        found = %w[app/views/admin/layouts/index.html.erb app/views/layouts/index.html.erb].map do |file|
          FileUtils.mkdir_p(File.dirname(File.join(@root, file)))
          File.write(File.join(@root, file), "<%= @ghost %>\n")
          described_class.check_rails_semantics(file, File.join(@root, file)).join("\n")
        end

        expect(found[0]).to include("@ghost used in view but not set in Admin::LayoutsController")
        expect(found[1]).not_to include("@ghost")
      end

      # A before_action in ApplicationController, or in a concern it
      # includes, sets the ivar for every action below it.
      it "says nothing about an ivar an ancestor or an included concern sets" do
        FileUtils.mkdir_p(File.join(@root, "app/controllers/concerns"))
        File.write(File.join(@root, "app/controllers/application_controller.rb"), <<~RUBY)
          class ApplicationController < ActionController::Base
            include CurrentCart
            before_action :set_announcement

            private

            def set_announcement
              @announcement = "Sale today"
            end
          end
        RUBY
        File.write(File.join(@root, "app/controllers/concerns/current_cart.rb"), <<~RUBY)
          module CurrentCart
            extend ActiveSupport::Concern

            included { before_action :set_cart }

            def set_cart
              @cart = []
            end
          end
        RUBY

        text = warnings_for("<%= @announcement %> <%= @cart.size %> <%= @ghost %>\n")

        expect(text).not_to include("@announcement")
        expect(text).not_to include("@cart")
        expect(text).to include("@ghost used in view but not set in WidgetsController, its ancestors or the modules they include")
      end
    end

    context "a controller the performance check found loading Model.all" do
      let(:source) { "class PostsController < ApplicationController\n  def index\n    @posts = Post.all\n  end\nend\n" }

      before do
        allow(described_class).to receive(:cached_context).and_return({
          routes: { by_controller: {} },
          schema: { tables: {} },
          models: {},
          performance: { model_all_in_controllers: [
            { controller: "app/controllers/posts_controller.rb", model: "Post", suggestion: "Post.all loads all records into memory." }
          ] }
        })
      end

      it "warns on that controller's file" do
        with_app_file("app/controllers/posts_controller.rb", source) do |file, path|
          expect(described_class.check_rails_semantics(file, path)).to include("Post.all loaded in controller - consider pagination or scoping")
        end
      end

      it "leaves a namespaced controller of the same base name alone" do
        with_app_file("app/controllers/admin/posts_controller.rb", source.sub("PostsController", "Admin::PostsController")) do |file, path|
          expect(described_class.check_rails_semantics(file, path).join).not_to include("Post.all loaded")
        end
      end
    end

    context "a model whose methods live in the classes it inherits from" do
      around do |example|
        Dir.mktmpdir do |root|
          @root = root
          {
            "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\n\n  private\n\n  def assign_uuid\n    self.uuid ||= SecureRandom.uuid\n  end\nend\n",
            "app/models/vehicle.rb" => "class Vehicle < ApplicationRecord\n  def normalize_name\n    self.name = name.strip\n  end\nend\n",
            "app/models/car.rb" => "class Car < Vehicle\n  before_save :normalize_name\n  before_create :assign_uuid\n  before_update :touch_up\n" \
                                   "  validates :display_name, length: { maximum: 50 }\n\n  private\n\n  def display_name\n    \"\#{name} car\"\n  end\nend\n",
            "app/models/import.rb" => "class Import < Vendor::Record\n  before_save :checksum\nend\n"
          }.each do |path, body|
            FileUtils.mkdir_p(File.dirname(File.join(root, path)))
            File.write(File.join(root, path), body)
          end
          example.run
        end
      end

      before do
        allow(RailsAiContext).to receive(:static_tier?).and_return(true)
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(@root))
        allow(described_class).to receive(:cached_context).and_return({
          routes: { by_controller: {} },
          schema: { tables: { "vehicles" => { columns: [ { name: "id" }, { name: "name" }, { name: "type" }, { name: "uuid" } ] },
                              "imports" => { columns: [ { name: "id" } ] } } },
          models: {
            "Vehicle" => { file: "app/models/vehicle.rb", table_name: "vehicles", concerns: [], instance_methods: [ "normalize_name" ], instance_method_count: 1 },
            "Car" => { file: "app/models/car.rb", table_name: "vehicles", concerns: [], instance_methods: [], instance_method_count: 0, parent_model: "Vehicle" },
            "Import" => { file: "app/models/import.rb", table_name: "imports", concerns: [], instance_methods: [], instance_method_count: 0 }
          }
        })
      end

      def warnings_for(file)
        described_class.check_rails_semantics(file, File.join(@root, file))
      end

      it "asks for no column for a validated attribute the model defines as a method" do
        expect(warnings_for("app/models/car.rb").join("\n")).not_to include("display_name")
      end

      it "finds a callback method a parent class defines, and still flags one no class in the chain does" do
        expect(warnings_for("app/models/car.rb")).to eq([ "before_update :touch_up - method not found in Car" ])
      end

      it "reads a def only from code, not from a comment that names one" do
        File.write(File.join(@root, "app/models/vehicle.rb"), "class Vehicle < ApplicationRecord\n  # def touch_up was folded into normalize_name\n  def normalize_name\n  end\nend\n")

        expect(warnings_for("app/models/car.rb")).to eq([ "before_update :touch_up - method not found in Car" ])
      end

      it "asks for no column for a validated method when the file is read without its tree" do
        allow(described_class).to receive(:parse_and_visit).and_return(nil)
        File.write(File.join(@root, "app/models/car.rb"), "class Car < Vehicle\n  validates :display_name, presence: true\n\n  def display_name\n    name\n  end\nend\n")

        expect(warnings_for("app/models/car.rb").join("\n")).not_to include("display_name")
      end

      it "makes no claim on the static tier when the chain reaches a class it cannot read" do
        expect(warnings_for("app/models/import.rb")).to eq([])
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
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(Rails.root.to_s))

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

    it "flags no chain a heredoc's text holds" do
      source = <<~RUBY
        class WidgetsController < ApplicationController
          def index
            @report = <<~SQL
              SELECT name FROM widgets
              .users.map { }
            SQL
          end
        end
      RUBY

      with_app_file("app/controllers/widgets_controller.rb", source) do |file, path|
        expect(described_class.check_rails_semantics(file, path).join).not_to include("may load all records")
      end
    end

    it "flags an association chain off a record or a helper call" do
      source = <<~RUBY
        class ArticlesController < ApplicationController
          def index
            @titles = current_user.articles.map { |a| a.title }
            @by_id = @article.comments.each_with_object({}) { |c, h| h[c.id] = c }
          end
        end
      RUBY

      with_app_file("app/controllers/articles_controller.rb", source) do |file, path|
        expect(described_class.check_rails_semantics(file, path).grep(/may load all records/).map { |w| w[/\Aline \d+/] })
          .to eq([ "line 3", "line 4" ])
      end
    end

    it "flags a scope chain, not one over params or a string" do
      source = <<~RUBY
        class WidgetsController < ApplicationController
          def index
            @keys = params.keys.map { |k| k.to_s }
            @tags = params[:tags].to_s.split.map(&:strip)
            @names = Admin::Widget.active.map(&:name)
          end
        end
      RUBY

      with_app_file("app/controllers/widgets_controller.rb", source) do |file, path|
        expect(described_class.check_rails_semantics(file, path).grep(/may load all records/))
          .to eq([ "line 5: scope chain followed by .map may load all records into memory - consider .pluck or SQL" ])
      end
    end

    it "flags an enumerable call off a call that takes no arguments, with a block or without one" do
      source = <<~RUBY
        class ImportsController < ApplicationController
          def create
            rows = JSON.parse(request.body.read).map { |row| row["id"] }
            files = Dir.glob("tmp/*.csv").map { |path| File.basename(path) }
            lines = File.readlines(path).map { |line| line.strip }
            keys = data.fetch(:k).map { |k| k.to_s }
            found = connection.select_all(sql).map { |row| row["id"] }
            columns = Article.published.select(:id, :title)
            total = Article.all.reduce(:+)
          end
        end
      RUBY

      with_app_file("app/controllers/imports_controller.rb", source) do |file, path|
        expect(described_class.check_rails_semantics(file, path).grep(/may load all records/))
          .to eq([ "line 9: scope chain followed by .reduce may load all records into memory - consider .pluck or SQL" ])
      end
    end
  end

  # On an app with web-console, brakeman's forked parse workers died
  # marshalling the Binding bindex hangs on a parse error, and the whole scan
  # rescued to no findings. A DEBUG=1 run printed some 440 lines of rescued
  # exceptions, since brakeman's parser turns $DEBUG on when it sees DEBUG.
  describe "the brakeman scan" do
    let(:seen) { {} }

    before do
      allow(described_class).to receive(:brakeman_available?).and_return(true)
      stub_const("Brakeman", Class.new { def self.run(_options); end })
      allow(Brakeman).to receive(:run) do |options|
        seen[:options] = options
        seen[:debug] = ENV.fetch("DEBUG", nil)
        Struct.new(:filtered_warnings).new([])
      end
    end

    around do |example|
      saved = ENV.fetch("DEBUG", nil)
      ENV["DEBUG"] = "1"
      example.run
    ensure
      saved ? ENV["DEBUG"] = saved : ENV.delete("DEBUG")
    end

    it "parses in this process, with DEBUG out of brakeman's sight" do
      described_class.check_brakeman_security([ "app/models/post.rb" ])

      expect(seen[:options]).to include(parallel_checks: false)
      expect(seen[:debug]).to be_nil
      expect(ENV.fetch("DEBUG", nil)).to eq("1")
    end

    # Brakeman reads a folder entry only with a trailing slash, and one with
    # a leading slash from the app root rather than as any path's suffix.
    it "parses only the files it was given, a folder as a folder" do
      described_class.check_brakeman_security([ "././app/models/post.rb", "app/models", "/app/controllers/" ])

      expect(seen[:options][:only_files]).to eq([ "/app/models/post.rb", "/app/models/", "/app/controllers/" ])
    end

    it "reports the first five warnings of the best confidence in brakeman's order" do
      warning = Struct.new(:warning_type, :confidence, :confidence_name, :file, :line, :message, keyword_init: true)
      file = Struct.new(:relative)
      warnings = (1..24).map do |i|
        confidence = (i % 3 == 1) ? 1 : 0
        warning.new(warning_type: "Remote Code Execution", confidence: confidence, confidence_name: %w[High Medium][confidence],
                    file: file.new("app/models/m#{i % 3}.rb"), line: i, message: format("rce %02d", i))
      end
      allow(Brakeman).to receive(:run).and_return(Struct.new(:filtered_warnings).new(warnings))

      found = described_class.check_brakeman_security([ "app/models" ])
      expect(found.values.flatten.map { |line| line[/rce \d\d/] }).to eq([ "rce 02", "rce 03", "rce 05", "rce 06", "rce 08" ])
    end

    it "files a warning under the entry that names its file, however the path is written" do
      warning = Struct.new(:warning_type, :confidence, :confidence_name, :file, :line, :message, keyword_init: true)
      file = Struct.new(:relative)
      warnings = %w[app/controllers/admin_controller.rb app/controllers/admin/posts_controller.rb].map do |path|
        warning.new(warning_type: "SQL Injection", confidence: 0, confidence_name: "High",
                    file: file.new(path), line: 3, message: "Possible SQL injection")
      end
      allow(Brakeman).to receive(:run).and_return(Struct.new(:filtered_warnings).new(warnings))

      found = described_class.check_brakeman_security([ "app/controllers/admin", "././app/controllers/admin_controller.rb" ])
      expect(found.transform_values(&:size)).to eq("app/controllers/admin" => 1, "././app/controllers/admin_controller.rb" => 1)
    end
  end

  # Brakeman is not in the test bundle, so this runs the one on the machine in a child outside it.
  describe "the brakeman scan of one controller, run for real" do
    # The child reads this gem's own dependencies from the bundle, which CI keeps apart from the
    # machine's gems; the trailing separator keeps RubyGems' default dirs, where brakeman is, behind it.
    let(:child_env) do
      { "GEM_PATH" => [ Bundler.bundle_path.to_s, Bundler.original_env["GEM_PATH"], "" ].compact.join(File::PATH_SEPARATOR) }
    end
    let(:brakeman_on_machine) do
      env = child_env
      Bundler.with_unbundled_env { system(env, RbConfig.ruby, "-e", 'require "brakeman"', err: File::NULL) }
    end

    it "rates its SQL injection as a whole-app scan does" do
      skip "brakeman is not installed on this machine" unless brakeman_on_machine

      Dir.mktmpdir do |dir|
        { "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  self.abstract_class = true\nend\n",
          "app/models/post.rb" => "class Post < ApplicationRecord\nend\n",
          "app/controllers/application_controller.rb" => "class ApplicationController < ActionController::Base\nend\n",
          "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n  def index\n    @posts = Post.where(\"title = '\#{params[:q]}'\")\n  end\nend\n",
          "config/application.rb" => "module Shop\n  class Application < Rails::Application\n  end\nend\n" }.each do |path, body|
          FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
          File.write(File.join(dir, path), body)
        end
        script = [
          "$LOAD_PATH.unshift #{File.expand_path('../../../../lib', __dir__).inspect}",
          'require "rails_ai_context"',
          "RailsAiContext.tier = :static",
          "RailsAiContext.configuration.app_root = #{dir.inspect}",
          'require "brakeman"',
          "full = Brakeman.run(app_path: #{dir.inspect}, quiet: true, report_progress: false, print_report: false)",
          'puts "whole app: [#{full.filtered_warnings.find { |w| w.warning_type == "SQL Injection" }&.confidence_name}]"',
          'puts RailsAiContext::Tools::ValidateSemantics.check_brakeman_security([ "app/controllers/posts_controller.rb" ]).values.flatten'
        ].join("\n")

        env = child_env
        output, = Bundler.with_unbundled_env { Open3.capture2e(env, RbConfig.ruby, "-e", script) }

        whole_app = output[/^whole app: (\[\w+\])$/, 1]
        expect(whole_app).not_to be_nil, output
        expect(output).to include("#{whole_app} SQL Injection - app/controllers/posts_controller.rb:3")
      end
    end
  end

  # ActionView looks a bare partial name up under the controller's prefixes
  # (its own folder, then application), never shared/, with any handler.
  describe "a partial a view renders" do
    def partial_warnings(views, file = "app/views/posts/edit.html.erb")
      Dir.mktmpdir do |root|
        views.each do |relative, content|
          full = File.join(root, "app", "views", relative)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        return described_class.check_rails_semantics(file, File.join(root, file)).select { |w| w.include?("render") }
      end
    end

    it "is found in any template handler, and under application/" do
      warnings = partial_warnings(
        "posts/_card.html.haml" => "%p card\n",
        "application/_flash.html.slim" => "p flash\n",
        "posts/_row.html.erb" => "row\n",
        "posts/edit.html.erb" => %(<%= render "card" %>\n<%= render "flash" %>\n<%= render(partial: "posts/row") %>\n)
      )

      expect(warnings).to eq([])
    end

    context "when the controller's prefixes are known" do
      def controllers_context
        entry = ->(file, parent) { { file: file, parent_class: parent, actions: [] } }
        { controllers: { controllers: {
          "ApplicationController" => entry.call("app/controllers/application_controller.rb", "ActionController::Base"),
          "PostsController" => entry.call("app/controllers/posts_controller.rb", "ApplicationController"),
          "Admin::PostsController" => entry.call("app/controllers/admin/posts_controller.rb", "PostsController")
        } } }
      end

      before { allow(described_class).to receive(:cached_context).and_return(controllers_context) }

      it "finds a partial in a parent controller's folder, as Rails' lookup prefixes do" do
        warnings = partial_warnings({
          "posts/_form.html.erb" => "form\n",
          "admin/posts/edit.html.erb" => %(<%= render "form" %>\n)
        }, "app/views/admin/posts/edit.html.erb")

        expect(warnings).to eq([])
      end

      it "does not look in the view's folder for a layout, which has no controller of its own" do
        warnings = partial_warnings({
          "layouts/_header.html.erb" => "header\n",
          "layouts/application.html.erb" => %(<%= render "header" %>\n)
        }, "app/views/layouts/application.html.erb")

        expect(warnings).to eq([ %(render "header" - partial not found (checked: application/_header)) ])
      end
    end

    it "is not found under shared/ by a bare name" do
      warnings = partial_warnings(
        "shared/_nav.html.erb" => "nav\n",
        "posts/edit.html.erb" => %(<%= render "nav" %>\n<%= render "shared/nav" %>\n)
      )

      expect(warnings).to eq([ %(render "nav" - partial not found (checked: posts/_nav)) ])
    end

    it "is read from the template's text when its Ruby does not parse, skipping a JavaScript render" do
      allow(RailsAiContext::AstCache).to receive(:parse_string).and_raise(RuntimeError, "prism exploded")
      warnings = partial_warnings(
        "posts/_card.html.haml" => "%p card\n",
        "posts/edit.html.erb" => %(<%= render "card" %>\n<%= render partial: "gone" %>\n<%= render "rows/\#{@kind}" %>\n<script>turnstile.render "#box"</script>\n)
      )

      expect(warnings).to eq([ %(render "gone" - partial not found (checked: posts/_gone)) ])
    end

    it "is checked for a partial layout and a spacer, never a template's layout, in the AST and the text read" do
      views = {
        "posts/_row.html.erb" => "row\n",
        "layouts/admin.html.erb" => "<%= yield %>\n",
        "posts/edit.html.erb" => <<~ERB
          <%= render partial: "posts/row", layout: "posts/frame", collection: @posts, spacer_template: "posts/spacer" %>
          <%= render layout: "posts/box" do %>body<% end %>
          <%= render template: "posts/row", layout: "admin" %>
          <%= render "posts/row", layout: "posts/local" %>
          <%= render "posts/row", layout: "posts/local" do %>body<% end %>
          <%= render(partial: "posts/unread", layout: "posts/wrap") do %>body<% end %>
          <%= render template: "posts/unread", layout: "posts/tpl" do %>body<% end %>
          <%= render(layout: "posts/pbox") { "body" } %>
          <%= render layout: "posts/lone" %>
          <%= render partial: @row, layout: "posts/rowframe" %>
          <%= render @posts, partial: "posts/rlocal" %>
          <%= render(layout: "posts/blkpass", &blk) %>
          <%= render layout: "posts/blkbare", &blk %>
          <%= render({ layout: "posts/braceblk" }) do %>body<% end %>
          <%= render({ partial: "posts/bracep", layout: "posts/bracel", spacer_template: "posts/braces", collection: @posts }) %>
          <%= render({ template: "posts/row", layout: "posts/bracetpl" }) %>
        ERB
      }
      expected = [
        %(render "posts/frame" - partial not found (checked: posts/_frame)),
        %(render "posts/spacer" - partial not found (checked: posts/_spacer)),
        %(render "posts/box" - partial not found (checked: posts/_box)),
        %(render "posts/wrap" - partial not found (checked: posts/_wrap)),
        %(render "posts/tpl" - partial not found (checked: posts/_tpl)),
        %(render "posts/pbox" - partial not found (checked: posts/_pbox)),
        %(render "posts/rowframe" - partial not found (checked: posts/_rowframe)),
        %(render "posts/blkpass" - partial not found (checked: posts/_blkpass)),
        %(render "posts/blkbare" - partial not found (checked: posts/_blkbare)),
        %(render "posts/braceblk" - partial not found (checked: posts/_braceblk)),
        %(render "posts/bracep" - partial not found (checked: posts/_bracep)),
        %(render "posts/bracel" - partial not found (checked: posts/_bracel)),
        %(render "posts/braces" - partial not found (checked: posts/_braces))
      ]

      expect(partial_warnings(views)).to match_array(expected)
      allow(RailsAiContext::AstCache).to receive(:parse_string).and_raise(RuntimeError, "prism exploded")
      expect(partial_warnings(views)).to match_array(expected)
    end

    it "is a template in any handler where a controller renders a path by name" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app", "views", "posts"))
        File.write(File.join(root, "app", "views", "posts", "feed.html.haml"), "%p feed\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        file = "app/controllers/posts_controller.rb"
        FileUtils.mkdir_p(File.join(root, "app", "controllers"))
        File.write(File.join(root, file), <<~RUBY)
          class PostsController < ApplicationController
            def index
              render "posts/feed"
            end

            def show
              render partial: "posts/gone"
            end
          end
        RUBY

        warnings = described_class.check_rails_semantics(file, File.join(root, file)).select { |w| w.include?("render") }

        expect(warnings).to eq([ %(render "posts/gone" - partial not found (checked: posts/_gone)) ])
      end
    end
  end

  describe "the strong params a controller permits" do
    def strong_params_warnings(body)
      Dir.mktmpdir do |root|
        file = "app/controllers/posts_controller.rb"
        FileUtils.mkdir_p(File.join(root, "app", "controllers"))
        File.write(File.join(root, file), "class PostsController < ApplicationController\n#{body}end\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({
          routes: { by_controller: {} },
          schema: { tables: { "posts" => { columns: [ { name: "id" }, { name: "title" } ] } } },
          models: { "Post" => { table_name: "posts", associations: [] } }
        })
        return described_class.check_rails_semantics(file, File.join(root, file)).select { |w| w.include?("permits") }
      end
    end

    # Query-string filters belong to no model.
    it "checks no bare permit against the controller's model" do
      expect(strong_params_warnings("  def index\n    @filters = params.permit(:page, :sort, :q)\n  end\n")).to eq([])
    end

    it "checks the keys permitted after params.fetch, with or without a default" do
      with_default = strong_params_warnings("  def post_params\n    params.fetch(:post, {}).permit(:title, :bogus_col)\n  end\n")
      without = strong_params_warnings("  def post_params\n    params.fetch(:post).permit(:title, :other_col)\n  end\n")

      expect(with_default).to eq([ "permits :bogus_col - not a column in posts table (check virtual attributes or add migration)" ])
      expect(without).to eq([ "permits :other_col - not a column in posts table (check virtual attributes or add migration)" ])
    end

    it "checks the keys Rails 8's params.expect permits" do
      warnings = strong_params_warnings("  def post_params\n    params.expect(post: [ :title, :bogus_col ])\n  end\n")

      expect(warnings).to eq([ "permits :bogus_col - not a column in posts table (check virtual attributes or add migration)" ])
    end
  end
end
