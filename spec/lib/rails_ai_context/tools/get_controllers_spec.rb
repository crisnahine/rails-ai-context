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

    # A base controller with no public actions rendered as a name, a dash and
    # nothing, which reads as a truncated line rather than an answer.
    it "says so when a controller has no public actions" do
      stub_controllers({
        "Admin::BaseController" => { actions: [], filters: [], strong_params: [], parent_class: "ApplicationController" }
      })

      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("- **Admin::BaseController** - (no public actions)")
    end

    # A file the walk could not read is not a controller with nothing in it,
    # and the single-controller answer already says so.
    it "says a controller could not be read in every listing detail" do
      stub_controllers({
        "HugeController" => { error: "unreadable" }
      })

      summary = described_class.call(detail: "summary").content.first[:text]
      standard = described_class.call(detail: "standard").content.first[:text]
      full = described_class.call(detail: "full").content.first[:text]

      expect(summary).to include("- **HugeController** - (could not be read: unreadable)")
      expect(standard).to include("- **HugeController** - (could not be read: unreadable)")
      expect(full).to include("- Could not be read: unreadable")
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

      expect(text).to include("## Admin::* (3 controllers)")
      expect(text).to include("- Members: Admin::OneController, Admin::ThreeController, Admin::TwoController")
      expect(text).to include("- Strong params: filter_params")
    end

    # The heading was built from the first member's own class name, so five
    # top-level controllers were filed under a namespace no controller is in.
    it "heads a group of top-level controllers with no namespace" do
      entry = { actions: %w[show], filters: [], strong_params: [], parent_class: "ActionController::Base" }
      stub_controllers({
        "CustomCssController" => entry.dup,
        "HealthController" => entry.dup,
        "ManifestsController" => entry.dup
      })

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).not_to include("CustomCssController::*")
      expect(text).to include("## 3 controllers")
      expect(text).to include("- Members: CustomCssController, HealthController, ManifestsController")
    end

    # A group heads under the namespace every member is really in, not the
    # first segment of the first member's name.
    it "heads a group with the namespace all its members share" do
      entry = { actions: %w[show], filters: [], strong_params: [], parent_class: "Admin::BaseController" }
      stub_controllers({
        "Admin::EmailSubscriptions::FooterTextsController" => entry.dup,
        "Admin::Settings::AboutController" => entry.dup,
        "Admin::Settings::AppearanceController" => entry.dup
      })

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("## Admin::* (3 controllers)")
      expect(text).to include(
        "- Members: Admin::EmailSubscriptions::FooterTextsController, " \
          "Admin::Settings::AboutController, Admin::Settings::AppearanceController"
      )
    end

    # Every controller the plain listing names has to be findable in the full
    # answer by the constant it really has.
    it "names every controller by its real constant in the full listing" do
      entry = { actions: %w[show], filters: [], strong_params: [], parent_class: "Api::BaseController" }
      names = [ "Api::SearchController", "Api::AsyncRefreshesController", "OAuth::UserinfoController" ]
      stub_controllers(names.to_h { |n| [ n, entry.dup ] })

      text = described_class.call(detail: "full").content.first[:text]

      names.each { |name| expect(text).to include(name) }
      expect(text).not_to include("Api::* ")
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

      expect(text).to include("- Filters: before require_actor_signature!, ~~authenticate_user!~~ _(skipped)_")
      expect(text).not_to include("before authenticate_user!")
    end

    # The compressed group renders one member's filters for all of them, so a
    # skip has to keep the skipper out of a group of declarers.
    it "does not group a controller that skips a filter with the ones that declare it" do
      declarer = {
        actions: %w[index show],
        filters: [ { kind: "before", name: "authenticate" } ],
        strong_params: [],
        parent_class: "Admin::BaseController"
      }
      stub_controllers({
        "Admin::PostsController" => declarer.merge(
          filters: [ { kind: "before", name: "authenticate", skipped: true } ]
        ),
        "Admin::TagsController" => declarer.dup,
        "Admin::UsersController" => declarer.dup
      })

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("## Admin::PostsController")
      expect(text).to include("- Filters: ~~authenticate~~ _(skipped)_")
      expect(text).not_to include("## Admin::* (Posts, Tags, Users)")
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

    # The listing rendered the class's own filter records while the
    # single-controller answer resolved the chain, so one tool gave two
    # answers to one question about the same controller. A skip carrying
    # `unless:` does not take the filter out on every request, so neither
    # answer strikes it through.
    it "says the same thing about a conditional skip in both answers" do
      stub_controllers({
        "ApplicationController" => {
          actions: [],
          filters: [ { kind: "before", name: "require_functional!" } ],
          strong_params: []
        },
        "AccountsController" => {
          actions: %w[show],
          parent_class: "ApplicationController",
          filters: [
            { kind: "before", name: "require_functional!", skipped: true, unless: "limited_federation_mode?" }
          ],
          strong_params: []
        }
      })

      listing = described_class.call(detail: "full").content.first[:text]
      single = described_class.call(controller: "AccountsController").content.first[:text]

      expect(listing).to include("- Filters: before require_functional! (skipped unless: limited_federation_mode?)")
      expect(listing).not_to include("~~require_functional!~~")
      expect(single).to include("**require_functional!** _(from ApplicationController)_ (skipped unless: limited_federation_mode?)")
      expect(single).not_to include("~~require_functional!~~")
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
