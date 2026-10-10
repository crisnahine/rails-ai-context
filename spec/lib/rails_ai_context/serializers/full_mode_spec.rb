# frozen_string_literal: true

require "spec_helper"

# context_mode :full handed the root files to MarkdownSerializer, which had no
# tools guide: CLAUDE.md, AGENTS.md and copilot-instructions.md lost the
# protocol and every tool reference, and OpenCode and Codex, which load
# AGENTS.md alone, got neither. The "full dump" also said less than the
# compact files in places.
RSpec.describe "full mode's root files" do
  around do |example|
    config = RailsAiContext.configuration
    saved = config.context_mode, config.tool_mode, config.anti_hallucination_rules
    config.context_mode = :full
    example.run
  ensure
    config.context_mode, config.tool_mode, config.anti_hallucination_rules = saved
  end

  let(:context) do
    serializer_context(
      schema: { adapter: "postgresql", total_tables: 1, tables: {
        "posts" => {
          columns: [ { name: "id", type: "integer" }, { name: "published", type: "boolean", default: false },
                     { name: "user_id", type: "integer" } ],
          indexes: [ { columns: [ "user_id" ], unique: false }, { columns: %w[user_id slug], unique: true } ],
          foreign_keys: [ { column: "user_id", to_table: "users" } ]
        }
      } },
      models: {
        "Post" => { table_name: "posts", associations: [], validations: [],
                    scopes: [ { name: "published" } ], callbacks: { before_save: [ "set_slug" ] },
                    enums: { "status" => { "draft" => 0, "live" => 1 } },
                    constants: [ { name: "KINDS", values: %w[news blog] } ] }
      },
      routes: { total_routes: 6, by_controller: {
        "posts" => [ { verb: "GET", path: "/posts", action: "index" },
                     { verb: "PATCH", path: "/posts/:id", action: "update" },
                     { verb: "PUT", path: "/posts/:id", action: "update" } ],
        "active_storage/disk" => [ { verb: "GET", path: "/rails/active_storage/disk/:key", action: "show" } ],
        "rails/health" => [ { verb: "GET", path: "/up", action: "show" } ]
      } },
      stimulus: { controllers: [ { name: "toggle", targets: %w[content], values: { "open" => "Boolean" }, actions: %w[toggle] } ] },
      devops: { puma: { port: 3000 }, deployment: "kamal" },
      views: { helpers: [ { file: "posts_helper.rb", methods: [] } ] }
    )
  end

  {
    "CLAUDE.md" => RailsAiContext::Serializers::ClaudeSerializer,
    "AGENTS.md" => RailsAiContext::Serializers::OpencodeSerializer,
    ".github/copilot-instructions.md" => RailsAiContext::Serializers::CopilotSerializer
  }.each do |file, serializer|
    it "carries the protocol and the tools guide in #{file}" do
      output = serializer.new(context).call

      expect(output).to include("Anti-Hallucination Protocol", "## Tools (#{RailsAiContext::Server.exposed_tools.size})",
                                "### Step-by-step workflows", "rails_get_context(")
    end

    it "leaves the protocol out of #{file} when anti_hallucination_rules is off" do
      RailsAiContext.configuration.anti_hallucination_rules = false

      output = serializer.new(context).call

      expect(output).not_to include("Anti-Hallucination Protocol")
      expect(output).to include("## Tools (")
    end

    it "names commands in #{file} under tool_mode :cli" do
      RailsAiContext.configuration.tool_mode = :cli

      output = serializer.new(context).call

      expect(output).to include("rails 'ai:tool[context]'")
      expect(output).not_to match(/`rails_get_\w+[`(]/)
    end
  end

  describe "the dump" do
    subject(:output) { RailsAiContext::Serializers::ClaudeSerializer.new(context).call }

    it "gives each column its default and each table its indexes and foreign keys" do
      expect(output).to include("`published` (boolean, default false)")
      expect(output).to include("- Indexes: user_id; user_id+slug (unique)", "- Foreign keys: user_id → users")
    end

    it "states a model's scopes, callbacks, enum values and constants" do
      expect(output).to include("- Scopes: published", "- Callbacks: before_save set_slug",
                                "- Enums: status (draft, live)", "- KINDS: news, blog")
    end

    it "lists the Stimulus controllers" do
      expect(output).to include("## Stimulus Controllers (1)", "- `toggle` - targets: content; values: open (Boolean); actions: toggle")
    end

    # The tools leave framework routes out, and the count merges each
    # PATCH/PUT pair; the listing did neither. The health check is a route
    # the app's own routes.rb declares, so it is the app's.
    it "lists the app's routes as the count has them, and counts the framework's" do
      routes = output[/^## Routes.*?(?=^## )/m]

      expect(routes).to include("3 app routes across 2 routed controllers (6 total incl. framework).",
                                "- `PATCH|PUT /posts/:id` → update", "### rails/health\n- `GET /up` → show",
                                "_Plus 1 framework route (active_storage), not listed._")
      expect(routes).not_to include("active_storage/disk")
    end

    it "leaves out a heading with nothing under it" do
      expect(output).not_to include("## Overview", "### Puma")
      expect(output).to include("- Deployment: kamal", "- `posts_helper.rb` (no methods)")
    end

    it "states every database's schema and migrations" do
      context[:schema][:secondary_databases] = {
        "analytics" => { adapter: "static_parse", total_tables: 1, note: "Parsed from db/analytics_schema.rb (from committed dump, not a live connection)",
                         tables: { "page_views" => { columns: [ { name: "id", type: "integer" }, { name: "path", type: "string" } ] } } },
        "queue" => { adapter: "static_parse", total_tables: 1, tables: { "solid_queue_jobs" => { columns: [ { name: "id", type: "integer" } ] } } }
      }
      context[:migrations] = {
        total: 3, schema_version: "20261009140925", pending: [], recent: [],
        secondary_databases: { "analytics" => { total: 4, migrations_paths: [ "db/analytics_migrate" ],
                                                pending: [ { version: "20261009141117", name: "AddBrowserToPageViews" } ] } }
      }

      expect(output).to include("## Database Schema: primary (1 table)", "## Database Schema: analytics (1 table)",
                                "_Parsed from db/analytics_schema.rb (from committed dump, not a live connection)._",
                                "### page\\_views\n\n`id` (integer), `path` (string)")
      expect(output).to include("- Total: 3 (primary)", "- analytics: 4 total, 1 pending in db/analytics_migrate",
                                "### Pending Migrations: analytics (1)\n- `20261009141117` AddBrowserToPageViews")
      # Solid Queue's database is named, its tables left to the tools.
      expect(output).to include("Framework databases, their tables not listed: queue: Solid Queue (1 table)")
      expect(output).not_to include("solid\\_queue\\_jobs", "Database Schema: queue")
    end
  end
end
