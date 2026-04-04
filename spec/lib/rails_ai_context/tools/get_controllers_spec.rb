# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetControllers do
  before { described_class.reset_cache! }

  let(:controllers) do
    {
      "PostsController" => {
        actions: %w[index show create update destroy],
        filters: [
          { kind: "before_action", name: "set_post", only: %w[show edit update destroy] },
          { kind: "before_action", name: "authenticate_user!" }
        ],
        strong_params: %w[post_params],
        parent_class: "ApplicationController"
      },
      "UsersController" => {
        actions: %w[index show],
        filters: [],
        strong_params: [],
        parent_class: "ApplicationController"
      },
      "CommentsController" => {
        actions: %w[create destroy],
        filters: [],
        strong_params: %w[comment_params],
        parent_class: "ApplicationController"
      }
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({
      controllers: { controllers: controllers }
    })
  end

  describe ".call with no params" do
    it "defaults to standard detail level" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Controllers (3)")
      expect(text).to include("**PostsController** — index, show, create, update, destroy")
    end

    it "returns all controllers sorted alphabetically" do
      result = described_class.call
      text = result.content.first[:text]
      comments_pos = text.index("CommentsController")
      posts_pos = text.index("PostsController")
      users_pos = text.index("UsersController")
      expect(comments_pos).to be < posts_pos
      expect(posts_pos).to be < users_pos
    end
  end

  describe ".call with controller not found" do
    it "returns a not-found response with suggestions" do
      result = described_class.call(controller: "NonexistentController")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("Available:")
    end

    it "suggests a close match via fuzzy matching" do
      result = described_class.call(controller: "Posts")
      text = result.content.first[:text]
      # Should match PostsController via flexible lookup
      expect(text).to include("# PostsController")
    end

    it "provides a recovery tool hint" do
      result = described_class.call(controller: "ZzzNonexistentController")
      text = result.content.first[:text]
      expect(text).to include("rails_get_controllers")
    end
  end

  describe ".call with controller that has an error" do
    before do
      error_controllers = controllers.merge(
        "BrokenController" => { error: "Failed to load controller" }
      )
      allow(described_class).to receive(:cached_context).and_return({
        controllers: { controllers: error_controllers }
      })
    end

    it "returns the error message for a specific controller with an error" do
      result = described_class.call(controller: "BrokenController")
      text = result.content.first[:text]
      expect(text).to include("Error inspecting")
      expect(text).to include("Failed to load controller")
    end
  end

  describe ".call with pagination" do
    it "respects limit parameter" do
      result = described_class.call(limit: 1)
      text = result.content.first[:text]
      expect(text).to include("Showing 1-1 of 3")
    end

    it "respects offset parameter" do
      result = described_class.call(limit: 1, offset: 1)
      text = result.content.first[:text]
      expect(text).to include("PostsController")
      expect(text).not_to include("CommentsController")
    end

    it "returns empty-pagination message when offset exceeds total" do
      result = described_class.call(offset: 100)
      text = result.content.first[:text]
      expect(text).to include("No items at offset 100")
      expect(text).to include("Total: 3")
    end

    it "clamps negative offset to 0" do
      result = described_class.call(offset: -5)
      text = result.content.first[:text]
      expect(text).to include("Controllers (3)")
    end
  end

  describe ".call when introspection data is missing" do
    it "returns not-available when controllers key is nil" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "returns error message when controllers data has an error" do
      allow(described_class).to receive(:cached_context).and_return({
        controllers: { error: "something went wrong" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("something went wrong")
    end
  end

  describe ".call with flexible controller name formats" do
    it "resolves snake_case controller name" do
      result = described_class.call(controller: "posts_controller")
      text = result.content.first[:text]
      expect(text).to include("# PostsController")
    end

    it "resolves bare plural name" do
      result = described_class.call(controller: "posts")
      text = result.content.first[:text]
      expect(text).to include("# PostsController")
    end

    it "resolves lowercased controller name without suffix" do
      result = described_class.call(controller: "comments")
      text = result.content.first[:text]
      expect(text).to include("# CommentsController")
    end
  end
end
