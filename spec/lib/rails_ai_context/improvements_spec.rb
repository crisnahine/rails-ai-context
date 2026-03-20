# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Token-saving improvements" do
  describe "Improvement 1: UI pattern extraction" do
    let(:introspector) { RailsAiContext::Introspectors::ViewTemplateIntrospector.new(Rails.application) }

    it "returns ui_patterns key" do
      result = introspector.call
      expect(result).to have_key(:ui_patterns)
      expect(result[:ui_patterns]).to be_a(Hash)
    end

    it "extracts patterns from views with repeated classes" do
      Dir.mktmpdir do |dir|
        views_dir = File.join(dir, "app", "views", "posts")
        FileUtils.mkdir_p(views_dir)
        # Create two views with repeated class patterns
        content = '<div class="bg-white rounded-xl p-4 shadow-sm border border-gray-100">card</div>'
        File.write(File.join(views_dir, "index.html.erb"), content * 3)
        File.write(File.join(views_dir, "show.html.erb"), content * 2)

        app = double("app", root: Pathname.new(dir))
        result = RailsAiContext::Introspectors::ViewTemplateIntrospector.new(app).call
        expect(result[:ui_patterns]).to be_a(Hash)
      end
    end

    it "includes UI Patterns in ClaudeSerializer compact output" do
      context = RailsAiContext.introspect
      context[:view_templates] = {
        ui_patterns: { components: [ { type: :button, label: "Button (primary)", classes: "bg-orange-600 text-white px-4 py-2 rounded-xl hover:bg-orange-700" } ], color_scheme: { primary: "orange" } }
      }
      output = RailsAiContext::Serializers::ClaudeSerializer.new(context).call
      expect(output).to include("UI Patterns")
      expect(output).to include("bg-orange-600")
    end

    it "includes UI Patterns in OpencodeSerializer compact output" do
      context = RailsAiContext.introspect
      context[:view_templates] = {
        ui_patterns: { components: [ { type: :card, label: "Card", classes: "bg-white rounded-2xl p-6 shadow-sm" } ] }
      }
      output = RailsAiContext::Serializers::OpencodeSerializer.new(context).call
      expect(output).to include("UI Patterns")
    end

    it "includes UI Patterns in CopilotSerializer compact output" do
      context = RailsAiContext.introspect
      context[:view_templates] = {
        ui_patterns: { components: [ { type: :input, label: "Input", classes: "border rounded-lg px-3 py-2 focus:ring-2" } ] }
      }
      output = RailsAiContext::Serializers::CopilotSerializer.new(context).call
      expect(output).to include("UI Patterns")
    end

    it "generates rails-ui-patterns.md in Claude rules" do
      context = RailsAiContext.introspect
      context[:view_templates] = {
        ui_patterns: { components: [ { type: :button, label: "Button (primary)", classes: "bg-orange-600 text-white rounded-xl" } ] }
      }
      Dir.mktmpdir do |dir|
        result = RailsAiContext::Serializers::ClaudeRulesSerializer.new(context).call(dir)
        ui_file = File.join(dir, ".claude", "rules", "rails-ui-patterns.md")
        expect(File.exist?(ui_file)).to be true
        expect(File.read(ui_file)).to include("bg-orange-600")
      end
    end

    it "generates rails-ui-patterns.mdc in Cursor rules" do
      context = RailsAiContext.introspect
      context[:view_templates] = {
        ui_patterns: { components: [ { type: :card, label: "Card", classes: "bg-white rounded-xl shadow-sm" } ] }
      }
      Dir.mktmpdir do |dir|
        result = RailsAiContext::Serializers::CursorRulesSerializer.new(context).call(dir)
        ui_file = File.join(dir, ".cursor", "rules", "rails-ui-patterns.mdc")
        expect(File.exist?(ui_file)).to be true
        expect(File.read(ui_file)).to include("bg-white")
      end
    end

    it "generates rails-ui-patterns.instructions.md in Copilot rules" do
      context = RailsAiContext.introspect
      context[:view_templates] = {
        ui_patterns: { components: [ { type: :label, label: "Label", classes: "block text-sm font-semibold" } ] }
      }
      Dir.mktmpdir do |dir|
        result = RailsAiContext::Serializers::CopilotInstructionsSerializer.new(context).call(dir)
        ui_file = File.join(dir, ".github", "instructions", "rails-ui-patterns.instructions.md")
        expect(File.exist?(ui_file)).to be true
        expect(File.read(ui_file)).to include("font-semibold")
      end
    end
  end

  describe "Improvement 2: View partial structure" do
    it "extracts model fields from partials" do
      introspector = RailsAiContext::Introspectors::ViewTemplateIntrospector.new(Rails.application)
      result = introspector.call
      partials = result[:partials] || {}
      partials.each_value do |meta|
        expect(meta).to have_key(:fields)
        expect(meta).to have_key(:helpers)
      end
    end

    it "shows partial fields in rails_get_view standard detail" do
      context = RailsAiContext.introspect
      context[:view_templates] = {
        templates: { "cooks/show.html.erb" => { lines: 50, partials: [ "cooks/output" ], stimulus: [ "cook-status" ] } },
        partials: { "cooks/_output.html.erb" => { lines: 100, fields: %w[confidence_score strategy_brief], helpers: %w[render_markdown] } },
        ui_patterns: {}
      }
      allow(RailsAiContext::Tools::GetView).to receive(:cached_context).and_return(context)
      result = RailsAiContext::Tools::GetView.call(controller: "cooks", detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("_output.html.erb")
      expect(text).to include("confidence_score")
      expect(text).to include("render_markdown")
    end
  end

  describe "Improvement 3: Column names in schema rules" do
    let(:schema_context) do
      {
        app_name: "TestApp", rails_version: "8.0", ruby_version: "3.4",
        schema: {
          adapter: "postgresql", total_tables: 2,
          tables: {
            "posts" => {
              columns: [
                { name: "id", type: "bigint" },
                { name: "title", type: "string" },
                { name: "body", type: "text" },
                { name: "user_id", type: "bigint" },
                { name: "type", type: "string" },
                { name: "deleted_at", type: "datetime" },
                { name: "created_at", type: "datetime" },
                { name: "updated_at", type: "datetime" }
              ],
              primary_key: "id"
            },
            "users" => {
              columns: [
                { name: "id", type: "bigint" },
                { name: "email", type: "string" },
                { name: "name", type: "string" },
                { name: "created_at", type: "datetime" },
                { name: "updated_at", type: "datetime" }
              ],
              primary_key: "id"
            }
          }
        },
        models: {}, routes: { total_routes: 0 }, gems: {}, conventions: {},
        view_templates: { ui_patterns: {} }
      }
    end

    it "includes column names in Claude schema rules" do
      Dir.mktmpdir do |dir|
        RailsAiContext::Serializers::ClaudeRulesSerializer.new(schema_context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-schema.md"))
        expect(content).to include("title")
        expect(content).to include("body")
        expect(content).to include("email")
      end
    end

    it "excludes id, timestamps, and foreign keys from column list" do
      Dir.mktmpdir do |dir|
        RailsAiContext::Serializers::ClaudeRulesSerializer.new(schema_context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-schema.md"))
        lines = content.lines.select { |l| l.start_with?("- ") }
        lines.each do |line|
          next unless line.include?("—")
          cols_part = line.split("—").last
          expect(cols_part).not_to include("created_at")
          expect(cols_part).not_to include("updated_at")
          expect(cols_part).not_to include("user_id")
        end
      end
    end

    it "keeps polymorphic type, STI type, and soft-delete columns" do
      Dir.mktmpdir do |dir|
        RailsAiContext::Serializers::ClaudeRulesSerializer.new(schema_context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-schema.md"))
        posts_line = content.lines.find { |l| l.include?("posts") }
        expect(posts_line).to include("type")
        expect(posts_line).to include("deleted_at")
      end
    end
  end
end
