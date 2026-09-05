# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetContext do
  describe ".call" do
    it "requires at least one parameter" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Provide at least one of")
      expect(result.error?).to be(true)
    end

    it "returns an MCP::Tool::Response" do
      result = described_class.call(model: "NonExistentModel")
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "does not offer a fuzzy suggestion for a blank model param" do
      # An empty model: "" means "missing", not "typo" - it must not fuzzy-match
      # the first model in the app just because "".include?(anything) is true.
      result = described_class.call(model: "")
      text = result.content.first[:text]
      expect(text).not_to include("Did you mean")
    end
  end

  describe "cross_reference_ivars" do
    it "uses actual Unicode characters, not escaped sequences" do
      # Access the private method to test directly
      ctrl_ivars = Set.new(%w[ user posts ])
      view_ivars = Set.new(%w[ user comments ])

      result = described_class.send(:cross_reference_ivars, ctrl_ivars, view_ivars)

      # Should use real Unicode checkmark/cross/warning, not literal \u2713
      expect(result).to include("\u2713") # ✓
      expect(result).to include("\u26A0") # ⚠
      expect(result).to include("\u2717") # ✗
      expect(result).not_to include('\\u2713')
      expect(result).not_to include('\\u2717')
      expect(result).not_to include('\\u26A0')
    end

    it "shows matched ivars as set in controller and used in view" do
      ctrl_ivars = Set.new(%w[ user ])
      view_ivars = Set.new(%w[ user ])

      result = described_class.send(:cross_reference_ivars, ctrl_ivars, view_ivars)

      expect(result).to include("@user")
      expect(result).to include("set in controller, used in view")
    end

    it "flags ivars used in view but not set in controller" do
      ctrl_ivars = Set.new
      view_ivars = Set.new(%w[ orphan ])

      result = described_class.send(:cross_reference_ivars, ctrl_ivars, view_ivars)

      expect(result).to include("@orphan")
      expect(result).to include("used in view but NOT set in controller")
    end

    it "flags ivars set in controller but not used in view" do
      ctrl_ivars = Set.new(%w[ unused ])
      view_ivars = Set.new

      result = described_class.send(:cross_reference_ivars, ctrl_ivars, view_ivars)

      expect(result).to include("@unused")
      expect(result).to include("set in controller but not used in view")
    end

    it "returns nil when both sets are empty" do
      result = described_class.send(:cross_reference_ivars, Set.new, Set.new)
      expect(result).to be_nil
    end

    context "when api_only: true" do
      it "labels a matched ivar as used in response, not used in view" do
        result = described_class.send(:cross_reference_ivars, Set.new(%w[order]), Set.new(%w[order]), api_only: true)

        expect(result).to include("@order")
        expect(result).to include("set in controller, used in response")
        expect(result).not_to include("used in view")
      end

      it "labels an unrendered ivar without claiming a view exists" do
        result = described_class.send(:cross_reference_ivars, Set.new(%w[unused]), Set.new, api_only: true)

        expect(result).to include("@unused")
        expect(result).to include("set in controller but not rendered in response")
        expect(result).not_to include("view")
      end
    end
  end

  describe "controller_action_context" do
    it "does not warn that an ivar rendered via render json: is unused" do
      allow(described_class).to receive(:cached_context).and_return(api: { api_only: true })

      ctrl_response = MCP::Tool::Response.new([ { type: "text", text: <<~MD } ])
        # OrdersController#create

        ## Instance Variables
        - `@order`

        ## Source (lines 1-5)
        ```ruby
        def create
          @order = Order.new(order_params)
          render json: @order, status: :created
        end
        ```
      MD
      allow(RailsAiContext::Tools::GetControllers).to receive(:call).and_return(ctrl_response)

      route_response = MCP::Tool::Response.new([ { type: "text", text: "No routes found." } ])
      allow(RailsAiContext::Tools::GetRoutes).to receive(:call).and_return(route_response)

      view_response = MCP::Tool::Response.new([ { type: "text", text: "No views found for orders." } ])
      allow(RailsAiContext::Tools::GetView).to receive(:call).and_return(view_response)

      text = described_class.send(:controller_action_context, "OrdersController", "create")

      expect(text).not_to include("not used in view")
      expect(text).not_to include("not rendered in response")
      expect(text).to include("@order")
    end

    it "skips the cross-check when the context carries no view templates" do
      allow(described_class).to receive(:cached_context).and_return(
        controllers: { controllers: { "PostsController" => {
          actions: %w[new], file: "app/controllers/posts_controller.rb"
        } } }
      )

      base = RailsAiContext::Tools::BaseTool
      allow(RailsAiContext::Tools::GetControllers).to receive(:call)
        .and_return(base.text_response("# PostsController#new"))
      allow(RailsAiContext::Tools::GetRoutes).to receive(:call).and_return(base.empty_response("No routes."))
      allow(RailsAiContext::Tools::GetView).to receive(:call).and_return(base.empty_response("No views."))

      text = described_class.send(:controller_action_context, "PostsController", "new")

      expect(text).not_to include("not used in view")
      expect(text).not_to include("## Instance Variable Cross-Check")
    end

    it "keeps a section whose own body mentions not found" do
      allow(described_class).to receive(:cached_context).and_return({})

      base = RailsAiContext::Tools::BaseTool
      allow(RailsAiContext::Tools::GetControllers).to receive(:call)
        .and_return(base.text_response("# PostsController#show"))
      allow(RailsAiContext::Tools::GetModelDetails).to receive(:call)
        .and_return(base.text_response("# Post\n\nrescue_from ActiveRecord::RecordNotFound do\n  render plain: \"record not found\"\nend"))
      allow(RailsAiContext::Tools::GetRoutes).to receive(:call)
        .and_return(base.empty_response("No routes for 'posts'. Controllers: users"))
      allow(RailsAiContext::Tools::GetView).to receive(:call)
        .and_return(base.empty_response("No views for 'posts'."))

      text = described_class.send(:controller_action_context, "PostsController", "show")

      expect(text).to include("record not found")
      expect(text).not_to include("No routes for")
      expect(text).not_to include("No views for")
    end
  end

  # The controllers section is a Hash of name => data. Reading it as a list of
  # entries raised a TypeError that the method-level rescue swallowed, which
  # threw away every schema block already appended and answered plain
  # AnalyzeFeature text instead.
  describe "feature context over the introspected fixture" do
    # Seeded in a before hook, not an around one: spec_helper resets the shared
    # cache in a config-level before(:each), which runs after any around hook.
    before do
      context = IntrospectedFixture.context.deep_dup
      # A controller the loose by-name match finds and the word match does not,
      # which is the only way into the related-controllers branch.
      context[:controllers][:controllers]["CommentaryController"] =
        { actions: %w[index show], file: "app/controllers/commentary_controller.rb" }
      cache = RailsAiContext::Tools::BaseTool::SHARED_CACHE
      cache[:context] = context
      cache[:timestamp] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    after { RailsAiContext::Tools::BaseTool.reset_cache! }

    it "names the controllers that match by name and keeps the schema enrichment above them", :aggregate_failures do
      text = described_class.call(feature: "comment").content.first[:text]

      expect(text).to include("## Related Controllers (by name)")
      expect(text).to include("- **CommentaryController** - index, show")
      # GetSchema's own table heading, which only the enrichment block appends.
      # The rescued fallback names the table too, in AnalyzeFeature's summary.
      expect(text).to include("## Table: comments")
    end
  end
end
