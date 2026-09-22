# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GenerateTest do
  # Every `is_expected.to belong_to(...)` line is a shoulda-matchers matcher,
  # so the generator only writes them for an app that bundles it.
  def bundling_shoulda
    allow(RailsAiContext::GemLock).to receive(:for)
      .and_return(RailsAiContext::GemLock::Spec.new({ "shoulda-matchers" => "6.4.0" }))
  end

  before { described_class.reset_cache! }

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call(model: "NonExistent")
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "requires at least one parameter" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Provide at least one")
      expect(result.error?).to be(true)
    end

    it "returns not-found for unknown model" do
      result = described_class.call(model: "ZzzNonexistentModel")
      text = result.content.first[:text]
      expect(text).to include("not found")
    end

    it "generates rspec-style output when framework is rspec" do
      bundling_shoulda
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factories: { count: 1 }, factory_names: {} },
        models: {
          "User" => {
            associations: [ { type: "has_many", name: "posts" } ],
            validations: [ { kind: "presence", attributes: %w[ email ] } ],
            scopes: [ { name: "active", body: "where(active: true)" } ],
            enums: {},
            callbacks: {}
          }
        }
      })

      result = described_class.call(model: "User")
      text = result.content.first[:text]
      expect(text).to include("RSpec.describe User")
      expect(text).to include("associations")
      expect(text).to include("validations")
      expect(text).to include("validate_presence_of(:email)")
      expect(text).to include("have_many(:posts)")
      expect(text).to include(".active")
    end

    # The marker is this gem's word for "a block lives here", not something
    # the user can paste into an example name.
    it "names a block callback as a block rather than by the marker" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factories: { count: 1 }, factory_names: {} },
        models: {
          "Status" => {
            associations: [], validations: [], scopes: [], enums: {},
            callbacks: {
              "around_create" => %w[Mastodon::Snowflake::Callbacks],
              "after_create" => [ "[inline_block]" ],
              "before_save" => %w[normalize]
            }
          }
        }
      })

      text = described_class.call(model: "Status").content.first[:text]

      expect(text).to include(%(it "around_create calls Mastodon::Snowflake::Callbacks" do))
      expect(text).to include(%(it "after_create runs its inline block" do))
      expect(text).to include(%(it "before_save calls :normalize" do))
      expect(text).not_to include("[inline_block]")
    end

    it "generates minitest-style output when framework is minitest" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest" },
        models: {
          "Post" => {
            associations: [ { type: "belongs_to", name: "user" } ],
            validations: [ { kind: "presence", attributes: %w[ title ] } ],
            scopes: [],
            enums: {},
            callbacks: {}
          }
        }
      })

      result = described_class.call(model: "Post")
      text = result.content.first[:text]
      expect(text).to include("class PostTest < ActiveSupport::TestCase")
      expect(text).to include("validates presence of title")
    end

    it "generates request spec for controller" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", test_helper_setup: [] },
        models: {},
        routes: {
          by_controller: {
            "posts" => [
              { verb: "GET", path: "/posts", action: "index", name: "posts" },
              { verb: "POST", path: "/posts", action: "create", name: "posts" }
            ]
          }
        }
      })

      result = described_class.call(controller: "PostsController")
      text = result.content.first[:text]
      expect(text).to include("type: :request")
      expect(text).to include("GET /posts")
      expect(text).to include("POST /posts")
    end

    it "generates minitest controller test with quoted paths and defined params for nested routes" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "likes" => [ "one" ], "posts" => [ "one" ] }
        },
        models: { "Like" => { table_name: "likes" } },
        routes: {
          by_controller: {
            "likes" => [
              { verb: "DELETE", path: "/posts/:post_id/like", action: "destroy", name: nil, params: [ "post_id" ] }
            ]
          }
        }
      })

      result = described_class.call(controller: "LikesController")
      text = result.content.first[:text]
      # Path must be a quoted string, not a regex literal
      expect(text).to include('delete "/posts/')
      expect(text).not_to match(/delete\s+\/posts/)
      # post_id variable must be defined
      expect(text).to include("post_id = posts(:one).id")
      # Destroy targets a fresh record so fixture foreign keys stay intact
      expect(text).to include('like = Like.create!(@like.attributes.except("id", "created_at", "updated_at"))')
      expect(text).to include('assert_difference("Like.count", -1)')
    end

    it "generates a scaffold-style minitest controller test from routes, fixtures, and strong params" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "articles" => [ "one", "two" ] }
        },
        models: { "Article" => { table_name: "articles" } },
        controllers: {
          controllers: {
            "ArticlesController" => {
              api_controller: false,
              respond_to_formats: [ "html", "json" ],
              strong_params: [ { name: "article_params", requires: "article", permits: [ "title", "body" ] } ]
            }
          }
        },
        routes: {
          by_controller: {
            "articles" => [
              { verb: "GET", path: "/articles", action: "index", name: "articles" },
              { verb: "POST", path: "/articles", action: "create" },
              { verb: "GET", path: "/articles/:id", action: "show", name: "article", params: [ "id" ] },
              { verb: "PATCH", path: "/articles/:id", action: "update", params: [ "id" ] },
              { verb: "PUT", path: "/articles/:id", action: "update", params: [ "id" ] },
              { verb: "DELETE", path: "/articles/:id", action: "destroy", params: [ "id" ] }
            ]
          }
        }
      })

      result = described_class.call(controller: "ArticlesController")
      text = result.content.first[:text]
      expect(text).to include("@article = articles(:one)")
      # Unnamed POST/PATCH/DELETE routes borrow the helper of the named sibling path
      expect(text).to include("post articles_url, params: { article: { body: @article.body, title: @article.title } }")
      expect(text).to include("patch article_url(@article), params: { article: { body: @article.body, title: @article.title } }")
      # Writes assert redirects, not :success, and update is tested once (PATCH wins over PUT)
      expect(text).to include("assert_response :redirect")
      expect(text.scan("should update article").size).to eq(1)
      expect(text).to include('assert_difference("Article.count")')
    end

    it "generates JSON requests with as: :json for API controllers" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "orders" => [ "one" ] }
        },
        models: { "Order" => { table_name: "orders" } },
        controllers: {
          controllers: {
            "OrdersController" => {
              api_controller: true,
              strong_params: [ { name: "order_params", requires: "order", permits: [ "number" ] } ]
            }
          }
        },
        routes: {
          by_controller: {
            "orders" => [
              { verb: "GET", path: "/orders", action: "index", name: "orders" },
              { verb: "POST", path: "/orders", action: "create" }
            ]
          }
        }
      })

      result = described_class.call(controller: "OrdersController")
      text = result.content.first[:text]
      expect(text).to include("get orders_url, as: :json")
      expect(text).to include("post orders_url, params: { order: { number: @order.number } }, as: :json")
      # API responses render, not redirect; 201/204 sit inside the :success range
      expect(text).not_to include("assert_response :redirect")
      expect(text).to include("assert_response :success")
    end

    it "emits explicit skip TODOs when fixtures or permitted attributes are missing" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "minitest", test_helper_setup: [], fixture_names: {} },
        models: { "Widget" => { table_name: "widgets" } },
        routes: {
          by_controller: {
            "widgets" => [
              { verb: "GET", path: "/widgets/:id", action: "show", name: "widget", params: [ "id" ] },
              { verb: "POST", path: "/widgets", action: "create" }
            ]
          }
        }
      })

      result = described_class.call(controller: "WidgetsController")
      text = result.content.first[:text]
      expect(text).to include('skip "TODO:')
      expect(text).not_to include("post widgets_url")
    end

    it "falls back to schema content columns when no strong params are detected" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: {
          framework: "minitest",
          test_helper_setup: [],
          fixture_names: { "articles" => [ "one" ] }
        },
        models: { "Article" => { table_name: "articles" } },
        schema: {
          tables: {
            "articles" => {
              columns: [
                { name: "id", type: "integer" },
                { name: "title", type: "string" },
                { name: "created_at", type: "datetime" },
                { name: "updated_at", type: "datetime" }
              ]
            }
          }
        },
        routes: {
          by_controller: {
            "articles" => [
              { verb: "POST", path: "/articles", action: "create", name: "articles" }
            ]
          }
        }
      })

      result = described_class.call(controller: "ArticlesController")
      text = result.content.first[:text]
      expect(text).to include("params: { article: { title: @article.title } }")
    end

    it "builds the placeholder record from the model's columns, not every permitted param" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factories: nil, factory_names: nil },
        models: { "Account" => { table_name: "accounts" } },
        schema: {
          tables: {
            "accounts" => {
              columns: [
                { name: "id", type: "integer" },
                { name: "username", type: "string" },
                { name: "note", type: "text" }
              ]
            }
          }
        },
        controllers: {
          controllers: {
            "AccountsController" => {
              strong_params: [ { name: "account_params", requires: "account", permits: %w[username email password agreement] } ]
            }
          }
        },
        routes: {
          by_controller: {
            "accounts" => [ { verb: "GET", path: "/accounts/:id", action: "show", name: "account" } ]
          }
        }
      })

      text = described_class.call(controller: "AccountsController").content.first[:text]

      expect(text).to include("Account.create!({ username: \"MyString\" })")
      expect(text).to include("agreement, email, password")
      expect(text).to include("not columns of accounts")
    end

    it "detects file type from path" do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec" },
        models: {
          "Post" => {
            associations: [],
            validations: [],
            scopes: [],
            enums: {},
            callbacks: {}
          }
        }
      })

      result = described_class.call(file: "app/models/post.rb")
      text = result.content.first[:text]
      expect(text).to include("RSpec.describe Post")
    end
  end

  describe "authentication setup for a Devise app" do
    def devise_context(framework:, tests: {}, controllers: {})
      {
        tests: {
          framework: framework,
          test_helper_setup: [ "Devise::Test::IntegrationHelpers" ]
        }.merge(tests),
        models: {},
        controllers: { controllers: controllers },
        routes: { by_controller: { "posts" => [ { verb: "GET", path: "/posts", action: "index" } ] } }
      }
    end

    def generated(context)
      allow(described_class).to receive(:cached_context).and_return(context)
      described_class.call(controller: "PostsController").content.first[:text]
    end

    it "does not call a user factory the app does not have" do
      text = generated(devise_context(framework: "rspec", tests: { factories: nil, factory_names: nil }))
      expect(text).to include("include Devise::Test::IntegrationHelpers")
      expect(text).not_to include("create(:user)")
      expect(text).not_to include("before { sign_in user }")
      expect(text).to include("# TODO: these examples run unauthenticated")
    end

    it "keeps the sign_in block when a user factory exists" do
      text = generated(devise_context(
        framework: "rspec",
        tests: { factories: { location: "spec/factories", count: 1 }, factory_names: { "users.rb" => [ :user ] } }
      ))
      expect(text).to include("let(:user) { create(:user) }")
      expect(text).to include("before { sign_in user }")
    end

    it "does not name a users fixture the app does not have" do
      text = generated(devise_context(framework: "minitest", tests: { fixtures: nil, fixture_names: nil }))
      expect(text).to include("include Devise::Test::IntegrationHelpers")
      expect(text).not_to include("users(:one)")
      expect(text).not_to include("setup do")
      expect(text).to include("# TODO: these tests run unauthenticated")
    end

    # The fixtures guide's shared-attribute idiom opens the file with
    # "DEFAULTS: &DEFAULTS", and Rails' own "_fixture:" key can be first too.
    # Neither is a fixture name.
    it "does not read a shared-attribute anchor off the fixture file as a name" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "test", "fixtures"))
        File.write(File.join(dir, "test", "fixtures", "users.yml"), <<~YAML)
          DEFAULTS: &DEFAULTS
            confirmed_at: <%= Time.current %>

          alice:
            <<: *DEFAULTS
            email: alice@example.com
        YAML
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))

        text = generated(devise_context(framework: "minitest", tests: { fixture_names: nil }))

        expect(text).not_to include("users(:DEFAULTS)")
        expect(text).to include("users(:alice)")
      end
    end

    it "does not name an anchor a cached context carries as a fixture name" do
      text = generated(devise_context(
        framework: "minitest",
        tests: { fixture_names: { "users" => [ "DEFAULTS", "alice" ] } }
      ))

      expect(text).not_to include("users(:DEFAULTS)")
      expect(text).to include("users(:alice)")
    end

    it "does not name a cached _fixture key as a fixture name" do
      text = generated(devise_context(
        framework: "minitest",
        tests: { fixture_names: { "users" => [ "_fixture", "alice" ] } }
      ))

      expect(text).not_to include("users(:_fixture)")
      expect(text).to include("users(:alice)")
    end

    it "keeps the fixture sign_in when a users fixture exists" do
      text = generated(devise_context(framework: "minitest", tests: { fixture_names: { "users" => [ "alice" ] } }))
      expect(text).to include("@user = users(:alice)")
      expect(text).to include("sign_in @user")
    end

    it "skips sign_in for a controller whose ancestry authorizes with Doorkeeper" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "app", "controllers", "api_base_controller.rb"), <<~RUBY)
          class ApiBaseController < ActionController::API
            before_action -> { doorkeeper_authorize! :read }
          end
        RUBY
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(dir))

        text = generated(devise_context(
          framework: "rspec",
          tests: { factories: { location: "spec/factories", count: 1 }, factory_names: { "users.rb" => [ :user ] } },
          controllers: {
            "PostsController" => { parent_class: "ApiBaseController", file: "app/controllers/posts_controller.rb" },
            "ApiBaseController" => { file: "app/controllers/api_base_controller.rb" }
          }
        ))

        expect(text).not_to include("sign_in")
        expect(text).to include("Doorkeeper")
      end
    end

    it "skips the fixture sign_in for a Doorkeeper controller in the minitest generator" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "app", "controllers", "api_base_controller.rb"), <<~RUBY)
          class ApiBaseController < ActionController::API
            before_action -> { doorkeeper_authorize! :read }
          end
        RUBY
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(dir))

        text = generated(devise_context(
          framework: "minitest",
          tests: { fixture_names: { "users" => [ "alice" ] } },
          controllers: {
            "PostsController" => { parent_class: "ApiBaseController", file: "app/controllers/posts_controller.rb" },
            "ApiBaseController" => { file: "app/controllers/api_base_controller.rb" }
          }
        ))

        expect(text).not_to include("sign_in")
        expect(text).not_to include("users(:alice)")
        expect(text).to include("Doorkeeper")
      end
    end
  end

  # The rspec branch matched the macro against Strings while the static walk
  # reported Symbols, so every row was dropped and the block came out empty.
  describe "a model parsed without booting" do
    it "fills the rspec associations and validations blocks" do
      bundling_shoulda
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "account.rb"), <<~RUBY)
          class Account < ApplicationRecord
            belongs_to :owner
            has_many :statuses, dependent: :destroy
            has_one :profile
            validates :username, presence: true
            validates :followers_url, absence: true
          end
        RUBY

        app = RailsAiContext::StaticApp.new(dir)
        models = RailsAiContext::Introspectors::ModelIntrospector.new(app).static_call
        allow(described_class).to receive(:cached_context)
          .and_return({ tests: { framework: "rspec" }, models: models })
        allow(described_class).to receive(:rails_app).and_return(app)

        text = described_class.call(model: "Account").content.first[:text]

        expect(text).to include("it { is_expected.to belong_to(:owner) }")
        expect(text).to include("it { is_expected.to have_many(:statuses).dependent(:destroy) }")
        expect(text).to include("it { is_expected.to have_one(:profile) }")
        expect(text).to include("it { is_expected.to validate_presence_of(:username) }")
        expect(text).to include("validates absence of followers_url")
        expect(text).not_to include(%(describe "associations" do\n  end))
      end
    end

    it "renders a habtm row rather than an empty associations block" do
      bundling_shoulda
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "account.rb"), <<~RUBY)
          class Account < ApplicationRecord
            has_and_belongs_to_many :tags
          end
        RUBY

        app = RailsAiContext::StaticApp.new(dir)
        models = RailsAiContext::Introspectors::ModelIntrospector.new(app).static_call
        allow(described_class).to receive(:cached_context)
          .and_return({ tests: { framework: "rspec" }, models: models })
        allow(described_class).to receive(:rails_app).and_return(app)

        text = described_class.call(model: "Account").content.first[:text]

        expect(text).to include("it { is_expected.to have_and_belong_to_many(:tags) }")
        expect(text).not_to include(%(describe "associations" do\n  end))
      end
    end
  end

  # Every generated one-liner is a shoulda-matchers matcher, and without the
  # gem each one fails with NoMethodError the first time the spec runs.
  describe "an app that does not bundle shoulda-matchers" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factories: { count: 1 }, factory_names: { "orders" => [ :order ] } },
        models: {
          "Order" => {
            associations: [ { type: "belongs_to", name: "account" } ],
            validations: [ { kind: "presence", attributes: %w[number] } ],
            enums: { "status" => { "draft" => 0, "sent" => 1 } },
            scopes: [], callbacks: {}
          }
        }
      })
    end

    it "writes examples that need no matcher gem" do
      text = described_class.call(model: "Order").content.first[:text]

      expect(text).not_to include("belong_to(")
      expect(text).not_to include("validate_presence_of(")
      expect(text).to include("reflect_on_association(:account).macro).to eq(:belongs_to)")
      expect(text).to include("validators_on(:number)")
      expect(text).to include("defined_enums")
    end
  end

  describe "an inclusion validation" do
    def generated_for(options)
      bundling_shoulda
      allow(described_class).to receive(:cached_context).and_return({
        tests: { framework: "rspec", factory_names: {} },
        models: { "Order" => { validations: [ { kind: "inclusion", attributes: %w[status], options: options } ] } }
      })
      described_class.call(model: "Order").content.first[:text]
    end

    it "passes an Array literal to in_array, not a quoted String" do
      expect(generated_for({ in: %w[draft sent paid] }))
        .to include(%(in_array(["draft", "sent", "paid"])))
    end

    it "passes a constant as code" do
      expect(generated_for({ in: "Orders::Constants::STATUSES" }))
        .to include("in_array(Orders::Constants::STATUSES)")
    end

    it "carries allow_nil through" do
      expect(generated_for({ in: [ 0, 7 ], allow_nil: true })).to include("in_array([0, 7]).allow_nil")
    end
  end

  describe "a namespaced controller" do
    let(:context) do
      {
        tests: { framework: "rspec", test_helper_setup: [], factories: { count: 1 },
                 factory_names: { "orders" => [ :order ] } },
        models: { "Order" => { table_name: "orders" } },
        controllers: { controllers: { "Api::V1::Admin::OrdersController" => { actions: %w[edit] } } },
        routes: {
          by_controller: {
            "api/v1/admin/orders" => [
              { verb: "POST", path: "/api/v1/admin/orders/edit", action: "edit", name: "api_v1_admin_orders_edit" }
            ]
          }
        }
      }
    end

    before { allow(described_class).to receive(:cached_context).and_return(context) }

    it "names the factory after the model, not after the route key" do
      text = described_class.call(controller: "Api::V1::Admin::OrdersController").content.first[:text]

      expect(text).to include("create(:order)")
      expect(text).not_to include("create(:api/v1/admin/order)")
    end

    it "sends the verb the route declares" do
      text = described_class.call(controller: "Api::V1::Admin::OrdersController").content.first[:text]

      expect(text).to include("post api_v1_admin_orders_edit")
      expect(text).not_to include("get api_v1_admin_orders_edit")
    end

    it "says a controller the app does not have is not there" do
      text = described_class.call(controller: "Api::V1::OrdersController").content.first[:text]

      expect(text).to include("not found")
      expect(text).to include("Api::V1::Admin::OrdersController")
    end
  end

  describe "the short name of a namespaced controller" do
    let(:context) do
      {
        tests: { framework: "rspec", test_helper_setup: [], factories: { count: 1 },
                 factory_names: { "gift_cards" => [ :gift_card ] } },
        models: { "GiftCard" => { table_name: "gift_cards" } },
        controllers: { controllers: { "Admin::GiftCardsController" => { actions: %w[index] } } },
        routes: {
          by_controller: {
            "admin/gift_cards" => [
              { verb: "GET", path: "/admin/gift_cards", action: "index", name: "admin_gift_cards" }
            ]
          }
        }
      }
    end

    before { allow(described_class).to receive(:cached_context).and_return(context) }

    it "resolves every form the routes already answer to" do
      %w[gift_cards gift-cards admin::gift_cards admin/gift_cards].each do |name|
        text = described_class.call(controller: name).content.first[:text]

        expect(text).not_to include("not found"), "expected #{name.inspect} to resolve"
        expect(text).to include("spec/requests/admin/gift_cards_spec.rb")
      end
    end

    # Two surfaces, one rule: a name rails_get_controllers resolves is a name
    # this tool generates for.
    it "resolves a short name the way rails_get_controllers does" do
      allow(RailsAiContext::Tools::GetControllers).to receive(:cached_context).and_return(context)

      listed = RailsAiContext::Tools::GetControllers.call(controller: "gift_cards").content.first[:text]
      generated = described_class.call(controller: "gift_cards").content.first[:text]

      expect(listed).to include("Admin::GiftCardsController")
      expect(generated).not_to include("not found")
    end
  end

  # The declaration is the answer for a model too, and the branch handed it a
  # basename, which carries no namespace to match against.
  describe "a namespaced model whose constant an inflection renames" do
    it "names the constant the file declares" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "ai_reports"))
        File.write(File.join(dir, "app", "models", "ai_reports", "build.rb"), <<~RUBY)
          class AIReports::Build < ApplicationRecord
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return(
          tests: { framework: "rspec" },
          models: { "AIReports::Build" => { table_name: "ai_reports_builds", associations: [], validations: [] } }
        )

        text = described_class.call(file: "app/models/ai_reports/build.rb").content.first[:text]

        expect(text).to include("AIReports::Build")
        expect(text).not_to include("AiReports::Build")
      end
    end
  end

  describe "an ActiveInteraction service" do
    # The app registers `inflect.acronym "AI"`, so the constant the file
    # declares is AIReports::Build and the path camelizes to AiReports::Build,
    # which is a constant nothing defines. The static tier never loads the
    # app's inflections, so only the declaration answers.
    it "names the constant the file declares, not the one its path camelizes to" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "services", "ai_reports"))
        File.write(File.join(dir, "app", "services", "ai_reports", "build.rb"), <<~RUBY)
          class AIReports::Build < ActiveInteraction::Base
            def execute; end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: "rspec" } })

        text = described_class.call(file: "app/services/ai_reports/build.rb").content.first[:text]

        expect(text).to include("RSpec.describe AIReports::Build do")
        expect(text).not_to include("AiReports::Build")
      end
    end

    # A filter declared inside a `hash :x do ... end` block is a key of that
    # hash, not an input of the interaction: `.filters.keys` is [:order_params,
    # :account], and run() drops the other two silently.
    it "passes only the interaction's own filters to run" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "services", "orders"))
        File.write(File.join(dir, "app", "services", "orders", "create_with_params.rb"), <<~RUBY)
          class Orders::CreateWithParams < ActiveInteraction::Base
            hash :order_params do
              string :title, default: nil
              integer :quantity, default: nil
            end

            object :account

            def execute; end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: "rspec" } })

        text = described_class.call(file: "app/services/orders/create_with_params.rb").content.first[:text]

        expect(text).to include("described_class.run(order_params: nil, account: nil)")
        expect(text).not_to include("title: nil")
        expect(text).not_to include("quantity: nil")
      end
    end

    # ActiveInteraction::Base defines .run and .run!, never .call, so a
    # subclass of a subclass still runs the same way.
    it "follows the superclass chain through the app's own services" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "services", "billing", "invoices"))
        File.write(File.join(dir, "app", "services", "billing", "invoices", "base_request.rb"), <<~RUBY)
          class Billing::Invoices::BaseRequest < ActiveInteraction::Base
            string :token

            def execute; end
          end
        RUBY
        File.write(File.join(dir, "app", "services", "billing", "invoices", "charge.rb"), <<~RUBY)
          class Billing::Invoices::Charge < Billing::Invoices::BaseRequest
            hash :body do
              integer :amount, default: nil
            end

            def execute; end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: "rspec" } })

        text = described_class.call(file: "app/services/billing/invoices/charge.rb").content.first[:text]

        expect(text).to include("describe \".run\"")
        expect(text).to include("described_class.run(token: nil, body: nil)")
        expect(text).not_to include("described_class.call")
      end
    end

    it "runs it the way the base class does" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "services", "orders"))
        File.write(File.join(dir, "app", "services", "orders", "auto_approve.rb"), <<~RUBY)
          class Orders::AutoApprove < ActiveInteraction::Base
            object :order
            string :reason, default: nil

            def execute; end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({ tests: { framework: "rspec" } })

        text = described_class.call(file: "app/services/orders/auto_approve.rb").content.first[:text]

        expect(text).to include("describe \".run\"")
        expect(text).to include("described_class.run(order: nil, reason: nil)")
        expect(text).not_to include("described_class.call")
      end
    end
  end

  # The generated setup line follows the app's own specs: an app that assigns
  # instance variables gets no let, and the factory call follows whichever of
  # create and build its specs reach for more.
  describe "setup style read from the app's own specs" do
    def generated_for(existing_spec)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec", "models"))
        File.write(File.join(dir, "spec", "models", "post_spec.rb"), existing_spec)
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:cached_context).and_return({
          tests: { framework: "rspec", factory_names: { "spec/factories/posts.rb" => [ :post ] } },
          models: { "Post" => { associations: [], validations: [], scopes: [], enums: {}, callbacks: {} } }
        })

        described_class.call(model: "Post").content.first[:text]
      end
    end

    it "writes a let when the app's specs use let" do
      text = generated_for("let(:a) { create(:post) }\nlet(:b) { create(:post) }\n")

      expect(text).to include("let(:post) { create(:post) }")
    end

    it "writes no let for an app that assigns instance variables" do
      text = generated_for("@a = create(:post)\n@b = create(:post)\n@c = create(:post)\n")

      expect(text).not_to include("let(:post)")
    end

    it "follows the app to build when its specs build more than they create" do
      text = generated_for("let(:a) { build(:post) }\nlet(:b) { build(:post) }\n")

      expect(text).to include("let(:post) { build(:post) }")
    end
  end
end
