# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::StackOverviewHelper do
  let(:test_class) do
    Class.new do
      include RailsAiContext::Serializers::StackOverviewHelper

      attr_reader :context

      def initialize(context)
        @context = context
      end
    end
  end

  describe "#full_preset_stack_lines" do
    it "returns empty array for empty context" do
      helper = test_class.new({})
      expect(helper.full_preset_stack_lines).to eq([])
    end

    it "renders auth line for Devise" do
      ctx = { auth: { authentication: { devise: [ "User" ] }, authorization: {} } }
      helper = test_class.new(ctx)
      lines = helper.full_preset_stack_lines
      expect(lines.join("\n")).to include("Auth: Devise")
    end

    it "renders auth line for Pundit + Rails 8 auth" do
      ctx = { auth: { authentication: { rails_auth: true }, authorization: { pundit: [ "UserPolicy" ] } } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("Rails 8 auth")
      expect(text).to include("Pundit")
    end

    it "renders Hotwire line with frames and streams" do
      ctx = { turbo: { frames: [ "user_frame" ], streams: [ "user_stream", "post_stream" ], broadcasts: [] } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("Hotwire")
      expect(text).to include("1 frame, 2 streams")
      expect(text).to include("2 streams")
    end

    it "renders I18n line when multiple locales exist" do
      ctx = { i18n: { available_locales: %w[en es fr de] } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("I18n: 4 locales")
      expect(text).to include("en, es, fr, de")
    end

    it "skips I18n when only one locale" do
      ctx = { i18n: { available_locales: %w[en] } }
      helper = test_class.new(ctx)
      expect(helper.full_preset_stack_lines).to eq([])
    end

    it "renders ActiveStorage line when attachments exist" do
      ctx = { active_storage: { attachments: [ { model: "User", name: "avatar" }, { model: "Post", name: "cover" } ] } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("Storage: ActiveStorage")
      expect(text).to include("2 models with attachments")
    end

    it "renders ActionText line when rich text fields exist" do
      ctx = { action_text: { rich_text_fields: [ { model: "Post", field: "body" } ] } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("RichText: ActionText")
      expect(text).to include("1 field")
    end

    it "renders assets line with pipeline and framework" do
      ctx = { assets: { pipeline: "Propshaft", js_bundler: "esbuild", css_framework: "Tailwind" } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("Assets: Propshaft, esbuild, Tailwind")
    end

    it "renders components line when components exist" do
      ctx = { components: { summary: { total: 5, view_component: 3, phlex: 2 } } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("Components: 5 components")
      expect(text).to include("3 ViewComponent")
      expect(text).to include("2 Phlex")
    end

    it "renders performance line when issues detected" do
      ctx = { performance: { summary: { total_issues: 7 } } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("Performance: 7 issues detected")
    end

    it "skips performance line when zero issues" do
      ctx = { performance: { summary: { total_issues: 0 } } }
      helper = test_class.new(ctx)
      expect(helper.full_preset_stack_lines).to eq([])
    end

    it "renders frontend framework line when detected" do
      ctx = { frontend_frameworks: { framework: "React", version: "18.2", mounting: "Inertia" } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("Frontend: React 18.2, Inertia")
    end

    it "renders API line for API-only apps with GraphQL" do
      ctx = { api: { api_only: true, versions: %w[v1 v2], graphql: { types: 5 }, serializer_library: "Alba" } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("API: API-only, 2 versions, GraphQL, Alba")
    end

    it "renders engines line when mounted engines exist" do
      ctx = { engines: { mounted: [ { name: "Sidekiq::Web" }, { name: "Devise::Engine" } ] } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("Engines: Sidekiq::Web, Devise::Engine")
    end

    it "renders multi-database line when more than one database" do
      ctx = { multi_database: { databases: [ { name: "primary" }, { name: "analytics" } ] } }
      helper = test_class.new(ctx)
      text = helper.full_preset_stack_lines.join("\n")
      expect(text).to include("Databases: 2")
    end

    it "skips sections that have errors" do
      ctx = {
        auth: { error: "not available" },
        turbo: { error: "not available" },
        i18n: { error: "not available" }
      }
      helper = test_class.new(ctx)
      expect(helper.full_preset_stack_lines).to eq([])
    end
  end
end
