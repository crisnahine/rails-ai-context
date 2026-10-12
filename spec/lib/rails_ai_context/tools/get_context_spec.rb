# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

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

  describe "an unexpected exception" do
    {
      "a controller and an action" => [ RailsAiContext::Tools::GetRoutes, { controller: "PostsController", action: "index" } ],
      "a controller" => [ RailsAiContext::Tools::GetRoutes, { controller: "PostsController" } ],
      "a model" => [ RailsAiContext::Tools::GetSchema, { model: "Post" } ]
    }.each do |mode, (tool, params)|
      it "is an error result for #{mode}" do
        allow(tool).to receive(:call).and_raise(NoMethodError, "undefined method 'to_sentence' for an instance of Array")

        response = described_class.call(**params)

        expect(response.error?).to be(true), response.content.first[:text]
        expect(response.content.first[:text]).to start_with("Tool rails_get_context failed: NoMethodError: undefined method 'to_sentence'")
      end
    end
  end

  describe "a name the app does not have, with the tool that answers it turned off" do
    around do |example|
      saved = RailsAiContext.configuration.skip_tools
      example.run
    ensure
      RailsAiContext.configuration.skip_tools = saved
    end

    def answer(**params)
      described_class.call(**params).content.first[:text]
    end

    it "is answered as a model that was not found, with the models the app has" do
      RailsAiContext.configuration.skip_tools = %w[rails_get_model_details]
      expect(RailsAiContext::Tools::GetModelDetails).not_to receive(:call)

      expect(answer(model: "Pots")).to start_with("Model 'Pots' not found.\nDid you mean 'Post'?\nAvailable: ")
    end

    it "is answered as a controller that was not found, with the controllers the app has" do
      RailsAiContext.configuration.skip_tools = %w[rails_get_controllers]
      expect(RailsAiContext::Tools::GetControllers).not_to receive(:call)

      expect(answer(controller: "NopeController")).to start_with("Controller 'NopeController' not found.\nAvailable: ")
      expect(answer(controller: "NopeController", action: "index")).to start_with("Controller 'NopeController' not found.\nAvailable: ")
      expect(answer(controller: "PostsController")).not_to include("not found.")
    end

    it "is answered as a feature that matched nothing, with model names to try" do
      RailsAiContext.configuration.skip_tools = %w[rails_analyze_feature]
      expect(RailsAiContext::Tools::AnalyzeFeature).not_to receive(:call)

      expect(answer(feature: "zzqqxx")).to start_with(
        "No matches found for 'zzqqxx'. No model or controller name holds this keyword.\n\nTry one of your model names: "
      )
    end
  end

  describe "include:" do
    let(:keys) { %w[stimulus turbo services jobs conventions helpers env callbacks tests config gems security] }

    def text(response)
      response.content.first[:text]
    end

    it "lists every key it takes in its schema" do
      description = described_class.input_schema_value.to_h.dig(:properties, :include, :description)

      keys.each { |key| expect(description).to include("'#{key}'") }
    end

    it "runs a key given twice once" do
      expect(RailsAiContext::Tools::GetConfig).to receive(:call).with(section: "gems").once.and_call_original

      described_class.call(model: "Post", include: %w[gems GEMS gems])
    end

    it "names a key it does not take, with the keys it does" do
      answer = text(described_class.call(model: "Post", include: %w[stimulus bogus]))

      expect(answer).to include("_`include` does not take 'bogus'. It takes: #{keys.join(', ')}._")
    end

    it "answers an include whose tool skip_tools turned off without running it" do
      saved = RailsAiContext.configuration.skip_tools
      RailsAiContext.configuration.skip_tools = %w[rails_security_scan]
      expect(RailsAiContext::Tools::SecurityScan).not_to receive(:call)

      answer = text(described_class.call(model: "Post", include: %w[security]))

      expect(answer).to include(RailsAiContext::Server.skipped_tool_message("rails_security_scan"))
    ensure
      RailsAiContext.configuration.skip_tools = saved
    end

    it "answers a config include from its rails_get_config section, and says when skip_tools turned the section off" do
      saved = RailsAiContext.configuration.skip_tools
      RailsAiContext.configuration.skip_tools = %w[rails_get_env]
      expect(RailsAiContext::Tools::GetEnv).not_to receive(:call)

      answer = text(described_class.call(model: "Post", include: %w[env gems]))

      expect(answer).to include("\n\n---\n\n_#{RailsAiContext::Tools::GetConfig.section_named('env').off_message}_")
      expect(answer).to include(text(RailsAiContext::Tools::GetConfig.call(section: "gems")))
    ensure
      RailsAiContext.configuration.skip_tools = saved
    end
  end

  # Rails resolves a namespaced controller's templates under its full
  # controller_path. Handing GetView the basename read app/views/orders,
  # which on this app is a directory of templates a service renders.
  describe "views for a namespaced controller" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      described_class.reset_cache!
      FileUtils.mkdir_p(File.join(tmpdir, "app", "controllers", "api", "v1", "admin"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "views", "api", "v1", "admin", "orders"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "views", "orders"))
      File.write(File.join(tmpdir, "app", "controllers", "api", "v1", "admin", "orders_controller.rb"), <<~RUBY)
        class Api::V1::Admin::OrdersController < ApplicationController
          def edit
            @order = Order.find(params[:id])
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "views", "api", "v1", "admin", "orders", "edit.html.erb"),
                 "<h1>Edit order <%= @order.number %></h1>\n")
      File.write(File.join(tmpdir, "app", "views", "orders", "reminder.text.erb"),
                 "Hello <%= @order.number %>,\n")
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "reads the directory Rails would resolve for the controller" do
      text = described_class.call(controller: "Api::V1::Admin::OrdersController", action: "edit").content.first[:text]

      expect(text).to include("api/v1/admin/orders/edit.html.erb")
      expect(text).not_to include("orders/reminder.text.erb")
    end

    it "names the directory the views came from" do
      text = described_class.call(controller: "Api::V1::Admin::OrdersController", action: "edit").content.first[:text]

      expect(text).to include("_Views from `app/views/api/v1/admin/orders`._")
    end

    it "reads the same directory for the whole-controller document" do
      text = described_class.call(controller: "Api::V1::Admin::OrdersController").content.first[:text]

      expect(text).to include("api/v1/admin/orders/edit.html.erb")
      expect(text).not_to include("orders/reminder.text.erb")
    end
  end

  # An app that keeps a flat app/views still has its templates found, and the
  # answer says they are not under the controller's own directory.
  describe "views for a namespaced controller with a flat views directory" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      described_class.reset_cache!
      FileUtils.mkdir_p(File.join(tmpdir, "app", "controllers", "admin"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "views", "orders"))
      File.write(File.join(tmpdir, "app", "controllers", "admin", "orders_controller.rb"), <<~RUBY)
        class Admin::OrdersController < ApplicationController
          def index
            @orders = Order.all
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "views", "orders", "index.html.erb"),
                 "<%= @orders.size %>\n")
      allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "falls back to the flat directory and says the templates are not under the controller's own" do
      text = described_class.call(controller: "Admin::OrdersController").content.first[:text]

      expect(text).to include("orders/index.html.erb")
      expect(text).to include("app/views/admin/orders")
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

    # A scaffold's `show` is empty and set_post sets @post, so reading the
    # action body alone marked every scaffold view "NOT set in controller".
    it "counts what the before filters that run on the action set" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/controllers"))
        File.write(File.join(dir, "app/controllers/posts_controller.rb"), <<~RUBY)
          class PostsController < ApplicationController
            before_action :set_post, only: %i[show publish]

            def show
            end

            def publish
              if @post.publish
                render :show
              else
                render :edit
              end
            end

            private

            def set_post
              @post = Post.find(params[:id])
            end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return(
          controllers: { controllers: { "PostsController" => {
            actions: %w[show publish], file: "app/controllers/posts_controller.rb",
            filters: [ { kind: "before", name: "set_post", only: %w[show publish] } ]
          } } },
          view_templates: { templates: { "posts/show.html.erb" => { ivars: %w[post] }, "posts/edit.html.erb" => { ivars: %w[post categories] } } }
        )
        base = RailsAiContext::Tools::BaseTool
        allow(RailsAiContext::Tools::GetControllers).to receive(:call).and_return(base.text_response("# PostsController"))
        allow(RailsAiContext::Tools::GetRoutes).to receive(:call).and_return(base.empty_response("No routes."))
        allow(RailsAiContext::Tools::GetView).to receive(:call).and_return(base.empty_response("No views."))

        expect(described_class.send(:controller_action_context, "PostsController", "show"))
          .to include("- ✓ @post - set by `set_post`, used in view")

        # publish renders show on success, edit on failure; both run in this request.
        text = described_class.send(:controller_action_context, "PostsController", "publish")
        expect(text).to include("- ✗ @categories - used in view but NOT set in controller")
        expect(text).to include("_Note: This action also renders `show`, `edit`, so that template's instance variables are counted here")
        expect(text).not_to include("on failure")
      end
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

  # A composed answer is one response, so it carries the tier banner once
  # however many tools it was built from.
  describe "the static tier banner on a composed answer" do
    it "appears once" do
      described_class.reset_cache!
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)

      text = described_class.call(model: "User").content.first[:text]

      expect(text.scan("Serving static analysis").size).to eq(1)
    end
  end
end
