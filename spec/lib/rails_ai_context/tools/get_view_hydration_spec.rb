# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetView, "hydration" do
  before do
    described_class.reset_cache!
    allow(RailsAiContext.configuration).to receive(:hydration_enabled).and_return(hydration_enabled)
    allow(RailsAiContext.configuration).to receive(:hydration_max_hints).and_return(5)
  end

  let(:models) do
    {
      "Post" => {
        table_name: "posts",
        associations: [ { name: "comments", type: "has_many", class_name: "Comment" } ],
        validations: [ { kind: "presence", attributes: [ "title" ] } ]
      }
    }
  end

  let(:schema) do
    {
      tables: {
        "posts" => {
          columns: [
            { name: "id", type: "integer", null: false },
            { name: "title", type: "string", null: false }
          ],
          primary_key: "id"
        }
      }
    }
  end

  let(:templates) do
    {
      "posts/index.html.erb" => { lines: 10, partials: [ "posts/post" ], stimulus: %w[search] },
      "posts/show.html.erb" => { lines: 5, partials: [], stimulus: [] }
    }
  end

  let(:partials) do
    {
      "posts/_post.html.erb" => { lines: 8, fields: %w[title body] }
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({
      view_templates: { templates: templates, partials: partials },
      models: models,
      schema: schema
    })
  end

  context "when hydration_enabled is true" do
    let(:hydration_enabled) { true }

    it "includes schema hints when views have model ivars" do
      # The view template at posts/index.html.erb uses @posts which should resolve to Post
      result = described_class.call(controller: "posts", detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("Schema Hints")
      expect(text).to include("Post")
    end

    it "includes column information in schema hints" do
      result = described_class.call(controller: "posts", detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("`title` string NOT NULL")
    end

    it "includes association information in schema hints" do
      result = described_class.call(controller: "posts", detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("`has_many` :comments")
    end
  end

  context "when hydration_enabled is false" do
    let(:hydration_enabled) { false }

    it "suppresses schema hints" do
      result = described_class.call(controller: "posts", detail: "standard")
      text = result.content.first[:text]
      expect(text).not_to include("Schema Hints")
    end
  end

  context "when no controller specified" do
    let(:hydration_enabled) { true }

    it "does not include schema hints in general listing" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      # Hydration only fires when a specific controller is given
      # (the guard is `hydration_enabled && controller`)
      # In a standard listing without controller, "Schema Hints" should not appear
      # unless the output incidentally includes those words
      expect(text).not_to include("## Schema Hints")
    end
  end

  context "when views have no model ivars" do
    let(:hydration_enabled) { true }

    before do
      allow(described_class).to receive(:cached_context).and_return({
        view_templates: {
          templates: {
            "static/about.html.erb" => { lines: 3, partials: [], stimulus: [] }
          },
          partials: {}
        },
        models: models,
        schema: schema
      })
    end

    it "does not include schema hints when no ivars found" do
      result = described_class.call(controller: "static", detail: "standard")
      text = result.content.first[:text]
      expect(text).not_to include("Schema Hints")
    end
  end
end
