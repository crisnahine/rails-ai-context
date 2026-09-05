# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

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
        strong_params: [ { name: "post_params", permits: %w[title body] } ],
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
        strong_params: [ { name: "comment_params", permits: %w[body] } ],
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
      expect(text).to include("**PostsController** - index, show, create, update, destroy")
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

  describe "detail levels with filter data" do
    before do
      detail_controllers = {
        "UsersController" => {
          actions: %w[index show create],
          filters: [ { kind: "before_action", name: "authenticate_user!" } ],
          strong_params: [ { name: "user_params", permits: %w[name email] } ],
          parent_class: "ApplicationController"
        },
        "PostsController" => {
          actions: %w[index show],
          filters: [],
          strong_params: [ { name: "post_params", permits: %w[title body] } ]
        }
      }
      allow(described_class).to receive(:cached_context).and_return({
        controllers: { controllers: detail_controllers }
      })
    end

    it "returns names with action counts for detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("**UsersController** - 3 actions")
      expect(text).to include("**PostsController** - 2 actions")
    end

    it "returns everything for detail:full" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("## UsersController")
      expect(text).to include("Filters:")
      expect(text).to include("authenticate_user!")
    end
  end

  describe "detail:full over the shape the introspector really records" do
    def stub_controllers(controllers)
      allow(described_class).to receive(:cached_context).and_return({
        controllers: { controllers: controllers }
      })
    end

    it "names both strong params methods of a controller under an app parent" do
      stub_controllers({
        "Admin::AccountsController" => {
          actions: %w[index show],
          filters: [ { kind: "before_action", name: "set_account" } ],
          strong_params: [
            { name: "filter_params", permits: %w[origin status] },
            { name: "form_account_batch_params", requires: "form_account_batch", permits: %w[action account_ids] }
          ],
          parent_class: "Admin::BaseController"
        }
      })

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("## Admin::AccountsController")
      expect(text).to include("- Strong params: filter_params, form_account_batch_params")
    end

    it "names them on a compressed sibling group too" do
      entry = {
        actions: %w[index],
        filters: [],
        strong_params: [ { name: "filter_params", permits: %w[origin] } ],
        parent_class: "Admin::BaseController"
      }
      stub_controllers({
        "Admin::OneController" => entry.dup,
        "Admin::TwoController" => entry.dup,
        "Admin::ThreeController" => entry.dup
      })

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("## Admin::* (One, Three, Two)")
      expect(text).to include("- Strong params: filter_params")
    end

    # The booted tier renders a skipped filter struck through. The listing
    # printed it as one the action runs, so the two tiers said the opposite.
    it "strikes through a filter the controller skips" do
      stub_controllers({
        "ActivityPub::InboxesController" => {
          actions: %w[create],
          filters: [
            { kind: "before", name: "authenticate_user!", skipped: true },
            { kind: "before", name: "require_actor_signature!" }
          ],
          strong_params: [],
          parent_class: "ActivityPub::BaseController"
        }
      })

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("- Filters: ~~authenticate_user!~~ _(skipped)_, before require_actor_signature!")
      expect(text).not_to include("before authenticate_user!")
    end

    it "pairs each rescued exception with its handler" do
      stub_controllers({
        "MediaProxyController" => {
          actions: %w[show],
          filters: [],
          strong_params: [],
          rescue_from: [
            { exception: "ActiveRecord::RecordInvalid", handler: "not_found" },
            { exception: "Mastodon::NotPermittedError" }
          ],
          parent_class: "ApplicationController"
        }
      })

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("- Rescue from: ActiveRecord::RecordInvalid -> not_found, Mastodon::NotPermittedError")
    end

    it "pairs them on the single-controller answer as well" do
      stub_controllers({
        "MediaProxyController" => {
          actions: %w[show],
          filters: [],
          strong_params: [],
          rescue_from: [ { exception: "ActiveRecord::RecordInvalid", handler: "not_found" } ],
          parent_class: "ApplicationController"
        }
      })

      text = described_class.call(controller: "MediaProxyController").content.first[:text]

      expect(text).to include("- `rescue_from` ActiveRecord::RecordInvalid -> not_found")
    end
  end

  describe "an action calling a protected method" do
    it "inlines it under Private Methods Called" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app", "controllers"))
        File.write(File.join(root, "app", "controllers", "widgets_controller.rb"), <<~RUBY)
          class WidgetsController < ApplicationController
            def show
              load_widget
            end

            protected

            def load_widget
              @widget = Widget.find(params[:id])
            end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))
        allow(described_class).to receive(:cached_context).and_return(
          controllers: { controllers: { "WidgetsController" => {
            actions: %w[show], filters: [], parent_class: "ApplicationController", file: "app/controllers/widgets_controller.rb"
          } } }
        )

        text = described_class.call(controller: "WidgetsController", action: "show").content.first[:text]

        expect(text).to include("## Private Methods Called")
        expect(text).to include("### load_widget")
      end
    end

    it "inlines the body of a private method the action calls" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/controllers"))
        File.write(File.join(root, "app/controllers/widgets_controller.rb"), <<~RUBY)
          class WidgetsController < ApplicationController
            def show
              load_widget
            end

            private

            def load_widget
              @widget = Widget.find(params[:id])
            end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))
        allow(described_class).to receive(:cached_context).and_return(
          controllers: { controllers: { "WidgetsController" => {
            actions: %w[show], filters: [], parent_class: "ApplicationController",
            file: "app/controllers/widgets_controller.rb"
          } } }
        )

        text = described_class.call(controller: "WidgetsController", action: "show").content.first[:text]

        expect(text).to include("## Private Methods Called")
        expect(text).to include("### load_widget")
        expect(text).to include("@widget = Widget.find(params[:id])")
      end
    end

    # An inherited filter names where it was declared, not whichever class
    # happens to be the direct parent.
    it "names the grandparent an inherited filter was declared on" do
      allow(described_class).to receive(:cached_context).and_return(
        controllers: { controllers: {
          "ApplicationController" => { actions: [], filters: [ { kind: "before_action", name: "authenticate" } ] },
          "Admin::BaseController" => { actions: [], filters: [], parent_class: "ApplicationController" },
          "Admin::PostsController" => { actions: %w[index], filters: [], parent_class: "Admin::BaseController" }
        } }
      )

      text = described_class.call(controller: "Admin::PostsController").content.first[:text]

      expect(text).to include("_(from ApplicationController)_")
      expect(text).not_to include("_(from Admin::BaseController)_")
    end
  end
end
