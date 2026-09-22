# frozen_string_literal: true

require "spec_helper"
require "shellwords"

RSpec.describe RailsAiContext::ActionFilters do
  # The gem is required on its own by the standalone binary and by any
  # consumer outside a booted app, so no entry point may reach for `Rails`
  # before a payload asks for a file.
  it "answers without a Rails constant in the process" do
    root = File.expand_path("../../..", __dir__)
    script = [
      "$LOAD_PATH.unshift #{File.join(root, 'lib').inspect}",
      'require "rails_ai_context"',
      'puts RailsAiContext::ActionFilters.for({}, "Nope", :show).inspect'
    ].join("\n")

    output = `ruby -e #{script.shellescape} 2>&1`

    expect(output).to include("{own: [], inherited: [], skipped: []}").or include("{:own=>[], :inherited=>[], :skipped=>[]}")
    expect($?.exitstatus).to eq(0)
  end

  let(:context) do
    { controllers: { controllers: {
      "ApplicationController" => { filters: [ { kind: "before_action", name: "authenticate" } ], file: "app/controllers/application_controller.rb" },
      "PostsController" => {
        parent_class: "ApplicationController",
        filters: [
          { kind: "before_action", name: "authenticate" },
          { kind: "before_action", name: "set_post", only: %w[show edit] },
          { kind: "after_action", name: "track", except: %w[index] }
        ],
        file: "app/controllers/posts_controller.rb"
      }
    } } }
  end

  # Every example below hands the walk a payload holding ApplicationController.
  # The real one never does - the listing leaves it out because it would sit in
  # every chain - so the walk ended on the first hop for most of an app's
  # controllers, while the generated files read the same file directly and
  # printed its filters. One run, two answers.
  describe "the base controller the listing leaves out" do
    def app_with_base(dir)
      FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "routes.rb"),
                 "Rails.application.routes.draw do\n  resources :pages\nend\n")
      File.write(File.join(dir, "app", "controllers", "application_controller.rb"), <<~RUBY)
        class ApplicationController < ActionController::Base
          before_action :authenticate_user!
          before_action :set_locale
          before_action :set_tenant, only: [ :show ]
        end
      RUBY
      File.write(File.join(dir, "app", "controllers", "pages_controller.rb"), <<~RUBY)
        class PagesController < ApplicationController
          def index; end
          def show; end
        end
      RUBY
    end

    def static_context(dir)
      previous = RailsAiContext.tier
      RailsAiContext.tier = :static
      RailsAiContext::Introspector.new(RailsAiContext::StaticApp.new(dir)).call
    ensure
      RailsAiContext.tier = previous
    end

    it "carries its filters into a child's chain" do
      Dir.mktmpdir do |dir|
        app_with_base(dir)
        ctx = static_context(dir)

        expect(RailsAiContext::Payload.controllers(ctx)).not_to have_key("ApplicationController")

        chain = described_class.for_controller(ctx, "PagesController", root: dir)
        expect(chain[:inherited].map { |f| f[:name] }).to eq(%w[authenticate_user! set_locale set_tenant])
        expect(chain[:inherited].map { |f| f[:from] }.uniq).to eq([ "ApplicationController" ])
      end
    end

    # A filter the class's own body declares is its own, whatever an ancestor
    # declares as well. The static list is the class's own declarations, so a
    # name in it that an ancestor also declares used to move to `inherited`
    # and the answer said the class declares nothing.
    it "keeps a filter the child declares itself in its own list" do
      Dir.mktmpdir do |dir|
        app_with_base(dir)
        File.write(File.join(dir, "app", "controllers", "posts_controller.rb"), <<~RUBY)
          class PostsController < ApplicationController
            before_action :authenticate_user!
            def index; end
          end
        RUBY
        ctx = static_context(dir)

        chain = described_class.for_controller(ctx, "PostsController", root: dir)

        expect(chain[:own].map { |f| f[:name] }).to eq([ "authenticate_user!" ])
        expect(chain[:inherited].map { |f| f[:name] }).to eq(%w[set_locale set_tenant])
      end
    end

    # A name is not a filter: `after_action :audit` and `before_action :audit`
    # are two entries in the chain, and Rails runs both. Keyed by name alone,
    # the child's `before` hid the base's `after` and took its attribution.
    it "keeps two filters that share a name and differ in kind" do
      Dir.mktmpdir do |dir|
        app_with_base(dir)
        File.write(File.join(dir, "app", "controllers", "application_controller.rb"), <<~RUBY)
          class ApplicationController < ActionController::Base
            before_action :authenticate_user!
            after_action :audit
          end
        RUBY
        File.write(File.join(dir, "app", "controllers", "widgets_controller.rb"), <<~RUBY)
          class WidgetsController < ApplicationController
            before_action :audit
            def index; end
          end
        RUBY
        ctx = static_context(dir)

        chain = described_class.for_controller(ctx, "WidgetsController", root: dir)

        expect(chain[:own].map { |f| [ f[:kind], f[:name] ] }).to eq([ [ "before", "audit" ] ])
        expect(chain[:inherited].map { |f| [ f[:kind], f[:name] ] })
          .to contain_exactly([ "before", "authenticate_user!" ], [ "after", "audit" ])
      end
    end

    it "applies its per-action constraints the way any other ancestor's are applied" do
      Dir.mktmpdir do |dir|
        app_with_base(dir)
        ctx = static_context(dir)

        index = described_class.for(ctx, "PagesController", "index", root: dir)
        show = described_class.for(ctx, "PagesController", "show", root: dir)

        expect(index[:inherited].map { |f| f[:name] }).to eq(%w[authenticate_user! set_locale])
        expect(show[:inherited].map { |f| f[:name] }).to eq(%w[authenticate_user! set_locale set_tenant])
      end
    end

    # The generated files print the same names off their own read of the same
    # file; they have to be one answer.
    it "names what the generated overview names" do
      Dir.mktmpdir do |dir|
        app_with_base(dir)
        ctx = static_context(dir)

        helper = Class.new do
          include RailsAiContext::Serializers::StackOverviewHelper
          def context = {}
        end.new
        chain = described_class.for_controller(ctx, "PagesController", root: dir)
        unconditional = chain[:inherited].reject { |f| f[:only] || f[:except] || f[:if] || f[:unless] }

        # Named, not only equal: both surfaces answering nothing is the shape
        # this example exists to catch.
        expect(helper.detect_before_actions(dir)).to eq(%w[authenticate_user! set_locale])
        expect(helper.detect_before_actions(dir)).to eq(unconditional.map { |f| f[:name] })
      end
    end

    # A parent the payload does not carry and the app has no file for still
    # ends the walk: reconstructing a path from a name breaks on an inflection.
    it "still ends the walk at a parent with no file of its own" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), "Rails.application.routes.draw do\nend\n")
        File.write(File.join(dir, "app", "controllers", "oauth_controller.rb"),
                   "class OauthController < Doorkeeper::ApplicationController\n  def index; end\nend\n")
        ctx = static_context(dir)

        chain = described_class.for_controller(ctx, "OauthController", root: dir)

        expect(chain[:inherited]).to be_empty
      end
    end
  end

  it "applies only and except to the action" do
    result = described_class.for(context, "PostsController", "show")
    expect(result[:own].map { |f| f[:name] }).to eq(%w[set_post track])
    expect(described_class.for(context, "PostsController", "index")[:own].map { |f| f[:name] }).to eq([])
  end

  it "reports the parent's filters as inherited, not own" do
    result = described_class.for(context, "PostsController", "show")
    expect(result[:inherited].map { |f| f[:name] }).to eq(%w[authenticate])
  end

  # An ancestor's own skip record joined the dropped set only after its own
  # filters had been selected, so the skip was reported as a filter the child
  # runs. Mastodon's Api::BaseController skips require_functional! and every
  # Api::V1 controller listed it as inherited.
  it "never reports an ancestor's skip as a filter the child runs" do
    ctx = { controllers: { controllers: {
      "ApplicationController" => { filters: [ { kind: "before", name: "require_functional!" } ] },
      "Api::BaseController" => {
        parent_class: "ApplicationController",
        filters: [ { kind: "before", name: "require_functional!", skipped: true } ]
      },
      "Api::V1::AccountsController" => { parent_class: "Api::BaseController", filters: [] }
    } } }

    result = described_class.for_controller(ctx, "Api::V1::AccountsController")

    expect(result[:inherited].map { |f| f[:name] }).to eq([])
    expect(result[:own]).to eq([])
  end

  # A skip record carries the skip's own only:/except:, so it covers those
  # actions only. Reading the flag without the constraint hid the filter
  # from every action of the class.
  describe "a skip record constrained to some actions" do
    let(:constrained_context) do
      { controllers: { controllers: {
        "AdminController" => { filters: [ { kind: "before", name: "authenticate_admin!", declared: true } ] },
        "ReportsController" => {
          parent_class: "AdminController",
          actions: %w[index show],
          filters: [ { kind: "before", name: "authenticate_admin!", skipped: true, only: %w[index] } ]
        }
      } } }
    end

    it "reports the filter skipped for an action the skip names" do
      result = described_class.for(constrained_context, "ReportsController", "index")

      expect(result[:skipped]).to eq(%w[authenticate_admin!])
      expect(result[:own]).to eq([])
      expect(result[:inherited]).to eq([])
    end

    it "still inherits the filter for an action the skip does not cover" do
      result = described_class.for(constrained_context, "ReportsController", "show")

      expect(result[:skipped]).to eq([])
      expect(result[:inherited].map { |f| [ f[:name], f[:from] ] })
        .to eq([ %w[authenticate_admin! AdminController] ])
    end

    # The whole-controller answer covers every action, and the filter runs on
    # all but the ones the skip names, so calling it skipped there
    # contradicted the same tool's per-action answer.
    it "keeps the filter in the whole-controller answer and names the actions it loses" do
      result = described_class.for_controller(constrained_context, "ReportsController")

      expect(result[:skipped]).to eq([])
      expect(result[:inherited].map { |f| [ f[:name], f[:skipped_on] ] })
        .to eq([ [ "authenticate_admin!", "index" ] ])
    end

    it "names the actions an except:-constrained skip leaves alone" do
      ctx = { controllers: { controllers: {
        "AdminController" => { filters: [ { kind: "before", name: "authenticate_admin!", declared: true } ] },
        "ReportsController" => {
          parent_class: "AdminController",
          filters: [ { kind: "before", name: "authenticate_admin!", skipped: true, except: %w[show] } ]
        }
      } } }

      result = described_class.for_controller(ctx, "ReportsController")

      expect(result[:skipped]).to eq([])
      expect(result[:inherited].map { |f| f[:skipped_except] }).to eq([ "show" ])
    end

    # A child never declared the skip, so the constrained skip must not take
    # the filter out of the child's chain either.
    it "carries a constrained skip down to a child that inherits it" do
      ctx = { controllers: { controllers: {
        "ApplicationController" => { filters: [ { kind: "before", name: "authenticate!" } ] },
        "Admin::BaseController" => {
          parent_class: "ApplicationController",
          filters: [ { kind: "before", name: "authenticate!", skipped: true, only: %w[index] } ]
        },
        "Admin::ReportsController" => { parent_class: "Admin::BaseController", filters: [] }
      } } }

      result = described_class.for_controller(ctx, "Admin::ReportsController")

      expect(result[:skipped]).to eq([])
      expect(result[:inherited].map { |f| [ f[:name], f[:skipped_on] ] })
        .to eq([ [ "authenticate!", "index" ] ])
    end
  end

  # The payload the CLI builds without booting, from real files, through the
  # introspector that sets the skip flag.
  describe "a constrained skip in a payload the static tier built" do
    it "keeps the filter for the action the skip leaves alone" do
      Dir.mktmpdir("action-filters-static") do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/controllers"))
        File.write(File.join(dir, "app/controllers/reports_controller.rb"), <<~RUBY)
          class ReportsController < ApplicationController
            before_action :authenticate_admin!
            skip_before_action :authenticate_admin!, only: [ :index ]

            def index; end

            def show; end
          end
        RUBY

        payload = RailsAiContext::Introspectors::ControllerIntrospector
          .new(RailsAiContext::StaticApp.new(dir)).static_call
        ctx = { controllers: payload }

        show = described_class.for(ctx, "ReportsController", "show", root: dir)
        index = described_class.for(ctx, "ReportsController", "index", root: dir)

        expect(show[:skipped]).to eq([])
        expect(show[:own].map { |f| f[:name] }).to eq(%w[authenticate_admin!])
        expect(index[:skipped]).to eq(%w[authenticate_admin!])
        expect(index[:own]).to eq([])

        whole = described_class.for_controller(ctx, "ReportsController", root: dir)
        expect(whole[:skipped]).to eq([])
        expect(whole[:own].map { |f| [ f[:name], f[:skipped_on] ] })
          .to eq([ [ "authenticate_admin!", "index" ] ])
      end
    end
  end

  # Every other example that reaches this module hands it a payload written
  # by hand, so a rename of a key the booted walk writes would pass. Real
  # constants, because `#call` rejects a class whose `name` is not the
  # constant it lives at, and an anonymous class would leave the payload
  # empty and the assertions vacuous.
  describe "a booted payload read back per action" do
    around do |example|
      Dir.mktmpdir("action-filters-composed") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/controllers/composed"))
        File.write(File.join(dir, "app/controllers/composed/app_controller.rb"), <<~RUBY)
          module Composed
            class AppController < ActionController::Base
              before_action :authenticate!
              before_action :set_locale
            end
          end
        RUBY
        File.write(File.join(dir, "app/controllers/composed/base_controller.rb"), <<~RUBY)
          module Composed
            class BaseController < Composed::AppController
              skip_before_action :authenticate!, only: [ :index ]
              skip_before_action :set_locale, unless: :html_request?
              before_action :require_admin
            end
          end
        RUBY
        File.write(File.join(dir, "app/controllers/composed/reports_controller.rb"), <<~RUBY)
          module Composed
            class ReportsController < Composed::BaseController
              before_action :load_report, except: :index

              def index; end

              def show; end
            end
          end
        RUBY
        Dir[File.join(dir, "app/controllers/composed/*.rb")].sort.each { |f| load f }
        example.run
        # The loaded classes stay in ActionController::Base.descendants, and so
        # in every later booted payload, until the constant is gone and they are
        # collected.
        Object.send(:remove_const, :Composed) if defined?(Composed)
        GC.start
      end
    end

    let(:composed_context) do
      app = Struct.new(:root).new(Pathname.new(@root))
      { controllers: RailsAiContext::Introspectors::ControllerIntrospector.new(app).call }
    end

    it "runs a constrained skip's filter on every action the skip leaves alone" do
      show = described_class.for(composed_context, "Composed::ReportsController", "show", root: @root)
      index = described_class.for(composed_context, "Composed::ReportsController", "index", root: @root)

      expect(show[:inherited].map { |f| f[:name] }).to include("authenticate!")
      expect(index[:inherited].map { |f| f[:name] }).not_to include("authenticate!")
      expect(index[:own].map { |f| f[:name] }).not_to include("authenticate!")
    end

    # `unless:` on a skip record is the one key of that seam no producer
    # example pins, so a rename of it drifts silently past both sides.
    it "keeps a conditionally skipped filter and names its condition" do
      show = described_class.for(composed_context, "Composed::ReportsController", "show", root: @root)

      set_locale = show[:inherited].find { |f| f[:name] == "set_locale" }
      expect(set_locale).not_to be_nil
      expect(set_locale[:skipped_unless]).to eq("html_request?")
    end
  end

  it "answers empty lists for an unknown controller" do
    expect(described_class.for(context, "Nope", "show")).to eq({ own: [], inherited: [], skipped: [] })
  end

  # An ancestor's skip joined the dropped set only after that ancestor's own
  # list had been collected, so the class that skips a filter still handed it
  # down. In the booted tier that list is the reflection list, which carries
  # every inherited name, so the skipping class itself contributed it.
  describe "an ancestor that skips a filter it also carries" do
    around do |example|
      Dir.mktmpdir("action-filters-own-skip") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/controllers/admin"))
        File.write(File.join(dir, "app/controllers/admin/base_controller.rb"), <<~RUBY)
          module Admin
            class BaseController < ApplicationController
              skip_before_action :authenticate!, only: [ :index ]
              before_action :require_admin
            end
          end
        RUBY
        example.run
      end
    end

    let(:skipping_context) do
      { controllers: { controllers: {
        "Admin::BaseController" => {
          parent_class: "ApplicationController",
          filters: [
            { kind: "before", name: "authenticate!" },
            { kind: "before", name: "require_admin" }
          ],
          file: "app/controllers/admin/base_controller.rb"
        },
        "Admin::ReportsController" => { parent_class: "Admin::BaseController", filters: [] }
      } } }
    end

    it "does not hand the filter to a child on an action the skip covers" do
      result = described_class.for(skipping_context, "Admin::ReportsController", "index", root: @root)

      expect(result[:inherited].map { |f| f[:name] }).to eq(%w[require_admin])
    end

    it "still hands it down on an action the skip leaves alone" do
      result = described_class.for(skipping_context, "Admin::ReportsController", "show", root: @root)

      expect(result[:inherited].map { |f| f[:name] }).to eq(%w[authenticate! require_admin])
    end

    # The booted tier gives every class the whole chain by reflection, so the
    # child's own list carries the name its parent skipped. Subtracting the
    # skip from the walk alone left it in the child's own filters.
    it "does not report it as the child's own filter either" do
      skipping_context[:controllers][:controllers]["Admin::ReportsController"][:filters] =
        [ { kind: "before", name: "authenticate!" }, { kind: "before", name: "require_admin" } ]

      result = described_class.for(skipping_context, "Admin::ReportsController", "index", root: @root)

      expect(result[:own].map { |f| f[:name] }).to eq([])
      expect(result[:inherited].map { |f| f[:name] }).to eq(%w[require_admin])
    end

    # A class that declares the filter again in its own body runs it, whatever
    # an ancestor skipped.
    it "keeps a filter the child declares itself" do
      skipping_context[:controllers][:controllers]["Admin::ReportsController"][:filters] =
        [ { kind: "before", name: "authenticate!", declared: true } ]

      result = described_class.for(skipping_context, "Admin::ReportsController", "index", root: @root)

      expect(result[:own].map { |f| f[:name] }).to eq(%w[authenticate!])
    end
  end

  # Ruby resolves a bare superclass from the enclosing namespace outward, so
  # `class ReportsController < BaseController` inside `module Admin` carries
  # the parent as written. Looking that up verbatim found nothing and the
  # whole inherited chain vanished from the answer.
  describe "a parent spelled relatively to its namespace" do
    let(:relative_context) do
      { controllers: { controllers: {
        "Admin::BaseController" => {
          parent_class: "ApplicationController",
          filters: [ { kind: "before", name: "require_admin", declared: true }, { kind: "after", name: "audit", declared: true } ]
        },
        "Admin::ReportsController" => {
          parent_class: "BaseController",
          filters: [ { kind: "before", name: "load_report", except: %w[index] } ]
        }
      } } }
    end

    it "resolves it against the enclosing namespace" do
      result = described_class.for_controller(relative_context, "Admin::ReportsController")

      expect(result[:inherited].map { |f| [ f[:name], f[:from] ] })
        .to eq([ %w[require_admin Admin::BaseController], %w[audit Admin::BaseController] ])
    end
  end

  describe ".for_controller" do
    it "keeps every declared filter, whatever action it constrains itself to" do
      result = described_class.for_controller(context, "PostsController")
      expect(result[:own].map { |f| f[:name] }).to eq(%w[set_post track])
      expect(result[:inherited].map { |f| f[:name] }).to eq(%w[authenticate])
    end

    it "answers empty lists for an unknown controller" do
      expect(described_class.for_controller(context, "Nope")).to eq({ own: [], inherited: [], skipped: [] })
    end
  end

  describe "source: keyword" do
    it "reads the skips from the source it is handed instead of the file" do
      source = "class PostsController\n  skip_before_action :authenticate\nend\n"
      result = described_class.for(context, "PostsController", "show", source: source)
      expect(result[:skipped]).to eq(%w[authenticate])
      expect(result[:inherited]).to eq([])
    end

    it "names a filter a skip lists as a string" do
      source = %(class PostsController\n  skip_before_action "authenticate"\nend\n)
      expect(described_class.for_controller(context, "PostsController", source: source)[:skipped]).to eq(%w[authenticate])
    end
  end

  context "skips read from the carried file" do
    around do |example|
      Dir.mktmpdir("action-filters") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/controllers"))
        File.write(File.join(dir, "app/controllers/posts_controller.rb"), <<~RUBY)
          class PostsController < ApplicationController
            skip_before_action :authenticate, :verify_token, only: %i[show]
            skip_after_action :track, except: %i[show]
          end
        RUBY
        example.run
      end
    end

    it "names every filter a skip lists, when the skip applies to the action" do
      expect(described_class.for(context, "PostsController", "show", root: @root)[:skipped]).to eq(%w[authenticate verify_token])
      expect(described_class.for(context, "PostsController", "index", root: @root)[:skipped]).to eq(%w[track])
    end

    it "drops a skipped filter from own and inherited" do
      result = described_class.for(context, "PostsController", "show", root: @root)
      expect(result[:inherited]).to eq([])
      expect(result[:own].map { |f| f[:name] }).to eq(%w[set_post track])
    end
  end

  # SourceScan carries the spelling the app uses, not the realpath, so a
  # symlinked pack's file is outside the root by realpath and only a reader
  # that trusts the carried path can open it.
  context "a controller in a pack symlinked out of the root" do
    it "reads the skips out of the carried file" do
      skip "symlinks unavailable" unless File.respond_to?(:symlink?)

      Dir.mktmpdir("outside-pack") do |outside|
        Dir.mktmpdir("pack-root") do |root|
          FileUtils.mkdir_p(File.join(outside, "billing", "app", "controllers"))
          File.write(File.join(outside, "billing", "app", "controllers", "billing_controller.rb"), <<~RUBY)
            class BillingController < ApplicationController
              skip_before_action :authenticate
            end
          RUBY
          File.symlink(outside, File.join(root, "packs"))

          ctx = { controllers: { controllers: {
            "ApplicationController" => { filters: [ { kind: "before_action", name: "authenticate" } ] },
            "BillingController" => {
              parent_class: "ApplicationController",
              filters: [],
              file: "packs/billing/app/controllers/billing_controller.rb"
            }
          } } }

          expect(described_class.for_controller(ctx, "BillingController", root: root)[:skipped]).to eq(%w[authenticate])
        end
      end
    end
  end

  # In the static tier each controller's list holds only its own
  # declarations, so a filter two levels up is reached only by walking.
  describe "an ancestor chain deeper than one level" do
    let(:deep_context) do
      { controllers: { controllers: {
        "ApplicationController" => { filters: [ { kind: "before_action", name: "authenticate", declared: true } ] },
        "Admin::BaseController" => {
          parent_class: "ApplicationController",
          filters: [ { kind: "before_action", name: "require_admin", declared: true } ]
        },
        "Admin::PostsController" => { parent_class: "Admin::BaseController", filters: [] }
      } } }
    end

    it "carries the grandparent's filter into inherited" do
      result = described_class.for_controller(deep_context, "Admin::PostsController")

      expect(result[:inherited].map { |f| f[:name] }).to eq(%w[authenticate require_admin])
    end

    # Re-declaring a filter moves it to the end of the chain, the way
    # `set_callback` does: the closer class's position is the one it runs at.
    it "lists a filter the closer ancestor redeclares once, at the closer position" do
      deep_context[:controllers][:controllers]["Admin::BaseController"][:filters] <<
        { kind: "before_action", name: "authenticate", only: %w[index], declared: true }

      names = described_class.for_controller(deep_context, "Admin::PostsController")[:inherited].map { |f| f[:name] }
      expect(names.count("authenticate")).to eq(1)
      expect(names).to eq(%w[require_admin authenticate])
    end

    # Rails runs the root's callbacks first: authentication after the current
    # user is loaded reads as the wrong order to an agent reading the chain.
    it "emits the inherited list in the order Rails runs it" do
      result = described_class.for_controller(deep_context, "Admin::PostsController")

      expect(result[:inherited].map { |f| f[:name] }).to eq(%w[authenticate require_admin])
    end

    # sentry-rails and paper_trail add callbacks from an
    # `on_load :action_controller` block. The reflection list of the nearest
    # ancestor carries them, no app class declares them, and naming that
    # ancestor sent an agent to a file that never mentions the callback.
    it "names no class for a filter no ancestor's body declares" do
      deep_context[:controllers][:controllers]["Admin::BaseController"][:filters] <<
        { kind: "around", name: "sentry_around_action" }

      entry = described_class.for_controller(deep_context, "Admin::PostsController")[:inherited]
        .find { |f| f[:name] == "sentry_around_action" }

      expect(entry).not_to have_key(:from)
      expect(entry[:provenance]).to eq("not declared in the controller chain")
    end

    # Reflection hands every class the whole chain, so the gem callback is on
    # the child's own list too. The child's copy used to win and arrive with
    # neither an attribution nor the label that explains its absence.
    it "carries the label through to the booted tier's own copy" do
      chain = [ { kind: "around", name: "sentry_around_action" },
                { kind: "before", name: "authenticate" } ]
      ctx = { controllers: { controllers: {
        "ApplicationController" => { filters: [ chain.first, chain.last.merge(declared: true) ] },
        "Admin::PostsController" => { parent_class: "ApplicationController", filters: chain }
      } } }

      entry = described_class.for_controller(ctx, "Admin::PostsController")[:inherited]
        .find { |f| f[:name] == "sentry_around_action" }

      expect(entry).not_to have_key(:from)
      expect(entry[:provenance]).to eq("not declared in the controller chain")
    end

    # A controller whose file the walk cannot read - an engine's, a gem's -
    # marks nothing as declared. That is "unknown", not "a gem installed it",
    # and dropping the attribution there loses the answer.
    it "keeps the attribution when no ancestor's body could be read" do
      ctx = { controllers: { controllers: {
        "ApplicationController" => { filters: [ { kind: "before", name: "authenticate" } ] },
        "Admin::PostsController" => { parent_class: "ApplicationController",
                                      filters: [ { kind: "before", name: "authenticate" } ] }
      } } }

      entry = described_class.for_controller(ctx, "Admin::PostsController")[:inherited].first

      expect(entry[:from]).to eq("ApplicationController")
      expect(entry).not_to have_key(:provenance)
    end

    it "stops at the first ancestor the payload does not carry" do
      deep_context[:controllers][:controllers].delete("ApplicationController")

      expect(described_class.for_controller(deep_context, "Admin::PostsController")[:inherited].map { |f| f[:name] })
        .to eq(%w[require_admin])
    end

    it "names the ancestor each inherited filter was found on" do
      result = described_class.for_controller(deep_context, "Admin::PostsController")

      expect(result[:inherited].map { |f| [ f[:name], f[:from] ] })
        .to eq([ %w[authenticate ApplicationController], %w[require_admin Admin::BaseController] ])
    end

    # A booted ancestor's list carries every inherited name, so the nearest
    # entry holding a filter is not the one that declared it. The record the
    # class declared in its own body says which.
    it "names the ancestor that declared it over one that only carries it" do
      deep_context[:controllers][:controllers]["ApplicationController"][:filters] =
        [ { kind: "before_action", name: "authenticate", declared: true } ]
      deep_context[:controllers][:controllers]["Admin::BaseController"][:filters] =
        [ { kind: "before_action", name: "authenticate" },
          { kind: "before_action", name: "require_admin", declared: true } ]

      result = described_class.for_controller(deep_context, "Admin::PostsController")

      expect(result[:inherited].map { |f| [ f[:name], f[:from] ] })
        .to eq([ %w[authenticate ApplicationController], %w[require_admin Admin::BaseController] ])
    end

    # A skip in a class between the child and the declaring ancestor stops
    # the filter as surely as one in the child's own body.
    context "when an intermediate ancestor skips the grandparent's filter" do
      around do |example|
        Dir.mktmpdir("action-filters-chain") do |dir|
          @root = dir
          FileUtils.mkdir_p(File.join(dir, "app/controllers/admin"))
          File.write(File.join(dir, "app/controllers/admin/base_controller.rb"), <<~RUBY)
            class Admin::BaseController < ApplicationController
              skip_before_action :authenticate
            end
          RUBY
          example.run
        end
      end

      before do
        deep_context[:controllers][:controllers]["Admin::BaseController"][:file] =
          "app/controllers/admin/base_controller.rb"
      end

      it "does not carry it into the child's inherited list" do
        result = described_class.for_controller(deep_context, "Admin::PostsController", root: @root)

        expect(result[:inherited].map { |f| f[:name] }).to eq(%w[require_admin])
      end
    end
  end

  # Rails removes the callback at the skip and re-adds it at the next line, so
  # the later record decides. Reporting the name as skipped said an auth
  # filter does not run on an action where it does.
  describe "a class body that skips a filter and then declares it again" do
    around do |example|
      Dir.mktmpdir("action-filters-redeclare") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/controllers"))
        File.write(File.join(dir, "app/controllers/public_controller.rb"), <<~RUBY)
          class PublicController < ApplicationController
            skip_before_action :authenticate_user!
            before_action :authenticate_user!, only: [ :admin ]

            def index; end
            def admin; end
          end
        RUBY
        example.run
      end
    end

    let(:redeclare_context) do
      { controllers: { controllers: {
        "PublicController" => {
          parent_class: "ApplicationController",
          filters: [
            { kind: "before", name: "authenticate_user!", skipped: true },
            { kind: "before", name: "authenticate_user!", only: %w[admin], declared: true }
          ],
          file: "app/controllers/public_controller.rb"
        },
        "ChildController" => { parent_class: "PublicController", filters: [] }
      } } }
    end

    it "runs the re-declared filter on the action it names" do
      result = described_class.for(redeclare_context, "PublicController", "admin", root: @root)

      expect(result[:own].map { |f| f[:name] }).to eq(%w[authenticate_user!])
      expect(result[:skipped]).to eq([])
    end

    it "still reports the skip on an action the re-declaration leaves out" do
      result = described_class.for(redeclare_context, "PublicController", "index", root: @root)

      expect(result[:own]).to eq([])
      expect(result[:skipped]).to eq(%w[authenticate_user!])
    end

    it "hands the re-declared filter down to a child" do
      result = described_class.for(redeclare_context, "ChildController", "admin", root: @root)

      expect(result[:inherited].map { |f| [ f[:name], f[:from] ] })
        .to eq([ %w[authenticate_user! PublicController] ])
    end

    it "keeps a plain skip of a filter it never re-declares out of the child" do
      redeclare_context[:controllers][:controllers]["PublicController"][:filters] =
        [ { kind: "before", name: "authenticate_user!", skipped: true } ]

      result = described_class.for(redeclare_context, "ChildController", "admin")

      expect(result[:inherited]).to eq([])
    end
  end

  # `skip_before_action :x, unless: :y` takes the filter out on some requests
  # and leaves it on others, so striking it through claims more than the
  # source says.
  describe "a skip that carries a condition" do
    let(:conditional_context) do
      { controllers: { controllers: {
        "ApplicationController" => { filters: [ { kind: "before", name: "require_functional!" } ] },
        "AccountsController" => {
          parent_class: "ApplicationController",
          actions: %w[show],
          filters: [
            { kind: "before", name: "require_functional!", skipped: true, unless: "limited_federation_mode?" }
          ]
        }
      } } }
    end

    it "keeps the filter in the chain and says on what it is skipped" do
      result = described_class.for_controller(conditional_context, "AccountsController")

      expect(result[:skipped]).to eq([])
      inherited = result[:inherited].find { |f| f[:name] == "require_functional!" }
      expect(inherited).not_to be_nil
      expect(inherited[:skipped_unless]).to eq("limited_federation_mode?")
    end

    it "spells a lambda condition the way an inferred filter option is spelled" do
      ctx = { controllers: { controllers: {
        "ApplicationController" => { filters: [ { kind: "around", name: "set_locale" } ] },
        "AccountsController" => {
          parent_class: "ApplicationController",
          filters: [ { kind: "around", name: "set_locale", skipped: true, if: "-> { request.format == :json }" } ]
        }
      } } }

      result = described_class.for_controller(ctx, "AccountsController")

      expect(result[:skipped]).to eq([])
      expect(result[:inherited].first[:skipped_if]).to eq("[INFERRED]")
    end

    it "leaves an unconditional skip absolute" do
      ctx = { controllers: { controllers: {
        "ApplicationController" => { filters: [ { kind: "before", name: "require_functional!" } ] },
        "AccountsController" => {
          parent_class: "ApplicationController",
          filters: [ { kind: "before", name: "require_functional!", skipped: true } ]
        }
      } } }

      result = described_class.for_controller(ctx, "AccountsController")

      expect(result[:skipped]).to eq([ "require_functional!" ])
      expect(result[:inherited]).to eq([])
    end

    # A conditional skip on a shared base is inherited by every child, and
    # the child's answer has to carry the condition too.
    it "carries an ancestor's condition down to the child" do
      ctx = { controllers: { controllers: {
        "ApplicationController" => { filters: [ { kind: "before", name: "require_functional!" } ] },
        "Api::BaseController" => {
          parent_class: "ApplicationController",
          filters: [ { kind: "before", name: "require_functional!", skipped: true, unless: "limited_federation_mode?" } ]
        },
        "Api::V1::AccountsController" => { parent_class: "Api::BaseController", filters: [] }
      } } }

      result = described_class.for_controller(ctx, "Api::V1::AccountsController")

      expect(result[:skipped]).to eq([])
      expect(result[:inherited].map { |f| f[:skipped_unless] }).to eq([ "limited_federation_mode?" ])
    end

    # A concern declares the filter, so no controller entry carries it. A
    # conditional skip of a name is still evidence the chain runs it, and the
    # answer says nothing about where it was declared.
    it "keeps a conditional skip whose filter no entry declares" do
      ctx = { controllers: { controllers: {
        "Api::BaseController" => {
          filters: [ { kind: "before", name: "require_functional!", skipped: true, unless: "limited_federation_mode?" } ]
        },
        "Api::V1::AccountsController" => { parent_class: "Api::BaseController", filters: [] }
      } } }

      result = described_class.for_controller(ctx, "Api::V1::AccountsController")

      expect(result[:skipped]).to eq([])
      expect(result[:inherited]).to eq([
        { kind: "before", name: "require_functional!", skipped_unless: "limited_federation_mode?" }
      ])
    end
  end

  # A name missing from the placed list is not always a declaration the walk
  # could not see: the walk may have seen it and taken it out for this action.
  # Reporting it anyway put a filter that cannot run under "Applicable
  # Filters", with no ancestor named.
  describe "a conditional skip of a filter the chain does declare" do
    it "says nothing for an action the ancestor's own constraint excludes" do
      ctx = { controllers: { controllers: {
        "ApplicationController" => { filters: [ { kind: "before", name: "authenticate_user!", except: %w[index], declared: true } ] },
        "PostsController" => {
          parent_class: "ApplicationController",
          filters: [ { kind: "before", name: "authenticate_user!", skipped: true, if: "public_request?" } ]
        }
      } } }

      expect(described_class.for(ctx, "PostsController", "index"))
        .to eq({ own: [], inherited: [], skipped: [] })
      expect(described_class.for(ctx, "PostsController", "show")[:inherited].map { |f| f[:from] })
        .to eq([ "ApplicationController" ])
    end

    it "says nothing when the class itself constrains the filter away from this action" do
      ctx = { controllers: { controllers: {
        "PostsController" => {
          filters: [
            { kind: "before", name: "foo", only: %w[index] },
            { kind: "before", name: "foo", skipped: true, unless: "admin?" }
          ]
        }
      } } }

      expect(described_class.for(ctx, "PostsController", "show"))
        .to eq({ own: [], inherited: [], skipped: [] })
    end

    it "says nothing when an intermediate ancestor took the filter out outright" do
      ctx = { controllers: { controllers: {
        "BaseController" => { filters: [ { kind: "before", name: "foo" } ] },
        "MidController" => {
          parent_class: "BaseController",
          filters: [ { kind: "before", name: "foo", skipped: true } ]
        },
        "PostsController" => {
          parent_class: "MidController",
          filters: [ { kind: "before", name: "foo", skipped: true, unless: "admin?" } ]
        }
      } } }

      expect(described_class.for_controller(ctx, "PostsController"))
        .to eq({ own: [], inherited: [], skipped: [] })
    end
  end

  # ApplicationController is out of the payload by design, so a skip on the
  # base class is the only evidence the filter is there at all. The
  # whole-controller answer said "(skipped on: index)" and the per-action one
  # dropped the filter, so one tool contradicted itself on one tier.
  describe "a skip whose constraint leaves the queried action alone" do
    let(:evidence_context) do
      { controllers: { controllers: {
        "Admin::BaseController" => {
          parent_class: "ApplicationController",
          filters: [
            { kind: "before", name: "authenticate!", skipped: true, only: %w[index] },
            { kind: "before", name: "require_admin" }
          ]
        },
        "Admin::ReportsController" => { parent_class: "Admin::BaseController", filters: [] }
      } } }
    end

    it "keeps the filter in the per-action chain with no skipped tail" do
      result = described_class.for(evidence_context, "Admin::ReportsController", "show")

      expect(result[:skipped]).to eq([])
      expect(result[:inherited].map { |f| f[:name] }).to contain_exactly("require_admin", "authenticate!")
      authenticate = result[:inherited].find { |f| f[:name] == "authenticate!" }
      expect(authenticate.keys).not_to include(:skipped_on, :skipped_if, :skipped_unless, :skipped_except)
    end

    it "still names the actions the skip covers in the whole-controller answer" do
      result = described_class.for_controller(evidence_context, "Admin::ReportsController")

      expect(result[:inherited].map { |f| [ f[:name], f[:skipped_on] ] })
        .to contain_exactly([ "require_admin", nil ], [ "authenticate!", "index" ])
    end

    # The child's own skip says nothing about `show`, so the ancestor's
    # condition is still the answer for it.
    it "does not let it displace an ancestor's own condition" do
      ctx = { controllers: { controllers: {
        "Api::BaseController" => {
          filters: [ { kind: "before", name: "require_functional!", skipped: true, unless: "limited?" } ]
        },
        "Api::V1::AccountsController" => {
          parent_class: "Api::BaseController",
          filters: [ { kind: "before", name: "require_functional!", skipped: true, only: %w[index] } ]
        }
      } } }

      result = described_class.for(ctx, "Api::V1::AccountsController", "show")

      expect(result[:skipped]).to eq([])
      expect(result[:inherited].map { |f| [ f[:name], f[:skipped_unless] ] })
        .to eq([ [ "require_functional!", "limited?" ] ])
    end
  end

  it "keeps unplaced_conditional_skips off the public surface" do
    expect(described_class).not_to respond_to(:unplaced_conditional_skips)
  end
end
