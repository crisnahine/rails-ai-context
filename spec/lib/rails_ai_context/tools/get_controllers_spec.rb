# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Tools::GetControllers do
  # SafeCall normalizes `detail` before the tool body runs, so a junk value
  # reaches the standard listing rather than falling out of the case.
  describe "a detail value no tool declares" do
    before { described_class.reset_cache! }

    it "renders the standard listing and says the value was refused" do
      allow(described_class).to receive(:cached_context).and_return(
        controllers: { controllers: { "PostsController" => { parent_class: "ApplicationController", actions: %w[index] } } }
      )

      text = described_class.call(detail: "zzz").content.first[:text]

      expect(text).to include("- **PostsController**")
      expect(text).to include("_Use `controller:\"Name\"` for filters and strong params")
      expect(text).to include("is not a valid `detail`")
    end
  end

  describe "a filter a concern declares" do
    before { described_class.reset_cache! }

    it "names the concern, and says which included modules it could not read" do
      allow(described_class).to receive(:cached_context).and_return(
        controllers: { controllers: { "AboutController" => {
          parent_class: "ActionController::Base", actions: %w[show],
          filters: [ { name: "set_referer_header", kind: "before", declared: true,
                       from_concern: "WebAppControllerConcern" } ],
          concerns_unread: [ "Pundit::Authorization" ]
        } } }
      )

      text = described_class.call(controller: "AboutController").content.first[:text]

      expect(text).to include("- `before` **set_referer_header** _(from WebAppControllerConcern)_")
      expect(text).to include("1 included module not read, so a filter declared there is missing " \
                              "from this list: Pundit::Authorization")
    end
  end

  # A group of top-level controllers shares no namespace, so the heading was
  # the bare count - and two such groups in one document carried the same
  # heading, naming nothing and repeating.
  describe "a compressed group with no namespace of its own" do
    before { described_class.reset_cache! }

    it "heads the group with a member, not with a count alone" do
      allow(described_class).to receive(:cached_context).and_return(
        controllers: { controllers: {
          "PostsController" => { parent_class: "AdminController", actions: %w[index] },
          "PagesController" => { parent_class: "AdminController", actions: %w[index] },
          "SitesController" => { parent_class: "AdminController", actions: %w[index] },
          "AdminController" => { parent_class: "ApplicationController", actions: [] }
        } }
      )

      text = described_class.call(detail: "full").content.first[:text]
      headings = text.lines.select { |line| line.start_with?("## ") }.map(&:strip)

      expect(headings).to include("## PagesController and 2 like it (3 controllers)")
      expect(headings.uniq.size).to eq(headings.size)
    end
  end

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

    # A bare `gift_cards` resolves from the tool the same way the
    # rails-ai-context://controllers resource resolves it, off the same payload.
    it "resolves the bare name of a controller that only exists namespaced" do
      allow(described_class).to receive(:cached_context).and_return(
        controllers: { controllers: {
          "Admin::GiftCardsController" => { actions: %w[index], file: "app/controllers/admin/gift_cards_controller.rb" }
        } }
      )

      text = described_class.call(controller: "gift_cards").content.first[:text]

      expect(text).to include("# Admin::GiftCardsController")
    end

    # Rails resolves a namespaced controller's templates under its full
    # path; the basename is another component's directory.
    it "points the view hint at the controller's full path" do
      allow(described_class).to receive(:cached_context).and_return(
        controllers: { controllers: {
          "Admin::GiftCardsController" => { actions: %w[index], file: "app/controllers/admin/gift_cards_controller.rb" }
        } }
      )

      text = described_class.call(controller: "Admin::GiftCardsController").content.first[:text]

      expect(text).to include(%(`rails_get_view(controller:"admin/gift_cards")`))
    end

    it "resolves a controller by the route key Rails serves it under" do
      allow(described_class).to receive(:cached_context).and_return(
        controllers: { controllers: {
          "ActivityPub::InboxesController" => { actions: %w[create], file: "app/controllers/activitypub/inboxes_controller.rb" }
        } }
      )

      text = described_class.call(controller: "activitypub/inboxes").content.first[:text]

      expect(text).to include("# ActivityPub::InboxesController")
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

    # Rails unshifts a prepended filter onto the chain the class inherited, so
    # z runs first, then ApplicationController's prepended y.
    describe "a prepended filter" do
      around do |example|
        previous = RailsAiContext.tier
        RailsAiContext.tier = :static
        example.run
      ensure
        RailsAiContext.tier = previous
      end

      before do
        stub_controllers({
          "ApplicationController" => { actions: [], parent_class: "ActionController::Base",
                                       filters: [ { kind: "before", name: "x", declared: true },
                                                  { kind: "before", name: "y", prepend: true, declared: true } ] },
          "KidsController" => { actions: %w[index], parent_class: "ApplicationController",
                                filters: [ { kind: "before", name: "k", declared: true },
                                           { kind: "before", name: "z", prepend: true, declared: true } ] }
        })
      end

      it "leads the controller's filter list" do
        text = described_class.call(controller: "KidsController").content.first[:text]

        expect(text.scan(/^- `before` \*\*(\w+)\*\*/).flatten).to eq(%w[z y x k])
      end

      it "leads an action's filter list" do
        text = described_class.call(controller: "KidsController", action: "index").content.first[:text]

        expect(text.scan(/^- `before` \*\*(\w+)\*\*/).flatten).to eq(%w[z y x k])
      end

      it "leads the full listing's filter line" do
        text = described_class.call(detail: "full").content.first[:text]

        expect(text).to include("- Filters: before z, before y, before x, before k")
      end
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

      expect(summary).to include("- **HugeController** - [UNAVAILABLE: unreadable]")
      expect(standard).to include("- **HugeController** - [UNAVAILABLE: unreadable]")
      expect(full).to include("- [UNAVAILABLE: unreadable]")
    end

    it "prints every rate limit a controller declares" do
      limits = [ { text: "to: 10, within: 3.minutes, only: :create" }, { text: 'to: 100, within: 1.hour, name: "long"' } ]
      stub_controllers({ "SessionsController" => { actions: %w[create], filters: [], parent_class: "ApplicationController", rate_limits: limits } })

      one = described_class.call(controller: "SessionsController").content.first[:text]
      full = described_class.call(detail: "full").content.first[:text]

      expect(one).to include("**Rate limits:**\n- to: 10, within: 3.minutes, only: :create\n- to: 100, within: 1.hour, name: \"long\"")
      expect(full).to include('- Rate limit: to: 10, within: 3.minutes, only: :create; to: 100, within: 1.hour, name: "long"')
    end

    it "says the engine a static run from its test/dummy does not read, in the listing and when a name is not found" do
      allow(described_class).to receive(:cached_context).and_return({ controllers: { controllers: {}, unread_engine: "../.." } })

      %w[summary standard full].each do |detail|
        expect(described_class.call(detail: detail).content.first[:text]).to include("The engine at `../..` is not read unbooted")
      end
      expect(described_class.call(controller: "Shop::WidgetsController").content.first[:text]).to include("The engine at `../..` is not read unbooted")
    end

    it "leaves an inherited rate limit out of the full listing and names its base in the controller's detail" do
      inherited = { text: "to: 5, within: 1.minute", from: "Admin::BaseController" }
      stub_controllers({ "Admin::ReportsController" => { actions: %w[index], filters: [], parent_class: "Admin::BaseController", rate_limits: [ inherited ] },
                         "Admin::UsersController" => { actions: %w[index], filters: [], parent_class: "Admin::BaseController",
                                                       rate_limits: [ inherited, { text: "to: 2, within: 1.minute" } ] } })

      one = described_class.call(controller: "Admin::ReportsController").content.first[:text]
      full = described_class.call(detail: "full").content.first[:text]

      expect(one).to include("**Rate limit:** to: 5, within: 1.minute _(from Admin::BaseController)_")
      expect(full).not_to include("to: 5, within: 1.minute")
      expect(full).to include("- Rate limit: to: 2, within: 1.minute\n")
    end

    it "names the layout a controller renders in and the settings it and ApplicationController declare" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/controllers"))
        FileUtils.mkdir_p(File.join(root, "app/views/layouts"))
        File.write(File.join(root, "app/views/layouts/admin.html.erb"), "")
        File.write(File.join(root, "app/controllers/application_controller.rb"),
                   "class ApplicationController < ActionController::Base\n  allow_browser versions: :modern\n  add_flash_types :warning, :info\nend\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))
        stub_controllers({ "UsersController" => { actions: %w[index], filters: [], parent_class: "ApplicationController",
                                                  layout: { name: "admin" }, settings: [ "wrap_parameters :user, include: [:name, :email_address]" ] } })

        text = described_class.call(controller: "UsersController", detail: "full").content.first[:text]

        expect(text).to include("**Layout:** `admin` (declared in UsersController)")
        expect(text).to include("## Settings\n- `allow_browser versions: :modern` _(from ApplicationController)_\n" \
                                "- `add_flash_types :warning, :info` _(from ApplicationController)_\n" \
                                "- `wrap_parameters :user, include: [:name, :email_address]`")
      end
    end

    it "summarizes a strong params method's nested keys and arrays beside its permits" do
      params = [ { name: "user_params", requires: "user", permits: [ "name" ], nested: { "preferences" => [ "color" ] }, arrays: [ "tags" ] } ]
      stub_controllers({ "UsersController" => { actions: %w[update], filters: [], parent_class: "ApplicationController", strong_params: params } })

      text = described_class.call(controller: "UsersController").content.first[:text]

      expect(text).to include("- `user_params` (requires: :user) permits: :name, preferences: [:color], tags: []")
    end

    it "summarizes the arrays and hashes a nested key permits" do
      params = [ { name: "s_params", requires: "s", permits: [ "hide" ], hashes: [ "colors" ],
                   nested: { "filters" => [ "module_id", { "module_ids" => [] }, { "range" => %w[from to] }, { "opts" => {} } ] } } ]
      stub_controllers({ "SController" => { actions: %w[update], filters: [], parent_class: "ApplicationController", strong_params: params } })

      text = described_class.call(controller: "SController").content.first[:text]

      expect(text).to include("permits: :hide, filters: [:module_id, { module_ids: [] }, { range: [:from, :to] }, { opts: {} }], colors: {}")
    end

    it "prints a hash filter with keys as the keys it permits" do
      params = [ { name: "s_params", requires: "s", nested: { "prefs" => { "theme" => [], "extra" => {} } } } ]
      stub_controllers({ "SController" => { actions: %w[update], filters: [], parent_class: "ApplicationController", strong_params: params } })

      text = described_class.call(controller: "SController").content.first[:text]

      expect(text).to include("permits: prefs: { theme: [], extra: {} }")
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
    # A bare count is not the answer either: it names nothing, and a second
    # such group in the same document repeats it.
    it "heads a group of top-level controllers with a member and a count" do
      entry = { actions: %w[show], filters: [], strong_params: [], parent_class: "ActionController::Base" }
      stub_controllers({
        "CustomCssController" => entry.dup,
        "HealthController" => entry.dup,
        "ManifestsController" => entry.dup
      })

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).not_to include("CustomCssController::*")
      expect(text).to include("## CustomCssController and 2 like it (3 controllers)")
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

    # The static walk records the superclass as written, so two namespaces
    # that each define their own BaseController arrive spelled the same. The
    # group key read that raw spelling while the rendered filter chain
    # resolved it, so unrelated controllers shared one group and were given a
    # chain that is not theirs.
    it "groups by the parent the chain walk resolves, not the source spelling" do
      member = { actions: %w[index], filters: [], strong_params: [], parent_class: "BaseController" }
      stub_controllers({
        "Admin::BaseController" => {
          actions: [], strong_params: [], parent_class: "ApplicationController",
          filters: [ { kind: "before", name: "set_referrer_policy_header" } ]
        },
        "Settings::BaseController" => {
          actions: [], strong_params: [], parent_class: "ApplicationController",
          filters: [ { kind: "before", name: "authenticate_user!" } ]
        },
        "Admin::DashboardController" => member.dup,
        "Settings::Exports::BookmarksController" => member.dup,
        "Settings::Exports::ListsController" => member.dup,
        "Settings::Exports::MutedAccountsController" => member.dup
      })

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("- Inherits: Settings::BaseController")
      expect(text).not_to include("- Inherits: BaseController")
      expect(text).to include("## Admin::DashboardController")
      expect(text).not_to include("- Members: Admin::DashboardController")
      expect(text).to include("- Filters: before authenticate_user!")
    end

    # The listing resolves the parent and the single-controller answer read
    # the raw spelling, so one tool named two parents for one controller.
    it "heads both answers with the same parent for one controller" do
      member = { actions: %w[index], filters: [], strong_params: [], parent_class: "BaseController" }
      stub_controllers({
        "Settings::BaseController" => {
          actions: [], strong_params: [], parent_class: "ApplicationController",
          filters: [ { kind: "before", name: "authenticate_user!" } ]
        },
        "Settings::Exports::BookmarksController" => member.dup,
        "Settings::Exports::ListsController" => member.dup,
        "Settings::Exports::MutedAccountsController" => member.dup
      })

      listing = described_class.call(detail: "full").content.first[:text]
      single = described_class.call(controller: "Settings::Exports::BookmarksController").content.first[:text]

      expect(listing).to include("- Inherits: Settings::BaseController")
      expect(single).to include("**Parent:** `Settings::BaseController`")
    end

    it "heads a compact controller with the top-level parent its nesting reads" do
      stub_controllers({
        "BaseController" => { actions: [], filters: [], strong_params: [], parent_class: "ApplicationController" },
        "Api::BaseController" => { actions: [], filters: [], strong_params: [], parent_class: "ApplicationController" },
        "Api::UsersController" => {
          actions: %w[index], filters: [], strong_params: [], parent_class: "BaseController", parent_nesting: []
        }
      })

      single = described_class.call(controller: "Api::UsersController").content.first[:text]

      expect(single).to include("**Parent:** `BaseController`")
    end

    # Nothing in the payload can qualify a framework or gem base, and
    # inventing a namespace for it would be a guess.
    it "keeps the raw spelling of a parent no entry resolves" do
      stub_controllers({
        "Api::WidgetsController" => {
          actions: %w[index], filters: [], strong_params: [], parent_class: "ActionController::Metal"
        },
        "WidgetsController" => {
          actions: %w[index], filters: [], strong_params: [], parent_class: "Grape::API"
        }
      })

      namespaced = described_class.call(controller: "Api::WidgetsController").content.first[:text]
      plain = described_class.call(controller: "WidgetsController").content.first[:text]

      expect(namespaced).to include("**Parent:** `ActionController::Metal`")
      expect(plain).to include("**Parent:** `Grape::API`")
    end

    # A controller that defines no action of its own is an answer. Omitting
    # the line left a reader unable to tell it from a walk that did not look,
    # which is the reason the other listings say "(no public actions)".
    it "says a controller has no public actions in every detail level" do
      stub_controllers({
        "Admin::BaseController" => { actions: [], filters: [], strong_params: [], parent_class: "ApplicationController" }
      })

      standard = described_class.call(detail: "standard").content.first[:text]
      full = described_class.call(detail: "full").content.first[:text]
      single = described_class.call(controller: "Admin::BaseController").content.first[:text]

      expect(standard).to include("- **Admin::BaseController** - (no public actions)")
      expect(full).to include("- Actions: (no public actions)")
      expect(single).to include("## Actions\n(no public actions)")
    end

    # A skip's constraint decides whether the filter is struck through, so
    # two controllers whose skips differ only in the constraint must not
    # share a group and one rendered chain.
    it "tells a conditional skip apart from an outright one in the group key" do
      sibling = {
        actions: %w[index], strong_params: [], parent_class: "Api::BaseController",
        filters: [ { kind: "before", name: "require_user!", skipped: true } ]
      }
      stub_controllers({
        "Api::BaseController" => {
          actions: [], strong_params: [], parent_class: "ApplicationController",
          filters: [ { kind: "before", name: "require_user!" } ]
        },
        "Api::AController" => sibling.dup,
        "Api::BController" => sibling.dup,
        "Api::CController" => sibling.merge(
          filters: [ { kind: "before", name: "require_user!", skipped: true, unless: "public_fetch_mode?" } ]
        )
      })

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("## Api::CController")
      expect(text).to include("- Filters: before require_user! (skipped unless: public_fetch_mode?)")
      expect(text).not_to include("- Members: Api::AController, Api::BController, Api::CController")
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
          filters: [ { kind: "before", name: "require_functional!", declared: true } ],
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

    # The colon is what says the app named a method rather than writing an
    # expression, and callbacks and validations both print it.
    it "spells a symbol skip condition as the symbol it is" do
      stub_controllers({
        "ApplicationController" => {
          actions: [], strong_params: [],
          filters: [ { kind: "before", name: "require_functional!", declared: true } ]
        },
        "AccountsController" => {
          actions: %w[show], parent_class: "ApplicationController", strong_params: [],
          filters: [ { kind: "before", name: "require_functional!", skipped: true, unless: :limited_federation_mode? } ]
        }
      })

      single = described_class.call(controller: "AccountsController").content.first[:text]

      expect(single).to include("(skipped unless: :limited_federation_mode?)")
    end

    # The example above hands the tool a record written by hand, so the colon
    # it checks could come from the spec rather than from the reader. This one
    # builds the record the way the introspector does, out of source.
    it "spells a symbol skip condition as the symbol it is, reading the record off source" do
      source = <<~RUBY
        class AccountsController < ApplicationController
          skip_before_action :require_functional!, unless: :limited_federation_mode?
        end
      RUBY
      stub_controllers({
        "ApplicationController" => {
          actions: [], strong_params: [],
          filters: [ { kind: "before", name: "require_functional!", declared: true } ]
        },
        "AccountsController" => {
          actions: %w[show], parent_class: "ApplicationController", strong_params: [],
          filters: RailsAiContext::Introspectors::ControllerFilters.from_source(source)
        }
      })

      single = described_class.call(controller: "AccountsController").content.first[:text]

      expect(single).to include("(skipped unless: :limited_federation_mode?)")
      expect(single).not_to include("unless: limited_federation_mode?")
    end

    # An `if:` on a filter that runs was never printed, so a filter that runs
    # on some requests read as one that runs on every request.
    it "names the condition a declared filter runs under" do
      source = <<~RUBY
        class AccountsController < ApplicationController
          before_action :require_account_signature!, if: -> { request.format == :json }
          before_action :store_referrer, except: :raise_not_found, if: :devise_controller?
        end
      RUBY
      stub_controllers({
        "AccountsController" => {
          actions: %w[show raise_not_found], strong_params: [],
          filters: RailsAiContext::Introspectors::ControllerFilters.from_source(source)
        }
      })

      single = described_class.call(controller: "AccountsController").content.first[:text]

      expect(single).to include("**require_account_signature!** (if: -> { request.format == :json })")
      expect(single).to include("**store_referrer** (except: raise_not_found) (if: :devise_controller?)")
    end

    # A marker says nothing about when the skip applies; the line does.
    it "names a lambda skip condition with the line the file wrote" do
      stub_controllers({
        "ApplicationController" => {
          actions: [],
          filters: [ { kind: "around", name: "set_locale", declared: true } ],
          strong_params: []
        },
        "AccountsController" => {
          actions: %w[show],
          parent_class: "ApplicationController",
          filters: [
            { kind: "around", name: "set_locale", skipped: true,
              if: "-> { [:json, :rss].include?(request.format&.to_sym) }" }
          ],
          strong_params: []
        }
      })

      single = described_class.call(controller: "AccountsController").content.first[:text]

      expect(single).to include("(skipped if: -> { [:json, :rss].include?(request.format&.to_sym) })")
      expect(single).not_to include("[INFERRED]")
    end

    it "keeps a filter a skip takes out only under an if around it, and names that if" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/controllers"))
        source = <<~RUBY
          class PostsController < ApplicationController
            skip_before_action :authenticate if Rails.env.development?
            def show; end
          end
        RUBY
        File.write(File.join(root, "app/controllers/posts_controller.rb"), source)
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))
        stub_controllers({
          "ApplicationController" => { actions: [], filters: [ { kind: "before", name: "authenticate", declared: true } ], strong_params: [] },
          "PostsController" => {
            actions: %w[show], parent_class: "ApplicationController", strong_params: [],
            file: "app/controllers/posts_controller.rb",
            filters: RailsAiContext::Introspectors::ControllerFilters.from_source(source)
          }
        })

        [ { controller: "PostsController" }, { controller: "PostsController", action: "show" } ].each do |args|
          text = described_class.call(**args).content.first[:text]

          expect(text).not_to include("~~authenticate~~")
          expect(text).to include("authenticate** _(from ApplicationController)_ (skipped `if Rails.env.development?`)")
        end
      end
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
          "ApplicationController" => { actions: [], filters: [ { kind: "before_action", name: "authenticate", declared: true } ] },
          "Admin::BaseController" => { actions: [], filters: [], parent_class: "ApplicationController" },
          "Admin::PostsController" => { actions: %w[index], filters: [], parent_class: "Admin::BaseController" }
        } }
      )

      text = described_class.call(controller: "Admin::PostsController").content.first[:text]

      expect(text).to include("_(from ApplicationController)_")
      expect(text).not_to include("_(from Admin::BaseController)_")
    end
  end

  # Every read of the shared cache is a deep copy of the whole payload, so a
  # listing that reads it once per controller pays for the app twice over.
  describe "shared context reads in the full listing" do
    def context_with(count)
      entries = (1...(count + 1)).to_h do |i|
        [ "Admin::Group#{i}Controller", {
          actions: %w[index show], filters: [], strong_params: [],
          parent_class: "Admin::BaseController"
        } ]
      end
      entries["Admin::BaseController"] = { actions: [], filters: [], parent_class: "ApplicationController" }
      { controllers: { controllers: entries } }
    end

    def reads_for(count)
      described_class.reset_cache!
      reads = 0
      ctx = context_with(count)
      allow(described_class).to receive(:cached_context) do
        reads += 1
        ctx
      end
      described_class.call(detail: "full", limit: 400)
      reads
    end

    it "reads the shared context the same number of times for 3 controllers as for 40" do
      expect(reads_for(40)).to eq(reads_for(3))
    end
  end

  # One controller is one invocation, not a loop, but the reads were still one
  # per fact rendered, so a controller with a parent and a source file paid
  # more than a bare one.
  describe "shared context reads for a single controller" do
    def reads_for(entries, name)
      described_class.reset_cache!
      reads = 0
      ctx = { controllers: { controllers: entries } }
      allow(described_class).to receive(:cached_context) do
        reads += 1
        ctx
      end
      described_class.call(controller: name)
      reads
    end

    it "reads the shared context as many times for a bare controller as for one with a parent" do
      bare = { "BareController" => { actions: %w[index], filters: [] } }
      rich = {
        "RichController" => {
          actions: %w[index], parent_class: "Admin::BaseController",
          filters: [ { kind: "before", name: "authenticate!" } ],
          file: "app/controllers/rich_controller.rb"
        },
        "Admin::BaseController" => { actions: [], filters: [] }
      }

      expect(reads_for(rich, "RichController")).to eq(reads_for(bare, "BareController"))
    end
  end

  describe "the render map's enqueue side effects" do
    before do
      allow(described_class).to receive(:cached_context)
        .and_return(jobs: { enqueue_helpers: [ { owner: "Jobs", method: "enqueue", job_arg: 0 } ] })
    end

    it "names every enqueue call, a scheduled one and the app's helper included" do
      code = <<~RUBY
        def create
          # AuditJob.perform_later
          RefreshWorker.perform_in(5.minutes, 1)
          Jobs.enqueue(:process_post)
          NotifyJob.set(wait: 1.hour).perform_later
        end
      RUBY

      expect(described_class.send(:extract_render_map, code)[:side_effects]).to eq(
        [ "RefreshWorker.perform_in", "Jobs.enqueue", "NotifyJob.set(wait: 1.hour).perform_later" ]
      )
    end
  end
end
