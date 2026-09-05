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
      result = described_class.call(detail: "summary", format: "json", limit: 1)

      expect(JSON.parse(result.content.first[:text])["tables"].size).to eq(1)
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
end
