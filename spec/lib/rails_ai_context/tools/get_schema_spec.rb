# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetSchema do
  before { described_class.reset_cache! }

  let(:tables) do
    {
      "users" => {
        columns: [
          { name: "id", type: "integer", null: false },
          { name: "email", type: "string", null: false },
          { name: "name", type: "string", null: true },
          { name: "role", type: "integer", null: true },
          { name: "active", type: "boolean", null: true, default: true },
          { name: "created_at", type: "datetime", null: false },
          { name: "updated_at", type: "datetime", null: false }
        ],
        indexes: [
          { name: "index_users_on_email", columns: [ "email" ], unique: true }
        ],
        foreign_keys: []
      },
      "posts" => {
        columns: [
          { name: "id", type: "integer", null: false },
          { name: "title", type: "string", null: true },
          { name: "body", type: "text", null: true },
          { name: "published", type: "boolean", null: true, default: false },
          { name: "user_id", type: "integer", null: true },
          { name: "created_at", type: "datetime", null: false },
          { name: "updated_at", type: "datetime", null: false }
        ],
        indexes: [],
        foreign_keys: [
          { column: "user_id", to_table: "users", primary_key: "id" }
        ]
      },
      "comments" => {
        columns: [
          { name: "id", type: "integer", null: false },
          { name: "body", type: "text", null: true },
          { name: "post_id", type: "integer", null: true },
          { name: "user_id", type: "integer", null: true }
        ],
        indexes: [],
        foreign_keys: []
      }
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({
      schema: { adapter: "sqlite3", tables: tables, total_tables: 3 },
      models: {}
    })
  end

  describe ".call with no params" do
    it "defaults to standard detail" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Schema (3 tables")
      expect(text).to include("email:string")
    end

    it "sorts tables by column count descending in standard view" do
      result = described_class.call
      text = result.content.first[:text]
      # users has 7 columns, posts has 7, comments has 4
      users_pos = text.index("users")
      comments_pos = text.index("comments")
      expect(users_pos).to be < comments_pos
    end
  end

  # An STI child or a namespaced second model shares its parent's table, and
  # the emptier of the two used to win the listing line on payload order.
  describe "a table more than one model maps to" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "sqlite3", tables: tables, total_tables: 3 },
        models: {
          "Admin::User" => { table_name: "users", associations: [], validations: [] },
          "User" => {
            table_name: "users",
            associations: [ { name: "posts" }, { name: "comments" } ],
            validations: [ { field: "email" } ]
          }
        }
      })
    end

    it "names every model, the one carrying the most detail first" do
      text = described_class.call.content.first[:text]

      expect(text).to include("### users → **User** (2 assoc, 1 val), **Admin::User** (0 assoc, 0 val)")
    end
  end

  # An STI table with dozens of subclasses turned one heading into a wall of
  # names, in the view that exists to be cheap.
  describe "a table many models map to" do
    before do
      models = (1..7).to_h do |i|
        [ "Kind#{i}", { table_name: "users", associations: [], validations: [] } ]
      end
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "sqlite3", tables: tables, total_tables: 3 },
        models: models
      })
    end

    it "names the first five and counts the rest" do
      text = described_class.call.content.first[:text]

      expect(text).to include("**Kind5** (0 assoc, 0 val) (+2 more)")
      expect(text).not_to include("**Kind6**")
    end
  end

  # Rails builds no model for a has_and_belongs_to_many join table, so one is
  # not a table whose model went missing, and the reader was being pointed at
  # a table the app uses on every request.
  describe "tables no model file declares" do
    let(:join_tables) do
      tables.merge(
        "posts_tags" => { columns: [ { name: "post_id", type: "integer" } ], indexes: [], foreign_keys: [] },
        "legacy_audits" => { columns: [ { name: "id", type: "integer" } ], indexes: [], foreign_keys: [] }
      )
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "sqlite3", tables: join_tables, total_tables: 5 },
        models: {
          "Post" => {
            table_name: "posts",
            associations: [ { name: "tags", type: "has_and_belongs_to_many", options: {} } ]
          }
        }
      })
    end

    def warning_line
      described_class.call.content.first[:text].lines.find { |l| l.start_with?("⚠") }.to_s
    end

    it "leaves a habtm join table out" do
      expect(warning_line).not_to include("posts_tags")
    end

    it "still names a table nothing declares" do
      expect(warning_line).to include("legacy_audits")
    end

    it "does not claim the table has no model anywhere" do
      text = described_class.call.content.first[:text]

      expect(text).not_to include("no ActiveRecord model")
      expect(text).to include("no model file in this app")
    end
  end

  describe ".call with specific table" do
    it "returns full detail for a specific table" do
      result = described_class.call(table: "users")
      text = result.content.first[:text]
      expect(text).to include("Table: users")
      expect(text).to include("| Column |")
      expect(text).to include("email")
    end

    it "shows indexes on specific table" do
      result = described_class.call(table: "users")
      text = result.content.first[:text]
      expect(text).to include("Indexes")
      expect(text).to include("index_users_on_email")
      expect(text).to include("unique")
    end

    it "shows foreign keys on specific table" do
      result = described_class.call(table: "posts")
      text = result.content.first[:text]
      expect(text).to include("Foreign keys")
      expect(text).to include("user_id")
      expect(text).to include("users")
    end

    it "shows nullable column status" do
      result = described_class.call(table: "users")
      text = result.content.first[:text]
      expect(text).to include("**NO**")
    end
  end

  describe ".call with table not found" do
    it "returns a not-found response with available tables" do
      result = described_class.call(table: "nonexistent")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("Available:")
      expect(text).to include("users")
    end

    it "provides a recovery tool hint" do
      result = described_class.call(table: "nonexistent")
      text = result.content.first[:text]
      expect(text).to include("rails_get_schema")
    end
  end

  # The ordinary state after pulling a branch and not running db:migrate:
  # db/schema.rb declares a table the connected database does not have. The
  # answer read as a misspelling, and the header paired the live table count
  # with the file's version stamp.
  describe "a table db/schema.rb declares and the database does not have" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: {
          adapter: "sqlite3",
          tables: tables,
          total_tables: 3,
          schema_version: "20260920000000",
          declared_tables: tables.keys + [ "order_comments" ],
          pending_migrations: [ { version: "20260920000000", name: "CreateOrderComments" } ]
        },
        models: {}
      })
    end

    it "says the migration has not been run rather than guessing a typo" do
      text = described_class.call(table: "order_comments").content.first[:text]

      expect(text).to include("declared in db/schema.rb")
      expect(text).to include("rails db:migrate")
      expect(text).not_to include("Did you mean")
    end

    it "answers the same way for the model name the tool advertises" do
      text = described_class.call(table: "OrderComments").content.first[:text]

      expect(text).to include("declared in db/schema.rb")
      expect(text).not_to include("Did you mean")
    end

    it "still suggests a spelling for a table nothing declares" do
      text = described_class.call(table: "userz").content.first[:text]

      expect(text).to include("Did you mean")
    end

    it "says the two table counts disagree in the listing header" do
      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).to include("db/schema.rb declares 4")
      expect(text).to include("rails db:migrate")
    end
  end

  describe ".call with model name normalization" do
    it "resolves model name to pluralized table name" do
      result = described_class.call(table: "User")
      text = result.content.first[:text]
      expect(text).to include("Table: users")
    end

    it "resolves case-insensitive table name" do
      result = described_class.call(table: "USERS")
      text = result.content.first[:text]
      expect(text).to include("Table: users")
    end

    # Underscoring a namespaced model asks for `admin/action_logs`, a table no
    # app has. The model already carries the table it reads.
    it "resolves a namespaced model through the table its model recorded" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "sqlite3", tables: tables, total_tables: 3 },
        models: { "Admin::Comment" => { table_name: "comments" } }
      })

      result = described_class.call(table: "Admin::Comment")

      expect(result.content.first[:text]).to include("Table: comments")
    end
  end

  describe ".call with JSON format" do
    it "returns JSON for single table" do
      result = described_class.call(table: "users", format: "json")
      text = result.content.first[:text]
      parsed = JSON.parse(text)
      expect(parsed).to have_key("columns")
    end

    it "returns full schema JSON for detail:full format:json" do
      result = described_class.call(detail: "full", format: "json")
      text = result.content.first[:text]
      parsed = JSON.parse(text)
      expect(parsed).to have_key("tables")
    end

    it "returns JSON for the default table listing" do
      result = described_class.call(format: "json")
      text = result.content.first[:text]

      expect { JSON.parse(text) }.not_to raise_error
      expect(JSON.parse(text)["tables"]).to include("users")
    end

    it "returns JSON for a summary listing" do
      result = described_class.call(detail: "summary", format: "json")

      expect(JSON.parse(result.content.first[:text])["tables"]).to include("users")
    end

    it "honours limit and offset in the JSON listing" do
      first = described_class.call(detail: "summary", format: "json", limit: 1)
      second = described_class.call(detail: "summary", format: "json", limit: 1, offset: 1)

      first_tables = JSON.parse(first.content.first[:text])["tables"]
      second_tables = JSON.parse(second.content.first[:text])["tables"]

      expect(first_tables.size).to eq(1)
      expect(second_tables.size).to eq(1)
      expect(second_tables.keys).not_to eq(first_tables.keys)
    end

    # A page past the end is still a JSON request. It answered prose, which
    # no caller parsing the body can read.
    %w[summary standard full].each do |level|
      it "answers an empty #{level} page as JSON" do
        result = described_class.call(detail: level, format: "json", offset: 9999)

        expect(JSON.parse(result.content.first[:text])["tables"]).to eq({})
      end
    end

    # The markdown banner rides on every static-tier response; appended to a
    # JSON body it stops the body parsing, so it moves inside the document.
    it "still parses in the static tier, with the tier note inside the document" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      allow(RailsAiContext).to receive(:static_reason).and_return("static mode requested with --no-boot")
      allow(RailsAiContext).to receive(:static_kind).and_return(:requested)

      parsed = JSON.parse(described_class.call(format: "json").content.first[:text])

      expect(parsed["_static_tier"]).to include("[STATIC]")
      expect(parsed["tables"]).to include("users")
    end
  end

  describe ".call with pagination" do
    it "returns empty-pagination message when offset exceeds total" do
      result = described_class.call(detail: "summary", offset: 100)
      text = result.content.first[:text]
      expect(text).to include("No tables at offset 100")
    end

    it "shows pagination hint when more tables exist" do
      result = described_class.call(detail: "summary", limit: 1)
      text = result.content.first[:text]
      expect(text).to include("offset:")
    end

    it "paginates full detail view" do
      result = described_class.call(detail: "full", limit: 1, offset: 0)
      text = result.content.first[:text]
      expect(text).to include("1 of 3 tables")
    end
  end

  describe ".call when introspection data is missing" do
    it "returns not-available when schema key is nil" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "returns error message when schema data has an error" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { error: "no database connection" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("no database connection")
    end
  end

  describe "standard detail shows indexed/unique column hints" do
    it "marks unique columns with [unique] in standard view" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("[unique]")
    end
  end

  describe "summary detail with many tables" do
    before do
      many_tables = 50.times.each_with_object({}) do |i, h|
        h["table_#{i.to_s.rjust(3, '0')}"] = {
          columns: 10.times.map { |j| { name: "col_#{j}", type: "string", null: true } },
          indexes: [ { name: "idx_#{i}", columns: [ "col_0" ], unique: false } ],
          foreign_keys: []
        }
      end
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", tables: many_tables, total_tables: 50 }
      })
    end

    it "returns compact summary with detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Schema Summary (50 tables)")
      expect(text).to include("10 columns")
      expect(text).not_to include("| Column |")
    end
  end

  describe "secondary databases" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: {
          adapter: "sqlite3",
          tables: tables,
          total_tables: 3,
          secondary_databases: {
            "queue" => {
              tables: { "solid_queue_jobs" => { columns: [], indexes: [], foreign_keys: [] } },
              total_tables: 1,
              note: "Parsed from db/queue_schema.rb (from committed dump, not a live connection)"
            }
          }
        },
        models: {}
      })
    end

    it "renders a secondary databases section when present" do
      response = described_class.call
      text = response.content.first[:text]
      expect(text).to include("Secondary databases")
      expect(text).to include("queue")
      expect(text).to include("solid_queue_jobs")
    end
  end

  describe "singular pluralization with exactly one table" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "sqlite3", tables: { "users" => tables["users"] }, total_tables: 1 },
        models: {}
      })
    end

    it "says '1 table' not '1 tables' in the standard header" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("# Schema (1 table, showing 1)")
      expect(text).not_to include("1 tables")
    end

    it "says '1 table' not '1 tables' in the summary header" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("# Schema Summary (1 table)")
      expect(text).not_to include("1 tables")
    end

    it "says '1 table' not '1 tables' in the full header" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("# Schema Full Detail (1 of 1 table)")
      expect(text).not_to include("1 tables")
    end
  end

  # Every read of the shared cache is a deep copy of the whole payload, so a
  # listing that reads it once per table pays for the app several times over.
  describe "shared context reads in the table listing" do
    def context_with(count)
      entries = (1..count).to_h do |i|
        [ "table#{i}", { columns: [ { name: "id", type: "integer", null: false } ], indexes: [], foreign_keys: [] } ]
      end
      models = (1..count).to_h { |i| [ "Model#{i}", { table_name: "table#{i}", associations: [], validations: [] } ] }
      { schema: { adapter: "sqlite3", tables: entries, total_tables: count }, models: models }
    end

    def reads_for(count)
      described_class.reset_cache!
      reads = 0
      ctx = context_with(count)
      allow(described_class).to receive(:cached_context) do
        reads += 1
        ctx
      end
      described_class.call(detail: "standard", limit: 200)
      reads
    end

    it "reads the shared context the same number of times for 3 tables as for 40" do
      expect(reads_for(40)).to eq(reads_for(3))
    end
  end
end
