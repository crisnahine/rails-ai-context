# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::AnalyzeFeature do
  before { described_class.reset_cache! }

  let(:mock_context) do
    {
      models: {
        "User" => {
          table_name: "users",
          associations: [
            { type: "has_many", name: "posts" },
            { type: "has_one", name: "profile" }
          ],
          validations: [
            { kind: "presence", attributes: %w[email] },
            { kind: "uniqueness", attributes: %w[email] }
          ],
          scopes: %w[active admins]
        },
        "UserSession" => {
          table_name: "user_sessions",
          associations: [ { type: "belongs_to", name: "user" } ],
          validations: [],
          scopes: []
        },
        "Post" => {
          table_name: "posts",
          associations: [ { type: "belongs_to", name: "user" } ],
          validations: [ { kind: "presence", attributes: %w[title] } ],
          scopes: %w[published]
        }
      },
      schema: {
        adapter: "postgresql",
        tables: {
          "users" => {
            columns: [
              { name: "id", type: "bigint" },
              { name: "email", type: "string" },
              { name: "name", type: "string" },
              { name: "created_at", type: "datetime" },
              { name: "updated_at", type: "datetime" }
            ],
            indexes: [ { name: "idx_users_email", columns: [ "email" ], unique: true } ],
            foreign_keys: []
          },
          "user_sessions" => {
            columns: [
              { name: "id", type: "bigint" },
              { name: "user_id", type: "bigint" },
              { name: "token", type: "string" },
              { name: "created_at", type: "datetime" },
              { name: "updated_at", type: "datetime" }
            ],
            indexes: [],
            foreign_keys: [ { column: "user_id", to_table: "users", primary_key: "id" } ]
          },
          "posts" => {
            columns: [
              { name: "id", type: "bigint" },
              { name: "title", type: "string" },
              { name: "user_id", type: "bigint" },
              { name: "created_at", type: "datetime" },
              { name: "updated_at", type: "datetime" }
            ],
            indexes: [],
            foreign_keys: [ { column: "user_id", to_table: "users", primary_key: "id" } ]
          }
        }
      },
      controllers: {
        controllers: {
          "UsersController" => {
            actions: %w[index show create],
            filters: [ { kind: "before_action", name: "authenticate!" } ],
            parent_class: "ApplicationController"
          },
          "UserSessionsController" => {
            actions: %w[new create destroy],
            filters: [],
            parent_class: "ApplicationController"
          },
          "PostsController" => {
            actions: %w[index show new create edit update destroy],
            filters: [ { kind: "before_action", name: "set_post", only: %w[show edit update destroy] } ],
            parent_class: "ApplicationController"
          }
        }
      },
      routes: {
        by_controller: {
          "users" => [
            { verb: "GET", path: "/users", action: "index", name: "users" },
            { verb: "GET", path: "/users/:id", action: "show", name: "user" },
            { verb: "POST", path: "/users", action: "create", name: nil }
          ],
          "user_sessions" => [
            { verb: "GET", path: "/login", action: "new", name: "new_user_session" },
            { verb: "POST", path: "/login", action: "create", name: "user_session" },
            { verb: "DELETE", path: "/logout", action: "destroy", name: "destroy_user_session" }
          ],
          "posts" => [
            { verb: "GET", path: "/posts", action: "index", name: "posts" },
            { verb: "GET", path: "/posts/:id", action: "show", name: "post" }
          ]
        }
      }
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return(mock_context)
    allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(Dir.pwd)))
  end

  describe ".call" do
    it "returns matching models with schema, associations, validations, and scopes" do
      result = described_class.call(feature: "user")
      text = result.content.first[:text]

      expect(text).to include("Feature Analysis: user")
      expect(text).to include("Models (2)")
      expect(text).to include("### User")
      expect(text).to include("### UserSession")
      expect(text).to include("email:string")
      expect(text).to include("has_many :posts")
      expect(text).to include("presence on email")
      expect(text).to include("active, admins")
      expect(text).to include("active, admins")
    end

    it "returns matching controllers with actions and filters" do
      result = described_class.call(feature: "user")
      text = result.content.first[:text]

      expect(text).to include("Controllers (2)")
      expect(text).to include("### UsersController")
      expect(text).to include("### UserSessionsController")
      expect(text).to include("index, show, create")
      expect(text).to include("before_action authenticate!")
    end

    it "returns matching routes" do
      result = described_class.call(feature: "user")
      text = result.content.first[:text]

      expect(text).to include("Routes (6)")
      expect(text).to include("`GET` `/users`")
      expect(text).to include("`POST` `/login`")
      expect(text).to include("`DELETE` `/logout`")
    end

    it "returns no-match messages when feature has no hits" do
      result = described_class.call(feature: "zzz_nonexistent")
      text = result.content.first[:text]

      expect(text).to include("No models matching")
      expect(text).to include("No controllers matching")
      expect(text).to include("No routes matching")
    end

    it "handles missing introspection data gracefully" do
      allow(described_class).to receive(:cached_context).and_return({})
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(Dir.pwd)))
      result = described_class.call(feature: "anything")
      text = result.content.first[:text]

      expect(text).to include("Feature Analysis: anything")
      expect(text).to include("No models matching")
      expect(text).to include("No controllers matching")
      expect(text).to include("No routes matching")
    end

    it "performs case-insensitive matching" do
      result = described_class.call(feature: "POST")
      text = result.content.first[:text]

      expect(text).to include("### Post")
      expect(text).to include("### PostsController")
      expect(text).to include("`GET` `/posts`")
    end
  end
end
