# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::ClaudeRulesSerializer do
  let(:context) do
    serializer_context(
      schema: {
        adapter: "postgresql",
        total_tables: 2,
        tables: {
          "users" => { columns: [ { name: "id" }, { name: "email" } ], primary_key: "id" },
          "posts" => { columns: [ { name: "id" }, { name: "title" } ], primary_key: "id" }
        }
      },
      routes: { total_routes: 20 }
    )
  end

  it "writes a partial unique index with its condition" do
    ctx = serializer_context(schema: { adapter: "postgresql", total_tables: 1, tables: {
      "articles" => { columns: [ { name: "id" }, { name: "canonical_url" } ], primary_key: "id",
                      indexes: [ { name: "i", columns: [ "canonical_url" ], unique: true, where: "(published IS TRUE)" } ] }
    } })

    Dir.mktmpdir do |dir|
      described_class.new(ctx).call(dir)

      expect(File.read(File.join(dir, ".claude", "rules", "rails-schema.md")))
        .to include("Idx: canonical_url(unique where (published IS TRUE))")
    end
  end

  # Discourse writes `enum :status, Statuses.to_h`; the rules printed [INFERRED] as its value.
  it "writes a computed enum as its source, marked computed" do
    ctx = serializer_context(models: {
      "Topic" => { associations: [ { type: :has_many, name: :posts } ], validations: [], table_name: "topics",
                   enums: { "status" => "Statuses.to_h", "kind" => { "a" => 0, "b" => 1 } } }
    })

    Dir.mktmpdir do |dir|
      described_class.new(ctx).call(dir)
      content = File.read(File.join(dir, ".claude", "rules", "rails-models.md"))

      expect(content).to include("  status: `Statuses.to_h` (computed)", "  kind: a, b")
      expect(content).not_to include("[INFERRED]")
    end
  end

  it "summarizes a foreign key over two columns as the column list" do
    ctx = serializer_context(schema: { adapter: "postgresql", total_tables: 1, tables: {
      "posts" => { columns: [ { name: "id" }, { name: "user_id" } ], primary_key: "id",
                   foreign_keys: [ { column: "author_id", to_table: "authors", primary_key: "id" },
                                   { column: %w[user_id user_day], to_table: "users", primary_key: %w[id day] } ] }
    } })

    Dir.mktmpdir do |dir|
      described_class.new(ctx).call(dir)
      content = File.read(File.join(dir, ".claude", "rules", "rails-schema.md"))

      expect(content).to include("FK: author_id→authors, (user_id, user_day)→users")
    end
  end

  it "generates .claude/rules/ files" do
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].size).to eq(4)

      schema_file = File.join(dir, ".claude", "rules", "rails-schema.md")
      expect(File.exist?(schema_file)).to be true
      content = File.read(schema_file)
      expect(content).to include("users")
      expect(content).to include("rails_get_schema")

      models_file = File.join(dir, ".claude", "rules", "rails-models.md")
      expect(File.exist?(models_file)).to be true
      content = File.read(models_file)
      expect(content).to include("User")
      expect(content).to include("rails_get_model_details")

      tools_file = File.join(dir, ".claude", "rules", "rails-mcp-tools.md")
      expect(File.exist?(tools_file)).to be true
      content = File.read(tools_file)
      expect(content).to include("Tools (#{RailsAiContext::Server::TOOLS.size})")
      expect(content).to include("rails_get_schema")
      expect(content).to include('detail:"summary"')
    end
  end

  # Claude Code loads CLAUDE.md and every rule without paths: on each
  # request, so a whole guide here put the guide and the protocol in front
  # of the AI twice.
  describe "rails-mcp-tools.md" do
    def tools_rule(dir)
      described_class.new(context).call(dir)
      File.read(File.join(dir, ".claude", "rules", "rails-mcp-tools.md"))
    end

    it "carries the reference CLAUDE.md leaves out, and points to CLAUDE.md for the rest" do
      Dir.mktmpdir do |dir|
        content = tools_rule(dir)

        expect(content).to start_with("## Tools (#{RailsAiContext::Server.exposed_tools.size}) - Reference")
        expect(content).to include("is in CLAUDE.md", "### detail parameter", "| `rails_get_schema(table:\"X\")` |")
        expect(content).not_to include("Anti-Hallucination Protocol", "Step-by-step workflows")
      end
    end

    it "carries the whole guide when no CLAUDE.md is written" do
      allow(RailsAiContext.configuration).to receive(:generate_root_files).and_return(false)

      Dir.mktmpdir do |dir|
        expect(tools_rule(dir)).to include("Anti-Hallucination Protocol", "Step-by-step workflows", "| `rails_get_schema(table:\"X\")` |")
      end
    end
  end

  it "skips unchanged files" do
    Dir.mktmpdir do |dir|
      first = described_class.new(context).call(dir)
      expect(first[:written].size).to eq(4)

      second = described_class.new(context).call(dir)
      expect(second[:written].size).to eq(0)
      expect(second[:skipped].size).to eq(4)
    end
  end

  it "skips schema rule when no tables" do
    context[:schema] = { adapter: "postgresql", tables: {} }
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].size).to eq(3) # context + models + mcp-tools
    end
  end

  it "skips models rule when no models" do
    context[:models] = {}
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].size).to eq(3) # context + schema + mcp-tools
    end
  end

  describe "paths: frontmatter" do
    it "includes paths: frontmatter on schema rule" do
      Dir.mktmpdir do |dir|
        described_class.new(context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-schema.md"))
        expect(content).to start_with("---")
        expect(content).to include('- "db/schema.rb"')
        expect(content).to include('- "db/migrate/**"')
      end
    end

    # The auto-attach glob has to name the dump file the app actually committed,
    # or the rule never fires on a :sql app: db/schema.rb is never opened there.
    #
    # Rails 7.1 moved schema_format from ActiveRecord::Base to ActiveRecord.
    # Only one of the two is real on any given matrix leg, so each is pinned
    # here by making it the one that answers.
    [ ActiveRecord, ActiveRecord::Base ].each do |owner|
      context "with schema_format on #{owner}" do
        # The accessor the running Rails does not have has to be conjured, so
        # partial-double verification is off for the stubbing itself.
        def stub_schema_format(owner, value)
          without_partial_double_verification do
            [ ActiveRecord, ActiveRecord::Base ].each do |mod|
              allow(mod).to receive(:respond_to?).and_call_original
              allow(mod).to receive(:respond_to?).with(:schema_format).and_return(mod == owner)
            end
            allow(owner).to receive(:schema_format).and_return(value)
          end
        end

        it "names db/structure.sql when the app configures :sql" do
          Dir.mktmpdir do |dir|
            FileUtils.mkdir_p(File.join(dir, "db"))
            File.write(File.join(dir, "db", "schema.rb"), "# stale\n")
            allow(Rails).to receive(:root).and_return(Pathname.new(dir))
            stub_schema_format(owner, :sql)

            described_class.new(context).call(dir)
            content = File.read(File.join(dir, ".claude", "rules", "rails-schema.md"))
            expect(content).to include('- "db/structure.sql"')
            expect(content).not_to include('- "db/schema.rb"')
          end
        end

        it "names db/schema.rb when the app configures :ruby" do
          Dir.mktmpdir do |dir|
            FileUtils.mkdir_p(File.join(dir, "db"))
            File.write(File.join(dir, "db", "structure.sql"), "CREATE TABLE users (id integer);\n")
            allow(Rails).to receive(:root).and_return(Pathname.new(dir))
            stub_schema_format(owner, :ruby)

            described_class.new(context).call(dir)
            content = File.read(File.join(dir, ".claude", "rules", "rails-schema.md"))
            expect(content).to include('- "db/schema.rb"')
            expect(content).not_to include('- "db/structure.sql"')
          end
        end
      end
    end

    # The static tier, where nothing is loaded and the dump on disk is the
    # only evidence there is.
    it "names db/structure.sql from disk when no configuration is reachable" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "db", "structure.sql"), "CREATE TABLE users (id integer);\n")
        allow(Rails).to receive(:root).and_return(Pathname.new(dir))
        hide_const("ActiveRecord")

        described_class.new(context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-schema.md"))
        expect(content).to include('- "db/structure.sql"')
        expect(content).not_to include('- "db/schema.rb"')
      end
    end

    it "includes paths: frontmatter on models rule" do
      Dir.mktmpdir do |dir|
        described_class.new(context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-models.md"))
        expect(content).to start_with("---")
        expect(content).to include('- "app/models/**/*.rb"')
      end
    end

    it "does NOT include paths: frontmatter on context rule" do
      Dir.mktmpdir do |dir|
        described_class.new(context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-context.md"))
        expect(content).not_to start_with("---")
      end
    end

    it "does NOT include paths: frontmatter on mcp-tools rule" do
      Dir.mktmpdir do |dir|
        described_class.new(context).call(dir)
        content = File.read(File.join(dir, ".claude", "rules", "rails-mcp-tools.md"))
        expect(content).not_to start_with("---")
      end
    end
  end

  # A Rails 7.1 app with a SQLite analytics database beside its PostgreSQL
  # primary: the rule listed the primary's tables, and its paths missed
  # db/analytics_schema.rb and db/analytics_migrate/**.
  describe "an app with more than one database" do
    let(:multi_context) do
      serializer_context(
        schema: {
          adapter: "postgresql", total_tables: 2,
          tables: {
            "users" => { columns: [ { name: "id" }, { name: "email", type: "string" } ], primary_key: "id" },
            "settings" => { columns: [ { name: "id" }, { name: "key", type: "string" } ], primary_key: "id" }
          },
          secondary_databases: {
            "analytics" => {
              adapter: "static_parse", total_tables: 2,
              tables: {
                "page_views" => { columns: [ { name: "id" }, { name: "path", type: "string" } ], primary_key: "id" },
                "settings" => { columns: [ { name: "id" }, { name: "metric", type: "string" } ], primary_key: "id" }
              },
              note: "Parsed from db/analytics_schema.rb (from committed dump, not a live connection)",
              dump: "db/analytics_schema.rb", migrations_paths: [ "db/analytics_migrate" ]
            }
          }
        },
        multi_database: { databases: [ { name: "primary", adapter: "postgresql" }, { name: "analytics", adapter: "sqlite3" } ] },
        models: {
          "Setting" => { associations: [], validations: [], table_name: "settings", enums: { "scope" => { "global" => 0 } } },
          "Analytics::Setting" => { associations: [], validations: [], table_name: "settings", database: { writing: "analytics" },
                                    enums: { "period" => { "daily" => 0, "weekly" => 1 } } }
        }
      )
    end

    def schema_rule(ctx)
      Dir.mktmpdir do |dir|
        described_class.new(ctx).call(dir)
        File.read(File.join(dir, ".claude", "rules", "rails-schema.md"))
      end
    end

    it "triggers on every database's dump and migrations" do
      expect(schema_rule(multi_context)).to start_with(<<~FRONTMATTER)
        ---
        paths:
          - "db/schema.rb"
          - "db/migrate/**"
          - "db/analytics_schema.rb"
          - "db/analytics_migrate/**"
        ---
      FRONTMATTER
    end

    it "lists every database's tables under a heading naming the database" do
      content = schema_rule(multi_context)

      expect(content).to include("# Database Tables (4)")
      expect(content).to include("## primary (PostgreSQL, 2 tables)\n\n- **settings** (2 cols) - key:string\n")
      expect(content).to include("## analytics (SQLite, 2 tables)\n\n" \
                                 "_Parsed from db/analytics_schema.rb (from committed dump, not a live connection)._\n\n" \
                                 "- **page_views** (2 cols) - path:string\n- **settings** (2 cols) - metric:string\n")
    end

    it "puts each settings table's enums under its own database" do
      primary, analytics = schema_rule(multi_context).split("## analytics")

      expect(primary).to include("scope: global")
      expect(primary).not_to include("period:")
      expect(analytics).to include("period: daily, weekly")
      expect(analytics).not_to include("scope:")
    end

    it "names the database when only another database has tables" do
      multi_context[:schema][:tables] = {}

      content = schema_rule(multi_context)

      expect(content).to include("# Database Tables (2)", "## analytics (SQLite, 2 tables)")
      expect(content).not_to include("## primary")
    end

    it "keeps a single-database app's rule without database headings" do
      expect(schema_rule(context)).not_to include("## primary")
    end

    # Rails 8's queue, cache and cable databases: the framework's tables, read
    # on every load of the rule, said nothing about the app.
    it "leaves out a database a Rails framework keeps to itself" do
      multi_context[:schema][:secondary_databases]["queue"] = {
        adapter: "static_parse", total_tables: 2, dump: "db/queue_schema.rb",
        tables: { "solid_queue_jobs" => { columns: [ { name: "id" } ] }, "solid_queue_processes" => { columns: [ { name: "id" } ] } }
      }

      content = schema_rule(multi_context)

      expect(content).to include("# Database Tables (4)", "## analytics (SQLite, 2 tables)", "- **page_views**")
      expect(content).not_to include("queue", "solid_queue")
    end

    it "keeps a Rails 8 app's rule as a single database's" do
      context[:schema][:secondary_databases] = {
        "cache" => { adapter: "static_parse", total_tables: 1, dump: "db/cache_schema.rb", tables: { "solid_cache_entries" => { columns: [] } } }
      }

      expect(schema_rule(context)).to eq(schema_rule(context.merge(schema: context[:schema].except(:secondary_databases))))
    end
  end

  it "names the files it did not generate and why" do
    context[:models] = {}
    context[:schema] = { tables: {} }
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      rules = File.join(dir, ".claude", "rules")

      expect(result[:not_applicable]).to eq(
        File.join(rules, "rails-schema.md") => "no schema dump",
        File.join(rules, "rails-models.md") => "no models",
        File.join(rules, "rails-components.md") => "no view components"
      )
      expect(File.exist?(File.join(rules, "rails-models.md"))).to be false
    end
  end
end
