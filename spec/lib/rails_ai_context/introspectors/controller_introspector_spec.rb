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

      after { FileUtils.rm_f(fixture_ctrl) }

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
            rate_limit to: 10, within: 1.minute

            def index
              render plain: "ok"
            end
          end
        RUBY
      end

      after { FileUtils.rm_f(fixture_ctrl) }

      it "extracts rate_limit macro from source" do
        rate_limit = result[:controllers]["RateLimitedController"][:rate_limit]
        expect(rate_limit).to include("10")
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

      after { FileUtils.rm_f(fixture_ctrl) }

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
      result = introspector.send(:extract_permit_details, source, "post_params")
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
      result = introspector.send(:extract_permit_details, source, "user_params")
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
      result = introspector.send(:extract_permit_details, source, "post_params")
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
      result = introspector.send(:extract_permit_details, source, "post_params")
      expect(result[:permits]).to contain_exactly("title", "body", "published")
    end

    it "flags params.permit! as unrestricted" do
      source = <<~RUBY
        def post_params
          params.permit!
        end
      RUBY
      result = introspector.send(:extract_permit_details, source, "post_params")
      expect(result[:unrestricted]).to be true
    end

    it "parses params.expect with a keyword array" do
      source = <<~RUBY
        def article_params
          params.expect(article: [ :title, :body, :published ])
        end
      RUBY
      result = introspector.send(:extract_permit_details, source, "article_params")
      expect(result[:requires]).to eq("article")
      expect(result[:permits]).to contain_exactly("title", "body", "published")
    end

    it "parses params.expect with nested attributes" do
      source = <<~RUBY
        def user_params
          params.expect(user: [ :name, address: [ :street, :city ] ])
        end
      RUBY
      result = introspector.send(:extract_permit_details, source, "user_params")
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
      result = introspector.send(:extract_permit_details, source, "post_params")
      expect(result[:requires]).to eq("post")
      expect(result[:permits]).to eq([ "title" ])
      expect(result[:nested]).to eq({ "comments" => [ "body" ] })
    end

    it "returns name only when method has no permit call" do
      source = <<~RUBY
        def post_params
          params[:post]
        end
      RUBY
      result = introspector.send(:extract_permit_details, source, "post_params")
      expect(result[:name]).to eq("post_params")
      expect(result).not_to have_key(:permits)
    end

    it "handles hash rocket nested syntax" do
      source = <<~RUBY
        def user_params
          params.require(:user).permit(:name, :address => [:street, :city])
        end
      RUBY
      result = introspector.send(:extract_permit_details, source, "user_params")
      expect(result[:nested]).to eq({ "address" => %w[street city] })
    end

    it "handles combined nested and array permits" do
      source = <<~RUBY
        def order_params
          params.require(:order).permit(:total, item_ids: [], address: [:line1, :line2])
        end
      RUBY
      result = introspector.send(:extract_permit_details, source, "order_params")
      expect(result[:permits]).to eq([ "total" ])
      expect(result[:arrays]).to eq([ "item_ids" ])
      expect(result[:nested]).to eq({ "address" => %w[line1 line2] })
    end
  end

  describe "#static_call" do
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

    it "returns an empty controllers hash when the directory is missing" do
      Dir.mktmpdir do |dir|
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result[:controllers]).to eq({})
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
end
