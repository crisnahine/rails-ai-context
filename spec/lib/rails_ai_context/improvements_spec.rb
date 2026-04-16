# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Token-saving improvements" do
  describe "Improvement 1: View template introspection" do
    let(:introspector) { RailsAiContext::Introspectors::ViewTemplateIntrospector.new(Rails.application) }

    it "returns templates and partials keys" do
      result = introspector.call
      expect(result).to have_key(:templates)
      expect(result).to have_key(:partials)
      expect(result[:templates]).to be_a(Hash)
      expect(result[:partials]).to be_a(Hash)
    end

    it "does not include ui_patterns (removed in v5.0.0)" do
      result = introspector.call
      expect(result).not_to have_key(:ui_patterns)
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
        templates: { "posts/show.html.erb" => { lines: 50, partials: [ "posts/output" ], stimulus: [ "post-status" ] } },
        partials: { "posts/_output.html.erb" => { lines: 100, fields: %w[confidence_score strategy_brief], helpers: %w[render_markdown] } }
      }
      allow(RailsAiContext::Tools::GetView).to receive(:cached_context).and_return(context)
      result = RailsAiContext::Tools::GetView.call(controller: "posts", detail: "standard")
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
        view_templates: { templates: {}, partials: {} }
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
