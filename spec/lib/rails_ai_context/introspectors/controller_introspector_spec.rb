# frozen_string_literal: true

require "spec_helper"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::ControllerIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns a controllers hash" do
      expect(result).to have_key(:controllers)
      expect(result[:controllers]).to be_a(Hash)
    end

    it "discovers PostsController" do
      expect(result[:controllers]).to have_key("PostsController")
    end

    # A class that answers a name no constant carries stays in
    # ActionController::Base.descendants for the life of the process, and
    # keyed by that name it would overwrite the real controller's entry.
    it "ignores a descendant whose name is not the constant it lives at" do
      Class.new(ActionController::Base) do
        def self.name = "GhostsController"
      end

      expect(result[:controllers]).not_to have_key("GhostsController")
      expect(result[:controllers]["PostsController"][:parent_class]).to eq("ApplicationController")
    end

    # The consumers read :file through Payload in both tiers, so a booted app
    # that answered without it would send them all back to guessing the path.
    it "carries the file each controller was read from" do
      expect(result[:controllers]["PostsController"][:file]).to eq("app/controllers/posts_controller.rb")
    end

    it "extracts all CRUD actions from PostsController" do
      actions = result[:controllers]["PostsController"][:actions]
      expect(actions).to include("index", "show", "new", "create", "edit", "update", "destroy")
    end

    it "extracts filter with correct kind" do
      filters = result[:controllers]["PostsController"][:filters]
      set_post = filters.find { |f| f[:name] == "set_post" }
      expect(set_post).not_to be_nil
      expect(set_post[:kind]).to eq("before")
    end

    it "extracts parent class" do
      expect(result[:controllers]["PostsController"][:parent_class]).to eq("ApplicationController")
    end

    it "extracts strong params with permit details" do
      params = result[:controllers]["PostsController"][:strong_params]
      expect(params).to be_an(Array)
      expect(params.size).to eq(1)

      sp = params.first
      expect(sp[:name]).to eq("post_params")
      expect(sp[:requires]).to eq("post")
      expect(sp[:permits]).to contain_exactly("title", "body", "user_id")
    end

    it "extracts respond_to formats from respond_to blocks" do
      formats = result[:controllers]["PostsController"][:respond_to_formats]
      expect(formats).to contain_exactly("html", "json", "turbo_stream")
    end

    it "detects API controllers" do
      expect(result[:controllers]).to have_key("Api::V1::BaseController")
      api = result[:controllers]["Api::V1::BaseController"]
      expect(api[:api_controller]).to be true
      expect(api[:parent_class]).to include("API")
    end

    it "marks non-API controllers as not api_controller" do
      expect(result[:controllers]["PostsController"][:api_controller]).to be false
    end

    it "excludes ApplicationController" do
      expect(result[:controllers]).not_to have_key("ApplicationController")
    end

    it "extracts concerns array" do
      concerns = result[:controllers]["PostsController"][:concerns]
      expect(concerns).to be_an(Array)
    end

    it "returns turbo_stream_actions for PostsController" do
      turbo_actions = result[:controllers]["PostsController"][:turbo_stream_actions]
      expect(turbo_actions).to include("create")
    end

    context "with a controller that has rescue_from and rate_limit" do
      let(:fixture_ctrl) { File.join(Rails.root, "app/controllers/widgets_controller.rb") }

      before do
        File.write(fixture_ctrl, <<~RUBY)
          class WidgetsController < ApplicationController
            rescue_from ActiveRecord::RecordNotFound, with: :not_found
            rescue_from ActionController::ParameterMissing, with: :bad_request

            def index
              @widgets = []
            end

            private

            def not_found
              head :not_found
            end

            def bad_request
              head :bad_request
            end
          end
        RUBY
      end

      # A loaded controller stays in ActionController::Base.descendants,
      # and so in every later booted payload, until its constant is gone
      # and it is collected.
      after do
        FileUtils.rm_f(fixture_ctrl)
        Object.send(:remove_const, :WidgetsController) if defined?(WidgetsController)
        GC.start
      end

      it "extracts rescue_from declarations" do
        load fixture_ctrl
        rescue_from = result[:controllers]["WidgetsController"][:rescue_from]
        expect(rescue_from).to be_an(Array)
        not_found_entry = rescue_from.find { |r| r[:handler] == "not_found" }
        expect(not_found_entry).not_to be_nil
      end
    end

    context "with a controller that has rate_limit (source parsing)" do
      let(:fixture_ctrl) { File.join(Rails.root, "app/controllers/rate_limited_controller.rb") }

      before do
        # Write source file but do NOT load it - rate_limit is Rails 8+ only.
        # The introspector extracts rate_limit via source parsing, not reflection.
        File.write(fixture_ctrl, <<~RUBY)
          class RateLimitedController < ApplicationController
            rate_limit to: 10, within: 1.minute, only: :index
            rate_limit to: 100,
                       within: 1.hour, # the long window
                       by: -> { request.domain }, name: "long"

            def self.throttle = rate_limit(to: 1, within: 1.second)

            def index
              render plain: "ok"
            end
          end
        RUBY
      end

      after { FileUtils.rm_f(fixture_ctrl) }

      # `name:` exists so one controller can declare several limits (rate_limiting.rb).
      it "extracts every rate_limit the class body declares, a call split over lines whole" do
        expect(result[:controllers]["RateLimitedController"][:rate_limits]).to eq([
          { text: "to: 10, within: 1.minute, only: :index", to: 10, within: "1.minute", only: [ "index" ] },
          { text: 'to: 100, within: 1.hour, by: -> { request.domain }, name: "long"', to: 100, within: "1.hour", name: "long" }
        ])
      end
    end

    context "with a controller that has complex respond_to" do
      let(:fixture_ctrl) { File.join(Rails.root, "app/controllers/items_controller.rb") }

      before do
        File.write(fixture_ctrl, <<~RUBY)
          class ItemsController < ApplicationController
            def index
              @items = []
              respond_to do |format|
                if @items.empty?
                  format.html { render :empty }
                end
                format.json { render json: @items }
                format.xml { render xml: @items }
              end
            end
          end
        RUBY
      end

      after do
        FileUtils.rm_f(fixture_ctrl)
        Object.send(:remove_const, :ItemsController) if defined?(ItemsController)
        GC.start
      end

      it "extracts all formats including those after nested end" do
        # Force controller discovery by loading the class
        load fixture_ctrl
        formats = result[:controllers]["ItemsController"][:respond_to_formats]
        expect(formats).to contain_exactly("html", "json", "xml")
      end
    end
  end

  describe "permit list extraction" do
    let(:introspector) { described_class.new(Rails.application) }

    it "parses simple permit list" do
      source = <<~RUBY
        def post_params
          params.require(:post).permit(:title, :body)
        end
      RUBY
      result = introspector.send(:extract_strong_params, source).find { |h| h[:name] == "post_params" }
      expect(result[:name]).to eq("post_params")
      expect(result[:requires]).to eq("post")
      expect(result[:permits]).to contain_exactly("title", "body")
    end

    it "parses nested permit" do
      source = <<~RUBY
        def user_params
          params.require(:user).permit(:name, address: [:street, :city, :zip])
        end
      RUBY
      result = introspector.send(:extract_strong_params, source).find { |h| h[:name] == "user_params" }
      expect(result[:requires]).to eq("user")
      expect(result[:permits]).to eq([ "name" ])
      expect(result[:nested]).to eq({ "address" => %w[street city zip] })
    end

    it "parses array permit" do
      source = <<~RUBY
        def post_params
          params.require(:post).permit(:title, tag_ids: [])
        end
      RUBY
      result = introspector.send(:extract_strong_params, source).find { |h| h[:name] == "post_params" }
      expect(result[:permits]).to eq([ "title" ])
      expect(result[:arrays]).to eq([ "tag_ids" ])
    end

    it "parses multi-line permit call" do
      source = <<~RUBY
        def post_params
          params.require(:post).permit(
            :title,
            :body,
            :published
          )
        end
      RUBY
      result = introspector.send(:extract_strong_params, source).find { |h| h[:name] == "post_params" }
      expect(result[:permits]).to contain_exactly("title", "body", "published")
    end

    it "flags params.permit! as unrestricted" do
      source = <<~RUBY
        def post_params
          params.permit!
        end
      RUBY
      result = introspector.send(:extract_strong_params, source).find { |h| h[:name] == "post_params" }
      expect(result[:unrestricted]).to be true
    end

    it "parses params.expect with a keyword array" do
      source = <<~RUBY
        def article_params
          params.expect(article: [ :title, :body, :published ])
        end
      RUBY
      result = introspector.send(:extract_strong_params, source).find { |h| h[:name] == "article_params" }
      expect(result[:requires]).to eq("article")
      expect(result[:permits]).to contain_exactly("title", "body", "published")
    end

    it "parses params.expect with nested attributes" do
      source = <<~RUBY
        def user_params
          params.expect(user: [ :name, address: [ :street, :city ] ])
        end
      RUBY
      result = introspector.send(:extract_strong_params, source).find { |h| h[:name] == "user_params" }
      expect(result[:requires]).to eq("user")
      expect(result[:permits]).to eq([ "name" ])
      expect(result[:nested]).to eq({ "address" => %w[street city] })
    end

    it "parses params.expect with a doubly-wrapped array-of-hashes" do
      source = <<~RUBY
        def post_params
          params.expect(post: [ :title, comments: [ [ :body ] ] ])
        end
      RUBY
      result = introspector.send(:extract_strong_params, source).find { |h| h[:name] == "post_params" }
      expect(result[:requires]).to eq("post")
      expect(result[:permits]).to eq([ "title" ])
      expect(result[:nested]).to eq({ "comments" => [ "body" ] })
    end

    # `tags: []` permits an array of scalars, in expect as in permit.
    it "reads an empty list inside params.expect as an array of scalars" do
      source = "def user_params = params.expect(user: [:name, { preferences: [:color] }, tags: []])\n"

      result = introspector.send(:extract_strong_params, source).first

      expect(result).to eq(name: "user_params", requires: "user", permits: [ "name" ],
                           nested: { "preferences" => [ "color" ] }, arrays: [ "tags" ])
    end

    # A hash inside a nested list permits more keys under it, and `{}` permits any hash.
    it "keeps the arrays and hashes a nested list permits" do
      source = <<~RUBY
        def settings_params
          params.expect(settings: [ { filters: [ :module_id, { module_ids: [] }, { range: [ :from, :to ] } ] }, { colors: {} }, :hide ])
        end
      RUBY

      result = introspector.send(:extract_strong_params, source).first

      expect(result).to eq(name: "settings_params", requires: "settings", permits: [ "hide" ],
                           nested: { "filters" => [ "module_id", { "module_ids" => [] }, { "range" => %w[from to] } ] },
                           hashes: [ "colors" ])
    end

    it "keeps the arrays and hashes a nested permit list permits" do
      source = "def s_params = params.require(:s).permit(:hide, colors: {}, filters: [ :module_id, { module_ids: [] } ])\n"

      result = introspector.send(:extract_strong_params, source).first

      expect(result).to eq(name: "s_params", requires: "s", permits: [ "hide" ],
                           nested: { "filters" => [ "module_id", { "module_ids" => [] } ] }, hashes: [ "colors" ])
    end

    it "returns name only when method has no permit call" do
      source = <<~RUBY
        def post_params
          params[:post]
        end
      RUBY
      result = introspector.send(:extract_strong_params, source).find { |h| h[:name] == "post_params" }
      expect(result[:name]).to eq("post_params")
      expect(result).not_to have_key(:permits)
    end

    it "handles hash rocket nested syntax" do
      source = <<~RUBY
        def user_params
          params.require(:user).permit(:name, :address => [:street, :city])
        end
      RUBY
      result = introspector.send(:extract_strong_params, source).find { |h| h[:name] == "user_params" }
      expect(result[:nested]).to eq({ "address" => %w[street city] })
    end

    it "handles combined nested and array permits" do
      source = <<~RUBY
        def order_params
          params.require(:order).permit(:total, item_ids: [], address: [:line1, :line2])
        end
      RUBY
      result = introspector.send(:extract_strong_params, source).find { |h| h[:name] == "order_params" }
      expect(result[:permits]).to eq([ "total" ])
      expect(result[:arrays]).to eq([ "item_ids" ])
      expect(result[:nested]).to eq({ "address" => %w[line1 line2] })
    end
  end

  # Reflection that yields nothing but excluded names falls through to the
  # source parser, which is the same producer the static tier uses.
  describe "excluded_filters on the booted source fallback" do
    it "does not hand back the names reflection already dropped" do
      allow(RailsAiContext.configuration).to receive(:excluded_filters).and_return(%w[set_post])
      ctrl = Class.new(ActionController::Base) do
        before_action :set_post
      end
      source = <<~RUBY
        class PostsController < ApplicationController
          before_action :set_post

          def show; end
        end
      RUBY

      expect(introspector.send(:extract_filters, ctrl, source)).to eq([])
    end
  end

  # Folding skip_before_action into a plain "before" kind lost the skip, and
  # the listing then printed the filter as one the action runs.
  describe "a skipped filter in source" do
    it "keeps the skip on the record" do
      source = <<~RUBY
        class InboxesController < ApplicationController
          skip_before_action :authenticate_user!
          before_action :require_actor_signature!
        end
      RUBY

      filters = introspector.send(:extract_filters_from_source, source)

      expect(filters).to include(a_hash_including(name: "authenticate_user!", kind: "before", skipped: true))
      expect(filters.find { |f| f[:name] == "require_actor_signature!" }).not_to have_key(:skipped)
    end
  end

  # A skip states what does not run, so its only:/except: is the opposite of
  # the filter's own. Copying it onto the reflection record inverted the
  # per-action answer: an authentication filter was named on the one action
  # where the skip applies and dropped from every action where it runs.
  describe "a class whose body skips an inherited filter for some actions" do
    let(:base_source) do
      <<~RUBY
        module Admin
          class BaseController < ApplicationController
            skip_before_action :authenticate!, only: [ :index ]
            before_action :require_admin
            after_action :audit
          end
        end
      RUBY
    end

    let(:reports_source) do
      <<~RUBY
        module Admin
          class ReportsController < BaseController
            before_action :load_report, except: :index
            skip_before_action :set_locale

            def index; end
            def show; end
          end
        end
      RUBY
    end

    # Named after construction: the inherited hook resolves a helper module
    # from the class name, and these names carry no constant.
    def build_chain
      app_ctrl = Class.new(ActionController::Base) do
        before_action :authenticate!
        before_action :set_locale
      end
      base = Class.new(app_ctrl) do
        skip_before_action :authenticate!, only: [ :index ]
        before_action :require_admin
        after_action :audit
      end
      reports = Class.new(base) do
        before_action :load_report, except: :index
        skip_before_action :set_locale
      end
      app_ctrl.define_singleton_method(:name) { "ApplicationController" }
      base.define_singleton_method(:name) { "Admin::BaseController" }
      reports.define_singleton_method(:name) { "Admin::ReportsController" }
      [ app_ctrl, base, reports ]
    end

    before do
      sources = {
        "ApplicationController" => "class ApplicationController < ActionController::Base\n" \
                                   "  before_action :authenticate!\n  before_action :set_locale\nend\n",
        "Admin::BaseController" => base_source,
        "Admin::ReportsController" => reports_source
      }
      allow(introspector).to receive(:read_source) { |k| sources[k.name] }
    end

    it "does not give the filter the skip's own constraint" do
      _app, base, = build_chain

      authenticate = introspector.send(:extract_filters, base, base_source).find { |f| f[:name] == "authenticate!" }

      expect(authenticate).not_to have_key(:only)
      expect(authenticate).not_to have_key(:except)
    end

    it "marks the records the class declares in its own body" do
      _app, base, = build_chain

      filters = introspector.send(:extract_filters, base, base_source)

      expect(filters.find { |f| f[:name] == "require_admin" }[:declared]).to be(true)
      expect(filters.find { |f| f[:name] == "set_locale" }).not_to have_key(:declared)
    end

    it "carries the class's own skip records the way the static tier does" do
      _app, base, reports = build_chain

      expect(introspector.send(:extract_filters, base, base_source))
        .to include(a_hash_including(name: "authenticate!", skipped: true, only: %w[index]))
      expect(introspector.send(:extract_filters, reports, reports_source))
        .to include(a_hash_including(name: "set_locale", skipped: true))
    end

    # A skip and a later re-declaration of the same name are decided by the
    # order the body wrote them, which the callback chain does not preserve.
    it "keeps a re-declared filter after the skip it undoes" do
      ctrl = Class.new(ActionController::Base) do
        before_action :authenticate!
      end
      child = Class.new(ctrl) do
        skip_before_action :authenticate!
        before_action :authenticate!, only: [ :admin ]
      end
      ctrl.define_singleton_method(:name) { "ApplicationController" }
      child.define_singleton_method(:name) { "PublicController" }
      source = <<~RUBY
        class PublicController < ApplicationController
          skip_before_action :authenticate!
          before_action :authenticate!, only: [ :admin ]
        end
      RUBY
      allow(introspector).to receive(:read_source) { |k| k == child ? source : nil }

      records = introspector.send(:extract_filters, child, source).select { |f| f[:name] == "authenticate!" }

      expect(records.map { |f| f[:skipped] }).to eq([ true, nil ])
      expect(records.last[:only]).to eq(%w[admin])
    end

    # A compiled callback keeps its condition in a Proc, so the booted tier
    # reads conditions from the class body the way the static tier does. The
    # two tiers answering one line differently is the failure to prevent.
    it "names a lambda filter condition the way the static tier names it" do
      ctrl = Class.new(ActionController::Base) do
        before_action :require_signature, if: -> { request.format == :json }
      end
      ctrl.define_singleton_method(:name) { "StatusesController" }
      source = <<~RUBY
        class StatusesController < ActionController::Base
          before_action :require_signature, if: -> { request.format == :json }
        end
      RUBY
      allow(introspector).to receive(:read_source) { |k| k == ctrl ? source : nil }

      booted = introspector.send(:extract_filters, ctrl, source).find { |f| f[:name] == "require_signature" }
      static = introspector.send(:extract_filters_from_source, source).find { |f| f[:name] == "require_signature" }

      expect(booted[:if]).to eq("-> { request.format == :json }")
      expect(static[:if]).to eq(booted[:if])
    end

    # Rebuilding the list put every name the body declares behind every name
    # it only inherits, so a prepended filter was reported last, and only
    # when the body also carried a skip. The routes hint shows the first
    # three, so the prepend was the one cut.
    it "keeps the chain's order whether or not the body carries a skip" do
      ctrl = Class.new(ActionController::Base) do
        before_action :audit
        before_action :load_thing
      end
      child = Class.new(ctrl) do
        prepend_before_action :set_locale
        skip_before_action :require_login, raise: false
      end
      ctrl.define_singleton_method(:name) { "ApplicationController" }
      child.define_singleton_method(:name) { "PostsController" }
      with_skip = <<~RUBY
        class PostsController < ApplicationController
          prepend_before_action :set_locale
          skip_before_action :require_login, raise: false
        end
      RUBY
      without_skip = with_skip.lines.reject { |l| l.include?("skip_before_action") }.join

      names = ->(source) { introspector.send(:extract_filters, child, source).map { |f| f[:name] } }

      expect(child._process_action_callbacks.map(&:filter)).to eq(%i[set_locale audit load_thing])
      expect(names.call(without_skip)).to eq(%w[set_locale audit load_thing])
      expect(names.call(with_skip)).to eq(%w[set_locale audit load_thing require_login])
    end

    # A body that skips a name and then declares it again writes the skip
    # first, and the pair has to read in that order for the skip to be
    # recognised as undone.
    it "puts a skip ahead of the re-declaration the body writes after it" do
      ctrl = Class.new(ActionController::Base) do
        before_action :authenticate!
        before_action :audit
      end
      child = Class.new(ctrl) do
        skip_before_action :authenticate!
        before_action :authenticate!, only: [ :admin ]
      end
      ctrl.define_singleton_method(:name) { "ApplicationController" }
      child.define_singleton_method(:name) { "PublicController" }
      source = <<~RUBY
        class PublicController < ApplicationController
          skip_before_action :authenticate!
          before_action :authenticate!, only: [ :admin ]
        end
      RUBY

      records = introspector.send(:extract_filters, child, source)

      expect(records.map { |f| [ f[:name], f[:skipped] ] })
        .to eq([ [ "audit", nil ], [ "authenticate!", true ], [ "authenticate!", nil ] ])
    end

    it "marks only the kind the body declares, not every entry of that name" do
      ctrl = Class.new(ActionController::Base) { after_action :audit_trail }
      child = Class.new(ctrl) { before_action :audit_trail }
      ctrl.define_singleton_method(:name) { "BaseController" }
      child.define_singleton_method(:name) { "CouponsController" }
      source = <<~RUBY
        class CouponsController < BaseController
          before_action :audit_trail
        end
      RUBY

      records = introspector.send(:extract_filters, child, source)

      expect(records.map { |f| [ f[:kind], f[:name], f[:declared] ] })
        .to contain_exactly([ "after", "audit_trail", nil ], [ "before", "audit_trail", true ])
    end

    it "credits a filter a concern the body includes to that concern" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/controllers/concerns"))
        File.write(File.join(dir, "app/controllers/concerns/help_tracked.rb"), <<~RUBY)
          module HelpTracked
            extend ActiveSupport::Concern
            included { before_action :track_help_visit }
          end
        RUBY
        ctrl = Class.new(ActionController::Base) { before_action :track_help_visit }
        ctrl.define_singleton_method(:name) { "HelpPagesController" }
        source = <<~RUBY
          class HelpPagesController < ApplicationController
            include HelpTracked
          end
        RUBY

        in_dir = described_class.new(double("app", root: Pathname.new(dir)))
        record = in_dir.send(:extract_filters, ctrl, source).find { |f| f[:name] == "track_help_visit" }

        expect(record).to include(declared: true, from_concern: "HelpTracked")
      end
    end

    # `bin/rails generate authentication`: reflection takes the filter out of the chain, and the
    # body's call of the concern's class method is the only thing that says what did.
    it "shows the skip a class method the body calls makes, when nothing else is left in the chain" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/controllers/concerns"))
        File.write(File.join(dir, "app/controllers/concerns/authentication.rb"), <<~RUBY)
          module Authentication
            extend ActiveSupport::Concern
            included { before_action :require_authentication }
            class_methods do
              def allow_unauthenticated_access(**options)
                skip_before_action :require_authentication, **options
              end
            end
          end
        RUBY
        File.write(File.join(dir, "app/controllers/application_controller.rb"),
                   "class ApplicationController < ActionController::Base\n  include Authentication\nend\n")
        base = Class.new(ActionController::Base) do
          before_action :require_authentication
          def self.allow_unauthenticated_access(**options) = skip_before_action(:require_authentication, **options)
        end
        child = Class.new(base) { allow_unauthenticated_access }
        base.define_singleton_method(:name) { "ApplicationController" }
        child.define_singleton_method(:name) { "PasswordsController" }
        source = "class PasswordsController < ApplicationController\n  allow_unauthenticated_access\nend\n"

        records = described_class.new(double("app", root: Pathname.new(dir))).send(:extract_filters, child, source)

        expect(child._process_action_callbacks.map(&:filter)).not_to include(:require_authentication)
        expect(records.map { |f| [ f[:name], f[:skipped] ] }).to eq([ [ "require_authentication", true ] ])
      end
    end

    # actionpack turns a block into a callback of its own; the static tier names it by its line.
    it "names a block filter the app wrote by its line, and leaves a framework block out" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "app/controllers/users_controller.rb")
        FileUtils.mkdir_p(File.dirname(path))
        source = <<~RUBY
          class UsersController < ApplicationController
            prepend_around_action :par
            before_action(only: :index) { |c| c.head(:forbidden) }
          end
        RUBY
        File.write(path, source)
        ctrl = Class.new(ActionController::Base) { before_action { head :ok } }
        ctrl.define_singleton_method(:name) { "UsersController" }
        ctrl.class_eval(source.lines[1..2].join, path, 2)
        in_dir = described_class.new(double("app", root: Pathname.new(dir)))

        booted = in_dir.send(:extract_filters, ctrl, source).map { |f| [ f[:kind], f[:name], f[:only] ] }
        static = in_dir.send(:extract_filters_from_source, source).map { |f| [ f[:kind], f[:name], f[:only] ] }

        expect(booted).to eq([ [ "around", "par", nil ], [ "before", "block (line 3)", [ "index" ] ] ])
        expect(static).to eq(booted)
      end
    end

    it "lists a call's lambdas and names in argument order, in both tiers" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "app/controllers/users_controller.rb")
        source = "class UsersController < ApplicationController\n  before_action -> { head :ok }, :a\nend\n"
        ctrl = Class.new(ActionController::Base)
        ctrl.define_singleton_method(:name) { "UsersController" }
        ctrl.class_eval(source.lines[1], path, 2)
        in_dir = described_class.new(double("app", root: Pathname.new(dir)))

        booted = in_dir.send(:extract_filters, ctrl, source).map { |f| f[:name] }

        expect(booted).to eq([ "block (line 2)", "a" ])
        expect(in_dir.send(:extract_filters_from_source, source).map { |f| f[:name] }).to eq(booted)
      end
    end

    it "leaves out a gem's block when the bundle is installed under the app root" do
      Dir.mktmpdir do |dir|
        gem_dir = File.join(dir, ".bundle/ruby/3.4.0/gems/actionpack-8.1.0")
        gem_block = eval("proc { }", binding, File.join(gem_dir, "lib/action_controller/metal/allow_browser.rb"), 58)
        app_block = eval("proc { }", binding, File.join(dir, "app/controllers/users_controller.rb"), 3)
        allow(Gem).to receive(:loaded_specs)
          .and_return("actionpack" => double(full_gem_path: gem_dir, source: Bundler::Source::Rubygems.allocate))
        in_dir = described_class.new(double("app", root: Pathname.new(dir)))

        expect(in_dir.send(:callback_name, gem_block)).to be_nil
        expect(in_dir.send(:callback_name, app_block)).to eq("block (line 3)")
      end
    end

    it "names cancancan's block callbacks for the macro that added them, as the static tier does" do
      gem_dir = "/gems/cancancan-3.6.1/lib/cancan"
      resource = eval("method = :load_and_authorize_resource; proc { |c| method }", binding, "#{gem_dir}/controller_resource.rb", 15)
      check = eval("options = {}; proc { |c| options }", binding, "#{gem_dir}/controller_additions.rb", 266)
      skip = eval("args = []; proc { |c| args }", binding, "#{gem_dir}/controller_additions.rb", 287)
      in_dir = described_class.new(double("app", root: Pathname.new(Dir.pwd)))

      expect(in_dir.send(:callback_name, resource)).to eq("load_and_authorize_resource")
      expect(in_dir.send(:callback_name, check)).to eq("check_authorization")
      expect(in_dir.send(:callback_name, skip)).to eq("skip_authorization_check")
    end

    it "names an object filter by its class, in both tiers, the same on every run" do
      stub_const("TimingFilter", Class.new { def around(_controller) = yield })
      stub_const("ClassFilter", Class.new { def self.before(_controller); end })
      source = <<~RUBY
        class WidgetsController < ApplicationController
          around_action TimingFilter.new, only: :index
          before_action ClassFilter, :plain_filter
        end
      RUBY
      ctrl = Class.new(ActionController::Base) do
        around_action TimingFilter.new, only: :index
        before_action ClassFilter, :plain_filter
      end
      ctrl.define_singleton_method(:name) { "WidgetsController" }

      booted = introspector.send(:extract_filters, ctrl, source).map { |f| [ f[:kind], f[:name], f[:only] ] }
      static = introspector.send(:extract_filters_from_source, source).map { |f| [ f[:kind], f[:name], f[:only] ] }

      expect(booted).to eq([ [ "around", "TimingFilter (object)", [ "index" ] ], [ "before", "ClassFilter", nil ],
                             [ "before", "plain_filter", nil ] ])
      expect(static).to eq(booted)
    end

    # http_authentication.rb: `before_action(options) { http_basic_authenticate_or_request_with ... }`.
    it "names the filter http_basic_authenticate_with adds, in both tiers, password left out" do
      source = <<~RUBY
        class ReportsController < ApplicationController
          http_basic_authenticate_with name: "admin", password: "secret", except: :index
        end
      RUBY
      ctrl = Class.new(ActionController::Base) { http_basic_authenticate_with name: "admin", password: "secret", except: :index }
      ctrl.define_singleton_method(:name) { "ReportsController" }

      booted = introspector.send(:extract_filters, ctrl, source)
      static = introspector.send(:extract_filters_from_source, source)

      expect(booted.map { |f| f.slice(:kind, :name, :except) })
        .to eq([ { kind: "before", name: "http_basic_authenticate_with", except: [ "index" ] } ])
      expect(static.map { |f| f.slice(:kind, :name, :except) }).to eq(booted.map { |f| f.slice(:kind, :name, :except) })
      expect((booted + static).inspect).not_to include("secret")
    end

    def with_concern(body)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/controllers/concerns"))
        File.write(File.join(dir, "app/controllers/concerns/auth.rb"), <<~RUBY)
          module Auth
            extend ActiveSupport::Concern
            included { #{body} }
          end
        RUBY
        yield described_class.new(double("app", root: Pathname.new(dir)))
      end
    end

    it "credits a filter the body re-declares after a concern's to the body" do
      with_concern("before_action :authenticate") do |in_dir|
        ctrl = Class.new(ActionController::Base) { before_action :authenticate, only: :show }
        ctrl.define_singleton_method(:name) { "PostsController" }
        source = <<~RUBY
          class PostsController < ApplicationController
            include Auth
            before_action :authenticate, only: :show
          end
        RUBY

        record = in_dir.send(:extract_filters, ctrl, source).find { |f| f[:name] == "authenticate" }

        expect(record).to include(declared: true, only: [ "show" ])
        expect(record).not_to have_key(:from_concern)
      end
    end

    it "carries a concern's only: onto the booted record" do
      with_concern("before_action :authenticate, only: :index") do |in_dir|
        ctrl = Class.new(ActionController::Base) { before_action :authenticate, only: :index }
        ctrl.define_singleton_method(:name) { "PostsController" }
        source = <<~RUBY
          class PostsController < ApplicationController
            include Auth
          end
        RUBY

        record = in_dir.send(:extract_filters, ctrl, source).find { |f| f[:name] == "authenticate" }

        expect(record).to include(only: [ "index" ], from_concern: "Auth")
      end
    end

    it "does not credit a concern the parent already includes to the child" do
      with_concern("before_action :authenticate") do |in_dir|
        stub_const("Auth", Module.new do
          extend ActiveSupport::Concern
          included { before_action :authenticate }
        end)
        parent = Class.new(ActionController::Base) { include Auth }
        ctrl = Class.new(parent) { include Auth }
        ctrl.define_singleton_method(:name) { "PostsController" }
        source = <<~RUBY
          class PostsController < ApplicationController
            include Auth
          end
        RUBY

        record = in_dir.send(:extract_filters, ctrl, source).find { |f| f[:name] == "authenticate" }

        expect(record).not_to have_key(:declared)
        expect(record).not_to have_key(:from_concern)
      end
    end

    it "credits a re-included plain module's filter to the child, whose include runs its hook again" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/controllers/concerns"))
        File.write(File.join(dir, "app/controllers/concerns/auth.rb"),
                   "module Auth\n  def self.included(base)\n    base.class_eval do\n      before_action :authenticate\n    end\n  end\nend\n")
        stub_const("Auth", Module.new do
          def self.included(base) = base.before_action(:authenticate)
        end)
        parent = Class.new(ActionController::Base) { include Auth }
        ctrl = Class.new(parent) { include Auth }
        ctrl.define_singleton_method(:name) { "PostsController" }
        source = "class PostsController < ApplicationController\n  include Auth\nend\n"

        record = described_class.new(double("app", root: Pathname.new(dir))).send(:extract_filters, ctrl, source)
                                .find { |f| f[:name] == "authenticate" }

        expect(record).to include(declared: true, from_concern: "Auth")
      end
    end
  end

  describe "booted parent nesting" do
    it "marks a namespaced controller's top-level parent so its namesake in the namespace is not read" do
      stub_const("NestBase", Class.new)
      stub_const("NestApi", Module.new)
      stub_const("NestApi::NestBase", Class.new)
      compact = stub_const("NestApi::CompactController", Class.new(NestBase))
      nested = stub_const("NestApi::NestedController", Class.new(NestApi::NestBase))

      expect(introspector.send(:booted_parent_nesting, compact)).to eq([])
      expect(introspector.send(:booted_parent_nesting, nested)).to be_nil
    end
  end

  describe "#static_call" do
    it "reads a compact controller's bare superclass from the top level" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "api"))
        File.write(File.join(dir, "app", "controllers", "base_controller.rb"),
                   "class BaseController < ApplicationController\n  before_action :authenticate_web\nend\n")
        File.write(File.join(dir, "app", "controllers", "api", "base_controller.rb"),
                   "module Api\n  class BaseController < ApplicationController\n    before_action :authenticate_token\n  end\nend\n")
        File.write(File.join(dir, "app", "controllers", "api", "users_controller.rb"),
                   "class Api::UsersController < BaseController\n  def index; end\nend\n")
        File.write(File.join(dir, "app", "controllers", "api", "orders_controller.rb"),
                   "module Api\n  class OrdersController < BaseController\n  end\nend\n")

        controllers = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:controllers]
        resolve = ->(name) { RailsAiContext::Introspectors::ActionResolver.resolve_entry_name(controllers, controllers[name][:parent_class], name) }

        expect(resolve.call("Api::UsersController")).to eq("BaseController")
        expect(resolve.call("Api::OrdersController")).to eq("Api::BaseController")
      end
    end

    it "names a controller that failed to load by its app-relative path" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "app", "controllers", "widgets_controller.rb"), "class WidgetsController; end\n")
        introspector = described_class.new(RailsAiContext::StaticApp.new(dir))
        allow(introspector).to receive(:extract_details_from_source)
          .and_raise(RuntimeError, "#{dir}/app/controllers/widgets_controller.rb:1: boom")

        error = introspector.static_call[:controllers]["WidgetsController"][:error]

        expect(error).to eq("app/controllers/widgets_controller.rb:1: boom")
      end
    end

    it "extracts controllers purely from source files" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "api"))
        File.write(File.join(dir, "app", "controllers", "widgets_controller.rb"), <<~RUBY)
          class WidgetsController < ApplicationController
            before_action :set_widget, only: [:show]

            def index; end

            def show; end

            private

            def set_widget; end
          end
        RUBY
        File.write(File.join(dir, "app", "controllers", "api", "pings_controller.rb"), <<~RUBY)
          class Api::PingsController < ActionController::API
            def show; end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        widgets = result[:controllers]["WidgetsController"]
        expect(widgets[:actions]).to eq(%w[index show])
        expect(widgets[:parent_class]).to eq("ApplicationController")
        expect(widgets[:confidence]).to eq("[STATIC]")
        expect(result[:controllers]["Api::PingsController"][:api_controller]).to be(true)
      end
    end

    # Every tool that needs a path for a controller reads `:file` through
    # Payload, because the name alone cannot carry it - the app's inflector
    # decides the directory.
    it "carries the file each controller was read from" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "activitypub"))
        File.write(File.join(dir, "app", "controllers", "activitypub", "inboxes_controller.rb"),
                   "class ActivityPub::InboxesController < ApplicationController\n  def create; end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:controllers]["ActivityPub::InboxesController"][:file])
          .to eq("app/controllers/activitypub/inboxes_controller.rb")
      end
    end

    # A file that was there and could not be read is not a controller the
    # app does not have; listing it is what tells the reader the difference.
    it "lists a controller file it could not read under its path name" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "app", "controllers", "huge_controller.rb"), "x" * 2_000)
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(100)

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:controllers]["HugeController"]).to eq({ error: "unreadable" })
      end
    end

    it "returns an empty controllers hash when the directory is missing" do
      Dir.mktmpdir do |dir|
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result[:controllers]).to eq({})
      end
    end

    # Reading the name from the source means the name no longer round-trips
    # back to the path: `ActivityPub::CollectionsController`.underscore is
    # `activity_pub/collections_controller`, and the file is under
    # `activitypub/`. Every consumer that wants the file must be handed it.
    it "carries the file each controller was read from" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "activitypub"))
        File.write(File.join(dir, "app", "controllers", "activitypub", "collections_controller.rb"), <<~RUBY)
          class ActivityPub::CollectionsController < ApplicationController
            def show; end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:controllers]["ActivityPub::CollectionsController"][:file])
          .to eq("app/controllers/activitypub/collections_controller.rb")
      end
    end

    # Zeitwerk resolves a path through the app's own inflections, so a
    # directory named `activitypub` is `ActivityPub` in an app that registers
    # that acronym - and camelizing the path alone invents `Activitypub`, a
    # constant Mastodon does not define anywhere in 818 references.
    it "names a controller from the constant its source declares" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "activitypub"))
        File.write(File.join(dir, "app", "controllers", "activitypub", "collections_controller.rb"), <<~RUBY)
          class ActivityPub::CollectionsController < ApplicationController
            def show; end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:controllers].keys).to contain_exactly("ActivityPub::CollectionsController")
      end
    end

    it "names a controller declared inside a module block" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "oauth"))
        File.write(File.join(dir, "app", "controllers", "oauth", "tokens_controller.rb"), <<~RUBY)
          module OAuth
            class TokensController < ApplicationController
              def create; end
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:controllers].keys).to contain_exactly("OAuth::TokensController")
      end
    end

    # The path is the only thing carrying the namespace when the source does
    # not, so it stays the answer there.
    it "falls back to the path when the source declares a bare name" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "admin"))
        File.write(File.join(dir, "app", "controllers", "admin", "widgets_controller.rb"), <<~RUBY)
          class WidgetsController < ApplicationController
            def index; end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:controllers].keys).to contain_exactly("Admin::WidgetsController")
      end
    end

    it "discovers controllers in packs and engines directories" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "controllers"))
        File.write(File.join(dir, "app", "controllers", "users_controller.rb"),
                   "class UsersController < ApplicationController\n  def index; end\nend\n")
        File.write(File.join(dir, "packs", "billing", "app", "controllers", "invoices_controller.rb"),
                   "class InvoicesController < ApplicationController\n  def show; end\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result[:controllers].keys).to contain_exactly("UsersController", "InvoicesController")
        expect(result[:controllers]["InvoicesController"][:actions]).to eq([ "show" ])
      end
    end

    it "lists a parent's actions on a subclass that defines none of its own" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "admin", "disputes"))
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "disputes"))
        File.write(File.join(dir, "app", "controllers", "disputes", "strikes_controller.rb"), <<~RUBY)
          class Disputes::StrikesController < ApplicationController
            def index; end

            def show; end
          end
        RUBY
        File.write(File.join(dir, "app", "controllers", "admin", "disputes", "strikes_controller.rb"),
                   "class Admin::Disputes::StrikesController < Disputes::StrikesController\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:controllers]["Admin::Disputes::StrikesController"][:actions]).to eq(%w[index show])
      end
    end

    it "walks past an empty middle class to the grandparent that defines the actions" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "api", "v1"))
        File.write(File.join(dir, "app", "controllers", "api", "accounts_controller.rb"), <<~RUBY)
          class Api::AccountsController < ApplicationController
            def index; end
          end
        RUBY
        File.write(File.join(dir, "app", "controllers", "api", "v1", "accounts_controller.rb"),
                   "class Api::V1::AccountsController < Api::AccountsController\nend\n")
        File.write(File.join(dir, "app", "controllers", "api", "v1", "public_accounts_controller.rb"),
                   "class Api::V1::PublicAccountsController < Api::V1::AccountsController\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:controllers]["Api::V1::PublicAccountsController"][:actions]).to eq([ "index" ])
      end
    end

    it "does not carry a namespaced app base class's helpers in as actions" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "api", "v1"))
        File.write(File.join(dir, "app", "controllers", "api", "application_controller.rb"), <<~RUBY)
          class Api::ApplicationController < ActionController::API
            def doorkeeper_helper; end
          end
        RUBY
        File.write(File.join(dir, "app", "controllers", "api", "v1", "posts_controller.rb"),
                   "class Api::V1::PostsController < Api::ApplicationController\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:controllers]["Api::V1::PostsController"][:actions]).to eq([])
      end
    end

    describe "excluded_filters" do
      before { allow(RailsAiContext.configuration).to receive(:excluded_filters).and_return(%w[set_post]) }

      def static_filters(dir)
        File.write(File.join(dir, "app", "controllers", "posts_controller.rb"), <<~RUBY)
          class PostsController < ApplicationController
            before_action :set_post, only: %i[show]
            before_action :authenticate_user!

            def show; end
          end
        RUBY

        described_class.new(RailsAiContext::StaticApp.new(dir))
          .static_call[:controllers]["PostsController"][:filters].map { |f| f[:name] }
      end

      it "drops an excluded filter and keeps the rest" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "controllers"))

          expect(static_filters(dir)).to eq(%w[authenticate_user!])
        end
      end
    end

    # An excluded name is framework noise while it runs; a skip of it is the
    # app's own decision, and the per-action answer states it either way.
    describe "a skip of an excluded filter, under the default config" do
      it "keeps the skip in the listing and still drops the plain filter" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
          File.write(File.join(dir, "app", "controllers", "webhooks_controller.rb"), <<~RUBY)
            class WebhooksController < ApplicationController
              skip_before_action :verify_authenticity_token
              before_action :verify_same_origin_request
              before_action :require_sig

              def create; end
            end
          RUBY

          ctx = { controllers: described_class.new(RailsAiContext::StaticApp.new(dir)).static_call }

          expect(RailsAiContext::Serializers::SectionFacts.filters_line(ctx, "WebhooksController", root: dir))
            .to eq("- Filters: before require_sig, ~~verify_authenticity_token~~ _(skipped)_")
        end
      end
    end

    # Ruby resolves a bare superclass from the enclosing namespace outward,
    # so the listing key is the qualified name, not the spelling in the file.
    it "resolves a relatively spelled superclass against the enclosing namespace" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "settings"))
        File.write(File.join(dir, "app", "controllers", "settings", "base_controller.rb"), <<~RUBY)
          module Settings
            class BaseController < ApplicationController
              def show; end
            end
          end
        RUBY
        File.write(File.join(dir, "app", "controllers", "settings", "profile_controller.rb"), <<~RUBY)
          module Settings
            class ProfileController < BaseController
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:controllers]["Settings::ProfileController"][:actions]).to eq(%w[show])
      end
    end
  end

  describe "actions for a controller that defines none of its own" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:controllers_dir) { File.join(tmpdir, "app", "controllers") }
    let(:introspector) { described_class.new(double("app", root: Pathname.new(tmpdir))) }

    def source_for(ctrl)
      File.read(File.join(controllers_dir, "#{ctrl.name.underscore}.rb"))
    end

    def actions_for(ctrl)
      introspector.send(:extract_actions, ctrl, source_for(ctrl))
    end

    before do
      FileUtils.mkdir_p(File.join(controllers_dir, "admin"))

      File.write(File.join(controllers_dir, "application_controller.rb"), <<~RUBY)
        class ApplicationController < ActionController::Base
          def set_locale
          end

          def with_read_replica
          end
        end
      RUBY

      File.write(File.join(controllers_dir, "admin", "settings_controller.rb"), <<~RUBY)
        class Admin::SettingsController < ApplicationController
          def show
          end

          def update
          end
        end
      RUBY

      File.write(File.join(controllers_dir, "admin", "thin_controller.rb"), <<~RUBY)
        class Admin::ThinController < Admin::SettingsController
          private

          def after_update_redirect_path
            admin_root_path
          end
        end
      RUBY

      File.write(File.join(controllers_dir, "admin", "bare_controller.rb"), <<~RUBY)
        class Admin::BareController < ApplicationController
        end
      RUBY

      app_ctrl = Class.new(ActionController::Base) do
        def set_locale; end
        def with_read_replica; end
      end
      settings = Class.new(app_ctrl) do
        def show; end
        def update; end
      end
      thin = Class.new(settings) do
        private

        def after_update_redirect_path; end
      end

      stub_const("ApplicationController", app_ctrl)
      stub_const("Admin::SettingsController", settings)
      stub_const("Admin::ThinController", thin)
      stub_const("Admin::BareController", Class.new(app_ctrl))
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "does not report inherited framework helpers as actions" do
      expect(actions_for(Admin::ThinController)).not_to include("set_locale", "with_read_replica")
    end

    it "takes the actions its parent controller defines" do
      expect(actions_for(Admin::ThinController)).to eq(%w[show update])
    end

    it "reports nothing for a controller whose only ancestor is ApplicationController" do
      expect(actions_for(Admin::BareController)).to eq([])
    end

    it "still reports a controller's own actions without consulting the chain" do
      expect(actions_for(Admin::SettingsController)).to eq(%w[show update])
    end

    context "when the controller has no source file at all" do
      before do
        gem_base = Class.new(ActionController::Base) do
          def engine_index; end
          def engine_show; end
        end
        stub_const("SomeEngine::WidgetsController", gem_base)
      end

      it "falls back to reflection rather than reporting nothing" do
        expect(introspector.send(:extract_actions, SomeEngine::WidgetsController, nil))
          .to include("engine_index", "engine_show")
      end

      it "does not fall back when the file was read and simply defines no action" do
        expect(actions_for(Admin::BareController)).to eq([])
      end
    end

    # What `rails g devise:controllers` writes: the app owns the file, every
    # action in it is commented out, and the actions it serves are defined by a
    # gem class whose source is not under app/controllers.
    context "when a readable file inherits from a gem controller" do
      before do
        FileUtils.mkdir_p(File.join(controllers_dir, "users"))
        File.write(File.join(controllers_dir, "users", "sessions_controller.rb"), <<~RUBY)
          class Users::SessionsController < Devise::SessionsController
            # def new
            #   super
            # end
          end
        RUBY

        gem_ctrl = Class.new(ActionController::Base) do
          def new; end
          def create; end
          def destroy; end
        end
        stub_const("Devise::SessionsController", gem_ctrl)
        stub_const("Users::SessionsController", Class.new(gem_ctrl))
      end

      it "reports the actions the gem class defines" do
        expect(actions_for(Users::SessionsController)).to include("new", "create", "destroy")
      end
    end

    # Doorkeeper mounted on the app's own base controller. Reflection is the
    # only way to see the gem's actions, and it carries every public method the
    # app's base controller and its concerns define along with them.
    context "when the gem controller itself inherits the app's base controller" do
      before do
        FileUtils.mkdir_p(File.join(controllers_dir, "oauth"))
        File.write(File.join(controllers_dir, "oauth", "authorizations_controller.rb"), <<~RUBY)
          class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController
            private

            def store_current_location; end
            def can_authorize_response?; end
          end
        RUBY

        doorkeeper = Class.new(ApplicationController) do
          def new; end
          def create; end
          def destroy; end
          def show; end
        end
        stub_const("Doorkeeper::AuthorizationsController", doorkeeper)
        stub_const("Oauth::AuthorizationsController", Class.new(doorkeeper))
      end

      it "reports the actions the gem defines" do
        expect(actions_for(Oauth::AuthorizationsController)).to eq(%w[create destroy new show])
      end

      it "does not carry the base controller's public helpers in with them" do
        expect(actions_for(Oauth::AuthorizationsController))
          .not_to include("set_locale", "with_read_replica")
      end
    end
  end

  describe "the carried file" do
    let(:source) { "class BillingInvoicesController < ApplicationController\n  def show; end\nend\n" }

    it "is the pack path for a pack controller in the static tier" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "controllers"))
        File.write(File.join(dir, "packs", "billing", "app", "controllers", "billing_invoices_controller.rb"), source)

        static = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(static[:controllers]["BillingInvoicesController"][:file])
          .to eq("packs/billing/app/controllers/billing_invoices_controller.rb")
      end
    end

    it "is the pack path for a pack controller the booted tier reads from source" do
      path = File.join(Rails.root, "packs", "billing", "app", "controllers", "billing_invoices_controller.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)

      booted = described_class.new(Rails.application).call
      expect(booted[:controllers]["BillingInvoicesController"][:file])
        .to eq("packs/billing/app/controllers/billing_invoices_controller.rb")
    ensure
      FileUtils.rm_rf(File.join(Rails.root, "packs"))
    end
  end

  # An app's Api::V1::Admin::BaseController listed its own before_action
  # target, a predicate, and a method taking a required argument as actions.
  describe "a controller whose public methods are not all actions" do
    let(:source) do
      <<~RUBY
        class Api::V1::Admin::BaseController < ApplicationController
          before_action :authenticate_admin

          def index
          end

          def authority?
            true
          end

          def create_event(event_name)
          end

          def authenticate_admin
          end
        end
      RUBY
    end

    it "lists only the actions in the static tier" do
      details = introspector.send(:extract_details_from_source,
                                  double(file: "app/controllers/api/v1/admin/base_controller.rb"),
                                  "Api::V1::Admin::BaseController", source)

      expect(details[:actions]).to eq(%w[index])
      expect(details[:filters].map { |f| f[:name] }).to include("authenticate_admin")
    end

    it "lists only the actions in the booted tier" do
      ctrl = Class.new(ActionController::Base) do
        before_action :authenticate_admin

        def index; end
        def authority? = true
        def create_event(event_name); end
        def authenticate_admin; end
      end
      ctrl.define_singleton_method(:name) { "Api::V1::Admin::BaseController" }
      allow(introspector).to receive(:read_source) { |k| k == ctrl ? source : nil }

      expect(introspector.send(:extract_controller_details, ctrl)[:actions]).to eq(%w[index])
    end

    # Mastodon's Api::V2::Admin::AccountsController inherits nine actions its
    # routes do not name, and Auth::OmniauthCallbacksController's
    # after_sign_in_path_for(resource) is no action; the static tier knew both.
    it "marks what the booted class inherits, and drops a method that needs an argument" do
      parent = Class.new(ActionController::Base) do
        def index; end
        def show; end
        def after_sign_in_path_for(resource) = resource
      end
      parent.define_singleton_method(:name) { "AccountsV1Controller" }
      child = Class.new(parent)
      child.define_singleton_method(:name) { "AccountsV2Controller" }
      allow(introspector).to receive(:read_source) do |k|
        k == child ? "class AccountsV2Controller < AccountsV1Controller\nend\n" : nil
      end

      details = introspector.send(:extract_controller_details, child)
      section = { controllers: { "AccountsV2Controller" => details } }
      described_class.apply_routes(section, { by_controller: { "accounts_v2" => [ { action: "index" } ] } }, Dir.tmpdir)

      expect(details[:actions]).to eq(%w[index])
    end
  end

  # OpenProject: WorkPackagePrioritiesController read "(no public actions)"
  # and DocumentTypesController only `delete_dialog`, though both inherit
  # eight actions from Admin::Settings::EnumerationsControllerBase - a file
  # the listing never read, because its name does not end in _controller.rb.
  describe "actions inherited from an app base controller" do
    def write(dir, path, body)
      full = File.join(dir, "app", "controllers", path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
    end

    it "gives each controller its own actions and every app ancestor's, less its own filters" do
      Dir.mktmpdir do |dir|
        write(dir, "admin/settings/enumerations_controller_base.rb", <<~RUBY)
          module Admin::Settings
            class EnumerationsControllerBase < ApplicationController
              def index; end
              def new; end
              def move; end
            end
          end
        RUBY
        write(dir, "admin/settings/work_package_priorities_controller.rb", <<~RUBY)
          module Admin::Settings
            class WorkPackagePrioritiesController < EnumerationsControllerBase
            end
          end
        RUBY
        write(dir, "documents/document_types_controller.rb", <<~RUBY)
          module Documents
            class DocumentTypesController < ::Admin::Settings::EnumerationsControllerBase
              before_action :move

              def delete_dialog; end
            end
          end
        RUBY
        write(dir, "concerns/paginated.rb", "module Paginated\n  def page; end\nend\n")
        write(dir, "queries/params_parser.rb", "module Queries\n  class ParamsParser\n    def parse; end\n  end\nend\n")
        write(dir, "api/v3/grids/grids_api.rb",
              "module API\n  module V3\n    module Grids\n      class GridsAPI < ::API::OpenProjectAPI\n      end\n    end\n  end\nend\n")

        listing = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:controllers]

        expect(listing["Admin::Settings::WorkPackagePrioritiesController"][:actions]).to eq(%w[index move new])
        expect(listing["Documents::DocumentTypesController"][:actions]).to eq(%w[delete_dialog index new])
        expect(listing).to have_key("Admin::Settings::EnumerationsControllerBase")
        expect(listing.keys).not_to include("Paginated", "Queries::ParamsParser")
        expect(listing.keys.grep(/grids/i)).to be_empty
      end
    end
  end

  # OFN's Admin::OrderCyclesController routes `incoming` and ships
  # incoming.html.haml with no method: Rails renders the template.
  describe ".apply_routes" do
    it "adds a routed action that has a template and no method" do
      Dir.mktmpdir do |dir|
        views = File.join(dir, "app", "views", "admin", "order_cycles")
        FileUtils.mkdir_p(views)
        %w[incoming.html.haml edit.html.haml _form.html.haml index.html.haml].each { |f| File.write(File.join(views, f), "") }
        section = { controllers: { "Admin::OrderCyclesController" => { actions: %w[index update] } } }
        routes = { by_controller: { "admin/order_cycles" => [
          { verb: "GET", action: "index" }, { verb: "GET", action: "incoming" },
          { verb: "GET", action: "edit" }, { verb: "GET", action: "outgoing" }, { verb: "GET", action: "_form" }
        ] } }

        described_class.apply_routes(section, routes, dir)

        expect(section[:controllers]["Admin::OrderCyclesController"][:actions]).to eq(%w[edit incoming index update])
      end
    end

    # An app's Api::V1::Admin::BaseController overrides paper_trail's public
    # hooks; every admin controller inherits them and no route names them.
    it "drops an inherited method no route names, and keeps a routed one" do
      section = { controllers: {
        "Admin::AddressesController" => { actions: %w[edit info_for_paper_trail list],
                                          inherited_actions: %w[info_for_paper_trail list] },
        "Admin::UnroutedController" => { actions: %w[info_for_paper_trail], inherited_actions: %w[info_for_paper_trail],
                                         file: "app/controllers/admin/unrouted_controller.rb" }
      } }
      routes = { by_controller: { "admin/addresses" => [ { action: "edit" }, { action: "list" } ] } }

      described_class.apply_routes(section, routes, Dir.tmpdir)

      expect(section[:controllers]["Admin::AddressesController"]).to eq(actions: %w[edit list])
      expect(section[:controllers]["Admin::UnroutedController"][:actions]).to eq([])
    end

    # OFN draws Spree's admin routes into Spree::Core::Engine's table.
    it "judges a controller by the routes an engine's table gives it" do
      section = { controllers: { "Spree::Admin::ProductsController" => {
        actions: %w[destroy edit update_positions], inherited_actions: %w[destroy update_positions],
        file: "app/controllers/spree/admin/products_controller.rb"
      } } }
      routes = { by_controller: { "posts" => [ { action: "index" } ] },
                 engine_routes: [ { engine: "Spree::Core::Engine", mount: "/", routes: [
                   { verb: "GET", path: "/admin/products/:id/edit", controller: "spree/admin/products", action: "edit" },
                   { verb: "POST", path: "/admin/products/update_positions", controller: "spree/admin/products",
                     action: "update_positions" }
                 ] } ] }

      described_class.apply_routes(section, routes, Dir.tmpdir)

      expect(section[:controllers]["Spree::Admin::ProductsController"][:actions]).to eq(%w[edit update_positions])
    end

    # Mastodon's inflection spells ActivityPub:: as activitypub/.
    it "reads the controller's route path off its file" do
      section = { controllers: { "ActivityPub::LikesController" => {
        actions: %w[doorkeeper_forbidden_render_options index], inherited_actions: %w[doorkeeper_forbidden_render_options],
        file: "app/controllers/activitypub/likes_controller.rb"
      } } }
      routes = { by_controller: { "activitypub/likes" => [ { action: "index" } ] } }

      described_class.apply_routes(section, routes, Dir.tmpdir)

      expect(section[:controllers]["ActivityPub::LikesController"][:actions]).to eq(%w[index])
    end

    # An app's Api::V1::BaseController defines paper_trail's public hooks and
    # is never routed; its subclasses are.
    it "keeps on an unrouted base only what its subclasses are routed for" do
      section = { controllers: {
        "Api::BaseController" => { actions: %w[index info_for_paper_trail], parent_class: "ApplicationController" },
        "Api::PostsController" => { actions: %w[index info_for_paper_trail], parent_class: "Api::BaseController",
                                    inherited_actions: %w[index info_for_paper_trail] },
        "Admin::BaseController" => { actions: %w[helper], parent_class: "ApplicationController" },
        "Admin::ThingsController" => { actions: %w[helper], parent_class: "Admin::BaseController" }
      } }
      routes = { by_controller: { "api/posts" => [ { action: "index" } ] } }

      described_class.apply_routes(section, routes, Dir.tmpdir)

      expect(section[:controllers]["Api::BaseController"][:actions]).to eq(%w[index])
      expect(section[:controllers]["Api::PostsController"][:actions]).to eq(%w[index])
      expect(section[:controllers]["Admin::BaseController"][:actions]).to eq(%w[helper])
    end

    # OAuth::UserinfoController inherits doorkeeper's public render hooks.
    it "keeps on an unrouted controller only what it defines itself, when routes are known" do
      section = { controllers: {
        "OAuth::UserinfoController" => { actions: %w[doorkeeper_forbidden_render_options show],
                                         inherited_actions: %w[doorkeeper_forbidden_render_options],
                                         file: "app/controllers/oauth/userinfo_controller.rb" },
        # OpenProject's modules/costs routes this in modules/costs/config/routes.rb.
        "Admin::CostsSettingsController" => { actions: %w[show update], inherited_actions: %w[show update],
                                              file: "modules/costs/app/controllers/admin/costs_settings_controller.rb" }
      } }

      described_class.apply_routes(section, { by_controller: { "home" => [ { action: "index" } ] } }, Dir.tmpdir)

      expect(section[:controllers]["OAuth::UserinfoController"][:actions]).to eq(%w[show])
      expect(section[:controllers]["Admin::CostsSettingsController"][:actions]).to eq(%w[show update])
    end

    # Whitehall's ContactTranslationsController gets create, update and
    # destroy from TranslationControllerConcern; its helper is no action.
    it "lists what an included controller concern offers, and the routes keep the routed ones" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        File.write(File.join(dir, "app", "controllers", "concerns", "translation_concern.rb"),
                   "module TranslationConcern\n  extend ActiveSupport::Concern\n  def create; end\n  def translation_locale; end\nend\n")
        File.write(File.join(dir, "app", "controllers", "contact_translations_controller.rb"),
                   "class ContactTranslationsController < ApplicationController\n  include TranslationConcern\n  def index; end\nend\n")

        section = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        described_class.apply_routes(section, { by_controller: { "contact_translations" => [
          { action: "index" }, { action: "create" }
        ] } }, dir)

        expect(section[:controllers]["ContactTranslationsController"][:actions]).to eq(%w[create index])
      end
    end

    it "records which actions were inherited, for the routes to settle" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "admin"))
        File.write(File.join(dir, "app", "controllers", "admin", "base_controller.rb"),
                   "class Admin::BaseController < ApplicationController\n  def product_name; end\nend\n")
        File.write(File.join(dir, "app", "controllers", "admin", "things_controller.rb"),
                   "class Admin::ThingsController < Admin::BaseController\n  def index; end\nend\n")

        things = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:controllers]["Admin::ThingsController"]

        expect(things[:actions]).to eq(%w[index product_name])
        expect(things[:inherited_actions]).to eq(%w[product_name])
      end
    end
  end
end
