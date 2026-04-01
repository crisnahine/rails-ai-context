# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::ClaudeSerializer do
  describe "compact mode" do
    before { RailsAiContext.configuration.context_mode = :compact }
    after { RailsAiContext.configuration.context_mode = :compact }

    it "generates ≤150 lines for a large app" do
      models = 200.times.each_with_object({}) do |i, h|
        h["Model#{i}"] = {
          associations: 5.times.map { |j| { type: "has_many", name: "rel_#{j}" } },
          validations: 3.times.map { |j| { kind: "presence", attributes: [ "attr_#{j}" ] } },
          table_name: "model_#{i}s"
        }
      end

      context = {
        app_name: "BigApp", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601,
        schema: { adapter: "postgresql", tables: {}, total_tables: 180 },
        models: models,
        routes: { total_routes: 1500, by_controller: {} },
        gems: { notable: [ { name: "devise", category: :auth } ] },
        conventions: { architecture: [ "MVC", "Service objects" ], patterns: [], config_files: [] },
        jobs: { jobs: [], mailers: [], channels: [] },
        auth: { authentication: {}, authorization: {} },
        migrations: { total: 500, pending: [] }
      }

      output = described_class.new(context).call
      line_count = output.lines.count

      expect(line_count).to be <= 175
      expect(output).to include("MCP tools")
      expect(output).to include("rails_get_schema")
      expect(output).to include('detail:"summary"')
    end

    it "includes key models capped at 15" do
      models = 30.times.each_with_object({}) do |i, h|
        h["Model#{i.to_s.rjust(2, '0')}"] = { associations: [], validations: [] }
      end

      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601, schema: {}, models: models,
        routes: {}, gems: {}, conventions: {}
      }

      output = described_class.new(context).call
      expect(output).to include("...15 more")
    end

    it "includes app name and version" do
      context = {
        app_name: "MyApp", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601
      }
      output = described_class.new(context).call
      expect(output).to include("MyApp")
      expect(output).to include("Rails 8.0")
    end
  end

  describe "full mode" do
    before { RailsAiContext.configuration.context_mode = :full }
    after { RailsAiContext.configuration.context_mode = :compact }

    it "delegates to FullClaudeSerializer (MarkdownSerializer)" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601
      }
      output = described_class.new(context).call
      expect(output).to be_a(String)
      expect(output).to include("Claude Code")
    end
  end

  describe "scope name rendering" do
    before { RailsAiContext.configuration.context_mode = :compact }
    after  { RailsAiContext.configuration.context_mode = :compact }

    it "renders scope names from hash-style scopes, not garbled hash output" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601,
        models: {
          "User" => {
            associations: [],
            validations: [],
            scopes: [ { name: "active", body: "where(active: true)" }, { name: "recent", body: "order(created_at: :desc)" } ],
            constants: []
          }
        }
      }

      output = described_class.new(context).call
      expect(output).to include("scopes: active, recent")
      expect(output).not_to include("{:name=>")
      expect(output).not_to include("body")
    end
  end

  describe "test command" do
    let(:base_context) do
      {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601
      }
    end

    context "compact mode" do
      before { RailsAiContext.configuration.context_mode = :compact }
      after  { RailsAiContext.configuration.context_mode = :compact }

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

    context "full mode" do
      before { RailsAiContext.configuration.context_mode = :full }
      after  { RailsAiContext.configuration.context_mode = :compact }

      it "uses rails test for minitest projects" do
        output = described_class.new(base_context.merge(tests: { framework: "minitest" })).call
        expect(output).to include("rails test")
        expect(output).not_to include("bundle exec rspec")
      end

      it "uses bundle exec rspec for rspec projects" do
        output = described_class.new(base_context.merge(tests: { framework: "rspec" })).call
        expect(output).to include("bundle exec rspec")
      end
    end
  end
end
