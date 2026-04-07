# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetControllers, "hydration" do
  before do
    described_class.reset_cache!
    allow(RailsAiContext.configuration).to receive(:hydration_enabled).and_return(hydration_enabled)
    allow(RailsAiContext.configuration).to receive(:hydration_max_hints).and_return(5)
  end

  let(:controllers) do
    {
      "PostsController" => {
        actions: %w[index show create],
        filters: [],
        strong_params: %w[post_params],
        parent_class: "ApplicationController"
      }
    }
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

  before do
    allow(described_class).to receive(:cached_context).and_return({
      controllers: { controllers: controllers },
      models: models,
      schema: schema
    })
  end

  context "when hydration_enabled is true" do
    let(:hydration_enabled) { true }

    it "includes schema hints when controller references models" do
      # The hydrator needs a real file on disk to parse. Use the test app's controller.
      source_path = Rails.root.join("app", "controllers", "posts_controller.rb")
      # Only test if the source file exists (Combustion test app)
      skip "No posts_controller.rb in test app" unless File.exist?(source_path)

      result = described_class.call(controller: "PostsController")
      text = result.content.first[:text]
      expect(text).to include("Schema Hints")
      expect(text).to include("Post")
    end
  end

  context "when hydration_enabled is false" do
    let(:hydration_enabled) { false }

    it "suppresses schema hints" do
      result = described_class.call(controller: "PostsController")
      text = result.content.first[:text]
      expect(text).not_to include("Schema Hints")
    end
  end

  context "when controller has no model references" do
    let(:hydration_enabled) { true }

    before do
      allow(described_class).to receive(:cached_context).and_return({
        controllers: {
          controllers: {
            "HealthController" => {
              actions: %w[index],
              filters: [],
              strong_params: [],
              parent_class: "ApplicationController"
            }
          }
        },
        models: models,
        schema: schema
      })
    end

    it "does not include schema hints section" do
      result = described_class.call(controller: "HealthController")
      text = result.content.first[:text]
      # No source file for HealthController, so hydrator returns empty
      expect(text).not_to include("Schema Hints")
    end
  end
end
