# frozen_string_literal: true

require "spec_helper"

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
        # Write source file but do NOT load it — rate_limit is Rails 8+ only.
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
end
