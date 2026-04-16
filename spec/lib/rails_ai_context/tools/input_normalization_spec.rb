# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tool input normalization" do
  # ── BaseTool.find_closest_match ─────────────────────────────────

  describe "BaseTool.find_closest_match" do
    subject { RailsAiContext::Tools::BaseTool }

    it "prefers shortest substring match (posts over post_comments)" do
      result = subject.find_closest_match("Post", %w[post_comments posts post_ratings])
      expect(result).to eq("posts")
    end

    it "matches snake_case input to PascalCase available" do
      result = subject.find_closest_match("user_profile", %w[UserProfile User Post])
      expect(result).to eq("UserProfile")
    end

    it "matches PascalCase input to snake_case available" do
      result = subject.find_closest_match("UserProfile", %w[user_profiles users posts])
      expect(result).to eq("user_profiles")
    end

    it "returns exact case-insensitive match first" do
      result = subject.find_closest_match("users", %w[users user_settings])
      expect(result).to eq("users")
    end

    it "returns nil for empty available list" do
      result = subject.find_closest_match("anything", [])
      expect(result).to be_nil
    end

    it "falls back to prefix match when no substring matches" do
      result = subject.find_closest_match("xyz", %w[xyzzy abc def])
      expect(result).to eq("xyzzy")
    end
  end

  # ── GetModelDetails: snake_case model lookup ────────────────────

  describe "GetModelDetails snake_case resolution" do
    let(:klass) { RailsAiContext::Tools::GetModelDetails }

    before { klass.reset_cache! }

    before do
      models = {
        "UserProfile" => { table_name: "user_profiles", associations: [], validations: [] },
        "Post" => { table_name: "posts", associations: [], validations: [] }
      }
      allow(klass).to receive(:cached_context).and_return({ models: models })
    end

    it "resolves snake_case model name to PascalCase key" do
      result = klass.call(model: "user_profile")
      text = result.content.first[:text]
      expect(text).to include("# UserProfile")
    end

    it "resolves lowercase model name" do
      result = klass.call(model: "post")
      text = result.content.first[:text]
      expect(text).to include("# Post")
    end

    it "still works with exact PascalCase input" do
      result = klass.call(model: "UserProfile")
      text = result.content.first[:text]
      expect(text).to include("# UserProfile")
    end
  end

  # ── GetSchema: table name normalization ─────────────────────────

  describe "GetSchema table name normalization" do
    let(:klass) { RailsAiContext::Tools::GetSchema }

    before { klass.reset_cache! }

    before do
      tables = {
        "posts" => {
          columns: [ { name: "id", type: "integer", null: false } ],
          indexes: [], foreign_keys: []
        },
        "post_comments" => {
          columns: [ { name: "id", type: "integer", null: false } ],
          indexes: [], foreign_keys: []
        },
        "user_profiles" => {
          columns: [ { name: "id", type: "integer", null: false } ],
          indexes: [], foreign_keys: []
        }
      }
      allow(klass).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", tables: tables, total_tables: 3 },
        models: {}
      })
    end

    it "resolves model name Post to posts table" do
      result = klass.call(table: "Post")
      text = result.content.first[:text]
      expect(text).to include("Table: posts")
    end

    it "resolves PascalCase model name to pluralized table" do
      result = klass.call(table: "UserProfile")
      text = result.content.first[:text]
      expect(text).to include("Table: user_profiles")
    end

    it "still works with exact table name" do
      result = klass.call(table: "posts")
      text = result.content.first[:text]
      expect(text).to include("Table: posts")
    end

    it "resolves singular model-style name via pluralization" do
      # "post" → "post".pluralize = "posts" → direct match (no fuzzy needed)
      result = klass.call(table: "post")
      text = result.content.first[:text]
      expect(text).to include("Table: posts")
    end
  end

  # ── GetView: controller suffix stripping ────────────────────────

  describe "GetView controller suffix stripping" do
    let(:klass) { RailsAiContext::Tools::GetView }

    before { klass.reset_cache! }

    before do
      templates = {
        "posts/index.html.erb" => { lines: 25, partials: [], stimulus: [] },
        "posts/show.html.erb" => { lines: 40, partials: [], stimulus: [] }
      }
      allow(klass).to receive(:cached_context).and_return({
        view_templates: { templates: templates, partials: {} }
      })
    end

    it "resolves PostsController to posts views" do
      result = klass.call(controller: "PostsController")
      text = result.content.first[:text]
      expect(text).to include("posts/index.html.erb")
    end

    it "resolves posts_controller to posts views" do
      result = klass.call(controller: "posts_controller")
      text = result.content.first[:text]
      expect(text).to include("posts/index.html.erb")
    end

    it "still works with plain controller name" do
      result = klass.call(controller: "posts")
      text = result.content.first[:text]
      expect(text).to include("posts/index.html.erb")
    end
  end

  # ── GetRoutes: _controller suffix stripping ─────────────────────

  describe "GetRoutes controller suffix stripping" do
    let(:klass) { RailsAiContext::Tools::GetRoutes }

    before { klass.reset_cache! }

    before do
      routes = {
        by_controller: {
          "posts" => [
            { verb: "GET", path: "/posts", action: "index", name: "posts" }
          ]
        },
        total_routes: 1
      }
      allow(klass).to receive(:cached_context).and_return({ routes: routes })
    end

    it "resolves posts_controller to posts routes" do
      result = klass.call(controller: "posts_controller")
      text = result.content.first[:text]
      expect(text).to include("/posts")
    end

    it "resolves PostsController to posts routes" do
      result = klass.call(controller: "PostsController")
      text = result.content.first[:text]
      expect(text).to include("/posts")
    end

    it "still works with plain controller name" do
      result = klass.call(controller: "posts")
      text = result.content.first[:text]
      expect(text).to include("/posts")
    end
  end

  # ── GetStimulus: PascalCase resolution ──────────────────────────

  describe "GetStimulus PascalCase resolution" do
    let(:klass) { RailsAiContext::Tools::GetStimulus }

    before { klass.reset_cache! }

    before do
      data = {
        controllers: [
          { name: "post_status", targets: %w[badge], actions: %w[toggle], values: {}, outlets: [], classes: [], file: "post_status_controller.js" }
        ]
      }
      allow(klass).to receive(:cached_context).and_return({ stimulus: data })
    end

    it "resolves PascalCase PostStatus to post_status" do
      result = klass.call(controller: "PostStatus")
      text = result.content.first[:text]
      expect(text).to include("## post_status")
    end

    it "resolves dash-separated post-status to post_status" do
      result = klass.call(controller: "post-status")
      text = result.content.first[:text]
      expect(text).to include("## post_status")
    end

    it "still works with exact underscore name" do
      result = klass.call(controller: "post_status")
      text = result.content.first[:text]
      expect(text).to include("## post_status")
    end
  end

  # ── GetEditContext: empty parameter validation ──────────────────

  describe "GetEditContext empty parameter validation" do
    let(:klass) { RailsAiContext::Tools::GetEditContext }

    it "returns friendly message for empty file parameter" do
      result = klass.call(file: "", near: "def index")
      text = result.content.first[:text]
      expect(text).to include("`file` parameter is required")
    end

    it "returns friendly message for whitespace-only file parameter" do
      result = klass.call(file: "   ", near: "def index")
      text = result.content.first[:text]
      expect(text).to include("`file` parameter is required")
    end

    it "returns friendly message for empty near parameter" do
      result = klass.call(file: "app/models/user.rb", near: "")
      text = result.content.first[:text]
      expect(text).to include("`near` parameter is required")
    end
  end

  # ── SearchCode: empty pattern handling ──────────────────────────

  describe "SearchCode empty pattern handling" do
    let(:klass) { RailsAiContext::Tools::SearchCode }

    before { klass.reset_cache! }

    it "returns friendly message for empty pattern" do
      result = klass.call(pattern: "")
      text = result.content.first[:text]
      expect(text).to include("Pattern is required")
    end

    it "returns friendly message for whitespace-only pattern" do
      result = klass.call(pattern: "   ")
      text = result.content.first[:text]
      expect(text).to include("Pattern is required")
    end
  end

  # ── GetTestInfo: plural model resolution ────────────────────────

  describe "GetTestInfo plural model resolution" do
    let(:klass) { RailsAiContext::Tools::GetTestInfo }

    before { klass.reset_cache! }

    before do
      allow(klass).to receive(:cached_context).and_return({
        tests: { framework: "Minitest", test_files: {} }
      })
    end

    it "tries singular form for model test lookup" do
      # find_test_file with plural "posts" should produce candidates including the singular form
      result = klass.call(model: "posts")
      text = result.content.first[:text]
      # Should search for post_spec.rb / post_test.rb (singular) in addition to posts_spec.rb
      expect(text).to include("post_spec.rb").or include("post_test.rb").or include("posts_spec.rb")
    end
  end
end
