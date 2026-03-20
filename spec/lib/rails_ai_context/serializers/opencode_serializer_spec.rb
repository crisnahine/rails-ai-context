# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::OpencodeSerializer do
  describe "#call" do
    let(:context) do
      {
        app_name: "TestApp", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601,
        schema: { adapter: "sqlite3", tables: {}, total_tables: 5 },
        models: {
          "User" => { associations: [ { type: "has_many", name: "posts" } ], validations: [] },
          "Post" => { associations: [ { type: "belongs_to", name: "user" } ], validations: [] }
        },
        routes: { total_routes: 20, by_controller: { "users" => [], "posts" => [] } },
        gems: { notable_gems: [ { name: "devise", category: :auth } ] },
        conventions: { architecture: [ "MVC" ], patterns: [], config_files: [ "config/routes.rb" ] },
        jobs: { jobs: [], mailers: [], channels: [] },
        auth: { authentication: {}, authorization: {} },
        migrations: { total: 10, pending: [] }
      }
    end

    context "in compact mode (default)" do
      before { RailsAiContext.configuration.context_mode = :compact }
      after { RailsAiContext.configuration.context_mode = :compact }

      it "includes AI Context header" do
        output = described_class.new(context).call
        expect(output).to include("TestApp — AI Context")
      end

      it "includes MCP tools section" do
        output = described_class.new(context).call
        expect(output).to include("MCP Tools (12)")
        expect(output).to include("rails_get_schema")
        expect(output).to include('detail:"summary"')
      end

      it "includes rules section" do
        output = described_class.new(context).call
        expect(output).to include("## Rules")
      end

      it "includes stack overview" do
        output = described_class.new(context).call
        expect(output).to include("## Stack")
        expect(output).to include("sqlite3")
        expect(output).to include("5 tables")
      end

      it "includes key models" do
        output = described_class.new(context).call
        expect(output).to include("User")
        expect(output).to include("Post")
      end
    end

    context "in full mode" do
      before { RailsAiContext.configuration.context_mode = :full }
      after { RailsAiContext.configuration.context_mode = :compact }

      it "delegates to FullOpencodeSerializer (MarkdownSerializer)" do
        output = described_class.new(context).call
        expect(output).to be_a(String)
        expect(output).to include("OpenCode")
      end
    end
  end
end
