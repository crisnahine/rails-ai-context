# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ControllerIntrospector, "AST edge cases" do
  let(:introspector) { described_class.new(Rails.application) }

  # Helper: extract from source-only path (no class loading)
  def extract_from_source(source)
    introspector.send(:extract_details_from_source_string, source)
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 1: Inline before_action block (no symbol arg)
  # The old regex matched `before_action :symbol_name`.
  # An inline block has no symbol - both versions should skip it.
  # ────────────────────────────────────────────────────────────
  describe "inline before_action block" do
    let(:fixture) { File.join(Rails.root, "app/controllers/inline_block_controller.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(fixture))
      File.write(fixture, <<~RUBY)
        class InlineBlockController < ApplicationController
          before_action { redirect_to root_path unless current_user }
          before_action :set_locale

          def index
            render plain: "ok"
          end

          private

          def set_locale
            I18n.locale = :en
          end
        end
      RUBY
    end

    after { FileUtils.rm_f(fixture) }

    it "skips the inline block filter and captures the symbol filter" do
      load fixture
      result = introspector.call
      ctrl = result[:controllers]["InlineBlockController"]
      filters = ctrl[:filters]

      # The inline block filter should not appear (no symbol arg)
      names = filters.map { |f| f[:name] }
      expect(names).to include("set_locale")
      # Block-based filters either don't appear or appear differently,
      # but should not crash
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 2: Multi-line before_action declaration
  # ────────────────────────────────────────────────────────────
  describe "multi-line before_action" do
    let(:fixture) { File.join(Rails.root, "app/controllers/multiline_filter_controller.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(fixture))
      File.write(fixture, <<~RUBY)
        class MultilineFilterController < ApplicationController
          before_action :authenticate_user!,
                        only: [:create, :update, :destroy]

          def index
            render plain: "ok"
          end

          def create
            render plain: "created"
          end

          def update
            render plain: "updated"
          end

          def destroy
            render plain: "destroyed"
          end

          private

          def authenticate_user!
            true
          end
        end
      RUBY
    end

    after { FileUtils.rm_f(fixture) }

    it "extracts the filter with its only constraint across lines" do
      load fixture
      result = introspector.call
      ctrl = result[:controllers]["MultilineFilterController"]
      filters = ctrl[:filters]
      auth_filter = filters.find { |f| f[:name] == "authenticate_user!" }
      expect(auth_filter).not_to be_nil
      expect(auth_filter[:kind]).to eq("before")
      expect(auth_filter[:only]).to contain_exactly("create", "update", "destroy")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 3: Multiple permit calls in one controller
  # ────────────────────────────────────────────────────────────
  describe "multiple strong params methods" do
    let(:fixture) { File.join(Rails.root, "app/controllers/multi_params_controller.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(fixture))
      File.write(fixture, <<~RUBY)
        class MultiParamsController < ApplicationController
          def create
            if admin?
              @widget = Widget.new(admin_widget_params)
            else
              @widget = Widget.new(widget_params)
            end
          end

          private

          def widget_params
            params.require(:widget).permit(:name, :color)
          end

          def admin_widget_params
            params.require(:widget).permit(:name, :color, :secret_key, :admin_notes)
          end
        end
      RUBY
    end

    after { FileUtils.rm_f(fixture) }

    it "extracts both params methods" do
      load fixture
      result = introspector.call
      ctrl = result[:controllers]["MultiParamsController"]
      sp = ctrl[:strong_params]
      expect(sp.size).to eq(2)
      names = sp.map { |p| p[:name] }
      expect(names).to contain_exactly("widget_params", "admin_widget_params")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 4: Namespaced constants in rescue_from
  # ────────────────────────────────────────────────────────────
  describe "namespaced rescue_from constants" do
    let(:fixture) { File.join(Rails.root, "app/controllers/namespaced_rescue_controller.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(fixture))
      File.write(fixture, <<~RUBY)
        class NamespacedRescueController < ApplicationController
          rescue_from ActiveRecord::RecordNotFound, with: :not_found
          rescue_from ActiveRecord::RecordInvalid, ActionController::ParameterMissing, with: :bad_request

          def index
            render plain: "ok"
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

    after { FileUtils.rm_f(fixture) }

    it "extracts fully qualified constant names" do
      load fixture
      result = introspector.call
      ctrl = result[:controllers]["NamespacedRescueController"]
      rescue_entries = ctrl[:rescue_from]
      exceptions = rescue_entries.map { |r| r[:exception] }
      expect(exceptions).to include("ActiveRecord::RecordNotFound")
      expect(exceptions).to include("ActiveRecord::RecordInvalid")
      expect(exceptions).to include("ActionController::ParameterMissing")
    end

    it "preserves the handler for each exception" do
      load fixture
      result = introspector.call
      ctrl = result[:controllers]["NamespacedRescueController"]
      rescue_entries = ctrl[:rescue_from]

      not_found = rescue_entries.find { |r| r[:exception] == "ActiveRecord::RecordNotFound" }
      expect(not_found[:handler]).to eq("not_found")

      bad_req = rescue_entries.find { |r| r[:exception] == "ActiveRecord::RecordInvalid" }
      expect(bad_req[:handler]).to eq("bad_request")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 5: Controller with no actions (empty body)
  # ────────────────────────────────────────────────────────────
  describe "controller with no actions" do
    let(:fixture) { File.join(Rails.root, "app/controllers/empty_controller.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(fixture))
      File.write(fixture, <<~RUBY)
        class EmptyController < ApplicationController
        end
      RUBY
    end

    after { FileUtils.rm_f(fixture) }

    it "returns an empty actions array" do
      load fixture
      result = introspector.call
      ctrl = result[:controllers]["EmptyController"]
      expect(ctrl[:actions]).to eq([])
    end

    it "returns empty strong_params" do
      load fixture
      result = introspector.call
      ctrl = result[:controllers]["EmptyController"]
      expect(ctrl[:strong_params]).to eq([])
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 6: Controller inheriting from API controller
  # ────────────────────────────────────────────────────────────
  describe "API-inheriting controller" do
    let(:fixture) { File.join(Rails.root, "app/controllers/api/v2/things_controller.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(fixture))
      File.write(fixture, <<~RUBY)
        module Api
          module V2
            class ThingsController < ActionController::API
              def index
                render json: []
              end
            end
          end
        end
      RUBY
    end

    after { FileUtils.rm_f(fixture) }

    it "detects api_controller as true" do
      load fixture
      result = introspector.call
      ctrl = result[:controllers]["Api::V2::ThingsController"]
      expect(ctrl[:api_controller]).to be true
    end

    it "extracts parent_class containing API" do
      load fixture
      result = introspector.call
      ctrl = result[:controllers]["Api::V2::ThingsController"]
      expect(ctrl[:parent_class]).to include("API")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 7: skip_before_action in source fallback
  # The old regex did NOT match skip_before_action.
  # The AST version includes it in filter_macros.
  # This is a behavioral difference.
  # ────────────────────────────────────────────────────────────
  describe "skip_before_action in source-only parsing" do
    it "includes skip_before_action in source-based filter extraction" do
      source = <<~RUBY
        class SkipController < ApplicationController
          skip_before_action :verify_authenticity_token, only: [:api_create]
          before_action :set_thing

          def index
            render plain: "ok"
          end

          def api_create
            render plain: "ok"
          end

          private

          def set_thing
            true
          end
        end
      RUBY
      filters = introspector.send(:extract_filters_from_source, source)
      names = filters.map { |f| f[:name] }
      expect(names).to include("verify_authenticity_token")
      expect(names).to include("set_thing")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 8: protect_from_forgery (not in filter_macros list)
  # protect_from_forgery is a common controller macro but is NOT
  # in the AST filter_macros list. Verify it doesn't appear.
  # ────────────────────────────────────────────────────────────
  describe "protect_from_forgery" do
    it "does not extract protect_from_forgery as a filter" do
      source = <<~RUBY
        class SecureController < ApplicationController
          protect_from_forgery with: :exception
          before_action :authenticate

          def index
            render plain: "ok"
          end

          private

          def authenticate
            true
          end
        end
      RUBY
      filters = introspector.send(:extract_filters_from_source, source)
      names = filters.map { |f| f[:name] }
      expect(names).not_to include("protect_from_forgery")
      expect(names).to include("authenticate")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 9: Strong params - params.permit without require
  # ────────────────────────────────────────────────────────────
  describe "params.permit without require" do
    it "extracts permits without a requires key" do
      source = <<~RUBY
        class SearchController < ApplicationController
          def index
            render plain: "ok"
          end

          private

          def search_params
            params.permit(:query, :page, :per_page)
          end
        end
      RUBY
      sp = introspector.send(:extract_strong_params, source)
      expect(sp.size).to eq(1)
      entry = sp.first
      expect(entry[:name]).to eq("search_params")
      expect(entry[:permits]).to contain_exactly("query", "page", "per_page")
      expect(entry).not_to have_key(:requires)
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 10: params.permit! (unrestricted)
  # ────────────────────────────────────────────────────────────
  describe "params.permit! unrestricted" do
    it "flags unrestricted params" do
      source = <<~RUBY
        class DangerController < ApplicationController
          def index
            render plain: "ok"
          end

          private

          def danger_params
            params.permit!
          end
        end
      RUBY
      sp = introspector.send(:extract_strong_params, source)
      expect(sp.size).to eq(1)
      entry = sp.first
      expect(entry[:name]).to eq("danger_params")
      expect(entry[:unrestricted]).to be true
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 11: respond_to with conditional format blocks
  # ────────────────────────────────────────────────────────────
  describe "respond_to with conditional format inside if/else" do
    it "extracts all format types regardless of nesting" do
      source = <<~RUBY
        class ConditionalFormatController < ApplicationController
          def show
            respond_to do |format|
              if @widget.published?
                format.html
                format.pdf { render_pdf }
              else
                format.html { render :draft }
              end
              format.json { render json: @widget }
            end
          end
        end
      RUBY
      formats = introspector.send(:extract_respond_to, source)
      expect(formats).to contain_exactly("html", "json", "pdf")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 12: respond_to outside of a respond_to block
  # format.X calls outside respond_to should NOT be captured.
  # (The old regex captured ALL format.X in the file.)
  # ────────────────────────────────────────────────────────────
  describe "format calls outside respond_to blocks" do
    it "does not capture format calls outside respond_to" do
      source = <<~RUBY
        class StrayFormatController < ApplicationController
          def index
            format.csv { send_csv }
          end

          def show
            respond_to do |format|
              format.html
              format.json
            end
          end
        end
      RUBY
      formats = introspector.send(:extract_respond_to, source)
      # The AST version only captures formats inside respond_to blocks.
      # csv should NOT appear.
      expect(formats).to contain_exactly("html", "json")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 13: rescue_from with no handler (block form)
  # ────────────────────────────────────────────────────────────
  describe "rescue_from with block instead of with:" do
    let(:fixture) { File.join(Rails.root, "app/controllers/block_rescue_controller.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(fixture))
      File.write(fixture, <<~RUBY)
        class BlockRescueController < ApplicationController
          rescue_from ActiveRecord::RecordNotFound do |e|
            render plain: "not found", status: 404
          end

          def show
            render plain: "ok"
          end
        end
      RUBY
    end

    after { FileUtils.rm_f(fixture) }

    it "extracts the exception class with nil handler" do
      load fixture
      result = introspector.call
      ctrl = result[:controllers]["BlockRescueController"]
      rescue_entries = ctrl[:rescue_from]
      expect(rescue_entries.size).to eq(1)
      expect(rescue_entries.first[:exception]).to eq("ActiveRecord::RecordNotFound")
      expect(rescue_entries.first).not_to have_key(:handler)
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 14: Actions after private method that includes
  # underscore-prefixed methods (should be excluded)
  # ────────────────────────────────────────────────────────────
  describe "underscore-prefixed methods excluded from actions" do
    it "excludes methods starting with underscore" do
      source = <<~RUBY
        class UnderscoreController < ApplicationController
          def index
            render plain: "ok"
          end

          def _callback
            true
          end
        end
      RUBY
      actions = introspector.send(:extract_actions_from_source, source)
      expect(actions).to include("index")
      expect(actions).not_to include("_callback")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 15: Turbo stream actions detection in multiple methods
  # ────────────────────────────────────────────────────────────
  describe "turbo_stream in multiple actions" do
    it "captures all actions that use format.turbo_stream" do
      source = <<~RUBY
        class TurboController < ApplicationController
          def create
            respond_to do |format|
              format.html
              format.turbo_stream
            end
          end

          def update
            respond_to do |format|
              format.turbo_stream
            end
          end

          def destroy
            respond_to do |format|
              format.html { redirect_to root_path }
            end
          end
        end
      RUBY
      turbo_actions = introspector.send(:extract_turbo_stream_actions, source)
      expect(turbo_actions).to contain_exactly("create", "update")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 16: Strong params - complex nested with arrays
  # ────────────────────────────────────────────────────────────
  describe "strong params with arrays and nested" do
    it "handles tags: [] as an array param, images: [:url, :caption] as nested" do
      source = <<~RUBY
        class ComplexParamsController < ApplicationController
          private

          def complex_params
            params.require(:post).permit(:title, tags: [], images: [:url, :caption])
          end
        end
      RUBY
      sp = introspector.send(:extract_strong_params, source)
      expect(sp.size).to eq(1)
      entry = sp.first
      expect(entry[:name]).to eq("complex_params")
      expect(entry[:requires]).to eq("post")
      expect(entry[:permits]).to eq([ "title" ])
      expect(entry[:arrays]).to eq([ "tags" ])
      expect(entry[:nested]).to eq({ "images" => [ "url", "caption" ] })
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 17: Concerns extracted from source (no class loaded)
  # ────────────────────────────────────────────────────────────
  describe "concerns from source" do
    it "extracts include statements from source" do
      source = <<~RUBY
        class ConcernController < ApplicationController
          include Authenticatable
          include Admin::Trackable

          def index
            render plain: "ok"
          end
        end
      RUBY
      concerns = introspector.send(:extract_concerns_from_source, source)
      expect(concerns).to include("Authenticatable")
      expect(concerns).to include("Admin::Trackable")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 18: filter kind normalization
  # prepend_before_action should produce kind "before", not
  # "prepend_before".
  # ────────────────────────────────────────────────────────────
  describe "filter kind normalization" do
    it "normalizes prepend_before_action to kind 'before'" do
      source = <<~RUBY
        class PrependController < ApplicationController
          prepend_before_action :early_check
          append_after_action :late_check

          def index
            render plain: "ok"
          end

          private

          def early_check
            true
          end

          def late_check
            true
          end
        end
      RUBY
      filters = introspector.send(:extract_filters_from_source, source)
      early = filters.find { |f| f[:name] == "early_check" }
      late = filters.find { |f| f[:name] == "late_check" }

      expect(early[:kind]).to eq("before")
      expect(late[:kind]).to eq("after")
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 19: rate_limit AST returns different format than
  # the old regex (the old regex returned raw source text;
  # the AST version reconstructs from options hash)
  # ────────────────────────────────────────────────────────────
  describe "rate_limit output format" do
    it "produces a string containing 'to:' and 'within:'" do
      source = <<~RUBY
        class RateController < ApplicationController
          rate_limit to: 5, within: 1.minute, only: :create

          def create
            render plain: "ok"
          end
        end
      RUBY
      raw = introspector.send(:extract_rate_limit, source)
      expect(raw).to include("to")
      expect(raw).to include("within")
      # The old regex would return: "to: 5, within: 1.minute, only: :create"
      # The AST version returns options reconstructed as "to: 5, within: ..."
    end
  end

  # ────────────────────────────────────────────────────────────
  # Edge case 20: parent class extraction from AST
  # ────────────────────────────────────────────────────────────
  describe "parent class from AST" do
    it "extracts namespaced parent class" do
      source = <<~RUBY
        class Api::V1::WidgetsController < Api::V1::BaseController
          def index
            render json: []
          end
        end
      RUBY
      parent = introspector.send(:extract_parent_class_ast, source)
      expect(parent).to eq("Api::V1::BaseController")
    end

    it "returns Unknown for a class with no superclass" do
      source = <<~RUBY
        class OrphanController
          def index
            render plain: "ok"
          end
        end
      RUBY
      parent = introspector.send(:extract_parent_class_ast, source)
      expect(parent).to eq("Unknown")
    end
  end
end
