# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetModelDetails do
  before { described_class.reset_cache! }

  let(:models) do
    {
      "User" => {
        table_name: "users",
        associations: [
          { type: "has_many", name: "posts", dependent: "destroy" },
          { type: "has_many", name: "comments", dependent: "destroy" }
        ],
        validations: [
          { kind: "presence", attributes: [ "email" ], options: {} }
        ],
        enums: { "role" => { "member" => 0, "admin" => 1 } },
        scopes: [
          { name: "active", body: "where(active: true)" },
          { name: "admins", body: "where(role: :admin)" }
        ],
        callbacks: {}
      },
      "Post" => {
        table_name: "posts",
        associations: [
          { type: "belongs_to", name: "user" },
          { type: "has_many", name: "comments", dependent: "destroy" }
        ],
        validations: [
          { kind: "presence", attributes: [ "title" ], options: {} }
        ]
      },
      "Comment" => {
        table_name: "comments",
        associations: [
          { type: "belongs_to", name: "post" },
          { type: "belongs_to", name: "user" }
        ],
        validations: [
          { kind: "presence", attributes: [ "body" ], options: {} }
        ]
      }
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ models: models })
  end

  describe ".call with no params" do
    it "defaults to standard detail level" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Models (3)")
      expect(text).to include("**User**")
      expect(text).to include("associations")
    end

    it "sorts models by association count descending" do
      result = described_class.call
      text = result.content.first[:text]
      # User has 2 associations, Post has 2, Comment has 2 - all tied but User should appear
      expect(text).to include("**User**")
      expect(text).to include("**Post**")
      expect(text).to include("**Comment**")
    end
  end

  describe ".call with model not found" do
    it "returns a not-found response with available models" do
      result = described_class.call(model: "Nonexistent")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("Available:")
      expect(text).to include("User")
    end

    it "provides a recovery tool hint" do
      result = described_class.call(model: "Nonexistent")
      text = result.content.first[:text]
      expect(text).to include("rails_get_model_details")
    end

    it "suggests a close match via fuzzy matching" do
      result = described_class.call(model: "Userr")
      text = result.content.first[:text]
      expect(text).to include("Did you mean")
      expect(text).to include("User")
    end
  end

  describe ".call with specific model" do
    it "returns full detail including associations section" do
      result = described_class.call(model: "User")
      text = result.content.first[:text]
      expect(text).to include("# User")
      expect(text).to include("## Associations")
      expect(text).to include("has_many")
      expect(text).to include("posts")
    end

    it "shows enums when present" do
      result = described_class.call(model: "User")
      text = result.content.first[:text]
      expect(text).to include("## Enums")
      expect(text).to include("role")
      expect(text).to include("member")
      expect(text).to include("admin")
    end

    it "shows scopes when present" do
      result = described_class.call(model: "User")
      text = result.content.first[:text]
      expect(text).to include("## Scopes")
      expect(text).to include("active")
    end

    it "shows cross-reference hints" do
      result = described_class.call(model: "User")
      text = result.content.first[:text]
      expect(text).to include("rails_get_schema")
      expect(text).to include("rails_get_controllers")
    end

    it "handles model with error in data" do
      models_with_error = models.merge("Broken" => { error: "could not load" })
      allow(described_class).to receive(:cached_context).and_return({ models: models_with_error })
      result = described_class.call(model: "Broken")
      text = result.content.first[:text]
      expect(text).to include("Error inspecting")
      expect(text).to include("could not load")
    end

    it "strips whitespace from model name input" do
      result = described_class.call(model: "  User  ")
      text = result.content.first[:text]
      expect(text).to include("# User")
    end
  end

  describe ".call with a Mongoid model" do
    let(:mongoid_models) do
      {
        "Customer" => {
          mongoid: true,
          fields: [ { name: :name, type: "String" }, { name: :active, type: "Boolean" } ],
          embeds: [ { type: :embeds_many, name: :orders } ],
          associations: [],
          validations: []
        }
      }
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({ models: mongoid_models })
    end

    it "renders declared fields since there is no AR table/columns" do
      result = described_class.call(model: "Customer")
      text = result.content.first[:text]
      expect(text).to include("## Fields")
      expect(text).to include("name")
      expect(text).to include("String")
    end

    it "renders embedded relations" do
      result = described_class.call(model: "Customer")
      text = result.content.first[:text]
      expect(text).to include("## Embedded relations")
      expect(text).to include("embeds_many")
      expect(text).to include("orders")
    end
  end

  describe ".call with pagination" do
    it "respects limit parameter" do
      result = described_class.call(limit: 1)
      text = result.content.first[:text]
      expect(text).to include("Showing 1-1 of 3")
    end

    it "returns empty-pagination message when offset exceeds total" do
      result = described_class.call(offset: 100)
      text = result.content.first[:text]
      expect(text).to include("No items at offset 100")
      expect(text).to include("Total: 3")
    end

    it "normalizes limit of 0 to minimum of 1" do
      result = described_class.call(limit: 0)
      text = result.content.first[:text]
      # paginate clamps limit to minimum of 1
      expect(text).to include("Models")
    end
  end

  describe ".call when introspection data is missing" do
    it "returns not-available when models key is nil" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "returns error message when models data has an error" do
      allow(described_class).to receive(:cached_context).and_return({
        models: { error: "database unreachable" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("database unreachable")
    end
  end

  describe "detail levels with simple model data" do
    before do
      simple_models = {
        "User" => {
          table_name: "users",
          associations: [ { type: "has_many", name: "posts" }, { type: "has_one", name: "profile" } ],
          validations: [ { kind: "presence", attributes: [ "email" ], options: {} } ]
        },
        "Post" => {
          table_name: "posts",
          associations: [ { type: "belongs_to", name: "user" } ],
          validations: []
        }
      }
      allow(described_class).to receive(:cached_context).and_return({ models: simple_models })
    end

    it "returns names only with detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("- Post")
      expect(text).to include("- User")
      expect(text).not_to include("associations")
    end

    it "returns names with association list for detail:full" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("**User**")
      expect(text).to include("has_many :posts")
    end

    it "supports case-insensitive model lookup" do
      result = described_class.call(model: "user")
      text = result.content.first[:text]
      expect(text).to include("# User")
    end
  end
  # A model in a pack does not live under app/models, so rebuilding the path
  # from the name found nothing and every source-read section went quietly
  # missing from an answer that otherwise looked complete.
  describe "a model whose file is not under app/models" do
    around do |example|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "packs", "billing", "app", "models", "invoice.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, <<~RUBY)
          class Invoice < ApplicationRecord
            def overdue_by(days)
            end
          end
        RUBY
        @root = dir
        example.run
      end
    end

    it "reads the source from the file the model carries" do
      described_class.reset_cache!
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return(
        models: { "Invoice" => { table_name: "invoices", file: "packs/billing/app/models/invoice.rb" } }
      )

      text = described_class.call(model: "Invoice", detail: "full").content.first[:text]

      expect(text).to include("overdue_by")
    end
  end
end
