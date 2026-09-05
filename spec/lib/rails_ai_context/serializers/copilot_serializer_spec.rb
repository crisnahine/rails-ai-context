# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::CopilotSerializer do
  describe "compact mode" do
    before { RailsAiContext.configuration.context_mode = :compact }
    after { RailsAiContext.configuration.context_mode = :compact }

    it "generates compact output with MCP tool references" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        schema: { adapter: "postgresql", total_tables: 10 },
        models: { "User" => { associations: [ { type: "has_many", name: "posts" } ], validations: [] } },
        routes: { total_routes: 50, by_controller: { "users" => [] } },
        gems: {}, conventions: {}
      }

      output = described_class.new(context).call
      expect(output).to include("Copilot Context")
      expect(output).to include("MCP tools")
      expect(output).to include("rails_get_schema")
    end

    it "includes model associations" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        models: { "User" => { associations: [ { type: "has_many", name: "posts" } ] } },
        schema: {}, routes: {}, gems: {}, conventions: {}
      }

      output = described_class.new(context).call
      expect(output).to include("has_many :posts")
    end
  end

  describe "test command" do
    before { RailsAiContext.configuration.context_mode = :compact }
    after  { RailsAiContext.configuration.context_mode = :compact }

    let(:base_context) do
      {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        schema: {}, models: {}, routes: {}, gems: {}, conventions: {}
      }
    end

    it "uses rails test for minitest projects" do
      output = described_class.new(base_context.merge(tests: { framework: "minitest" })).call
      expect(output).to include("rails test")
      expect(output).not_to include("bundle exec rspec")
    end

    it "uses bundle exec rspec for rspec projects" do
      output = described_class.new(base_context.merge(tests: { framework: "rspec" })).call
      expect(output).to include("bundle exec rspec")
      expect(output).not_to include("rails test")
    end

    it "defaults to rails test when framework is unknown" do
      output = described_class.new(base_context).call
      expect(output).to include("rails test")
    end
  end

  describe "full mode" do
    before { RailsAiContext.configuration.context_mode = :full }
    after { RailsAiContext.configuration.context_mode = :compact }

    it "delegates to FullCopilotSerializer (MarkdownSerializer)" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601
      }
      output = described_class.new(context).call
      expect(output).to be_a(String)
      expect(output).to include("Copilot Instructions")
    end

    # The tier note sits on its own line and every sibling header follows it
    # with the prose directly. Copilot's kept a blank line there too, so the
    # rendered header carried two.
    it "leaves one blank line between the header block and the prose" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601
      }
      output = described_class.new(context).call

      expect(output).to include("v#{RailsAiContext::VERSION}\n\nUse this context")
    end
  end
end
