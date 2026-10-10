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

  describe "the summary Adapter line" do
    it "names the candidates and why it cannot choose" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "static_parse", tables: tables, total_tables: 3 },
        gems: { notable_gems: [ { name: "mysql2" }, { name: "sqlite3" } ] },
        models: {}
      })

      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).to include("**Adapter:** MySQL or SQLite, the app does not say which")
    end
  end

  # A migration or validation written from the table view needs what the dump declares.
  describe "what the table view shows beyond name and type" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 2, extensions: [ "citext" ], tables: {
          "accounts" => {
            comment: "Tenant accounts",
            columns: [
              { name: "name", type: "string", null: false, limit: 120, collation: "C" },
              { name: "seats", type: "integer", unsigned: true },
              { name: "total", type: "decimal", precision: 10, scale: 2 },
              { name: "seen_at", type: "datetime", precision: 3 },
              { name: "bio", type: "text", size: "medium" }
            ],
            indexes: [], foreign_keys: [],
            unique_constraints: [ { name: "uniq_name", columns: [ "name" ], deferrable: "immediate" } ]
          },
          "users" => {
            columns: [ { name: "data", type: "jsonb" }, { name: "account_id", type: "bigint" } ],
            indexes: [
              { name: "index_users_on_data", columns: [ "data" ], unique: false, using: "gin" },
              { name: "idx_acct", columns: [ "account_id" ], unique: false, include: [ "data" ], order: { "account_id" => "desc" } }
            ],
            foreign_keys: [ { from_table: "users", to_table: "accounts", column: "account_id", primary_key: "id", on_delete: "cascade" } ]
          }
        } },
        models: {}
      })
    end

    it "shows a column's precision, scale, limit, unsigned flag and collation" do
      text = described_class.call(table: "accounts").content.first[:text]

      expect(text).to include("| name | string, limit: 120, collation: C | **NO** |")
      expect(text).to include("| seats | integer, unsigned | yes |")
      expect(text).to include("| total | decimal(10,2) | yes |")
      expect(text).to include("| seen_at | datetime(3) | yes |")
      expect(text).to include("| bio | text, size: medium | yes |")
    end

    it "shows the table comment and its unique constraints" do
      text = described_class.call(table: "accounts").content.first[:text]

      expect(text).to include("**Comment:** Tenant accounts")
      expect(text).to include("### Unique constraints\n- `uniq_name` on (name), deferrable: immediate")
    end

    it "shows an index's options and a foreign key's actions" do
      text = described_class.call(table: "users").content.first[:text]

      expect(text).to include("- `index_users_on_data` on (data) - using: gin")
      expect(text).to include("- `idx_acct` on (account_id) - include: data; order: account_id desc")
      expect(text).to include("- `account_id` → `accounts.id` (on_delete: cascade)")
    end

    # A line inside a markdown table ends it, so a comment is a cell.
    it "puts a column comment in its own cell and keeps the table whole" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1, tables: { "things" => { indexes: [], foreign_keys: [], columns: [
          { name: "data", type: "jsonb", comment: "Raw | payload" }, { name: "at", type: "timestamptz" }
        ] } } },
        models: {}
      })

      text = described_class.call(table: "things").content.first[:text]

      expect(text).to include("| Column | Type | Null | Comment |")
      expect(text).to include("| data | jsonb | yes | Raw \\| payload |")
      expect(text).to include("| at | timestamptz | yes |  |")
    end

    it "names the enabled extensions in the full listing" do
      expect(described_class.call(detail: "full").content.first[:text]).to include("**Extensions:** citext")
    end
  end

  describe "the primary key" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "sqlite3", total_tables: 2, tables: {
          "orders" => { primary_key: %w[shop_id id], indexes: [], foreign_keys: [], columns: [
            { name: "shop_id", type: "integer", null: false, primary_key: true },
            { name: "id", type: "integer", null: false, primary_key: true },
            { name: "number", type: "string" }
          ] },
          "legacy_widgets" => { primary_key: "widget_code", indexes: [], foreign_keys: [], columns: [
            { name: "widget_code", type: "string", null: false, primary_key: true }, { name: "label", type: "string" }
          ] }
        } },
        models: {}
      })
    end

    it "names a composite or custom key in the table view" do
      expect(described_class.call(table: "orders").content.first[:text]).to include("**Primary key:** shop_id, id")
      expect(described_class.call(table: "legacy_widgets").content.first[:text]).to include("**Primary key:** widget_code")
    end

    it "names a key other than id in the listing" do
      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("### orders (primary key: shop_id, id)")
      expect(text).to include("### legacy_widgets (primary key: widget_code)")
    end
  end

  describe "check constraints, enum types and generated columns in the table view" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1,
                  enum_types: [ { name: "mood", values: %w[happy sad] }, { name: "unused", values: %w[x] } ],
                  tables: { "users" => {
                    indexes: [], foreign_keys: [],
                    columns: [
                      { name: "age", type: "integer" },
                      { name: "mood", type: "enum", enum_type: "mood" },
                      { name: "age_next", type: "integer", generated: "age + 1", stored: true }
                    ],
                    check_constraints: [ { name: "age_nonneg", expression: "age >= 0" }, { expression: "age < 200" } ]
                  } } },
        models: {}
      })
    end

    it "lists each for the table" do
      text = described_class.call(table: "users").content.first[:text]

      expect(text).to include("### Check constraints\n- `age_nonneg`: age >= 0\n- age < 200")
      expect(text).to include("### Enum types\n- `mood`: happy, sad")
      expect(text).not_to include("unused")
      expect(text).to include("### Generated columns\n- `age_next`: age + 1 (stored)")
      expect(text).to include("| mood | enum, enum_type: mood | yes |")
    end
  end

  # A composite unique index constrains the pair, not each column: a blog's
  # articles read series_id and position as unique on their own, and lost the
  # plain index on series_id.
  describe "column hints for a composite unique index" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1, tables: {
          "articles" => {
            columns: [
              { name: "id", type: "integer", null: false },
              { name: "series_id", type: "integer", null: true },
              { name: "position", type: "integer", null: true },
              { name: "slug", type: "string", null: true }
            ],
            indexes: [
              { name: "index_articles_on_series_id_and_position", columns: %w[series_id position], unique: true },
              { name: "index_articles_on_series_id", columns: %w[series_id], unique: false },
              { name: "index_articles_on_slug", columns: %w[slug], unique: true }
            ],
            foreign_keys: []
          }
        } },
        models: {}
      })
    end

    let(:text) { described_class.call(detail: "standard").content.first[:text] }

    it "names the partner column rather than calling each one unique" do
      expect(text).to include("series_id:integer [indexed; unique with position]")
      expect(text).to include("position:integer [unique with series_id]")
    end

    it "still calls a column unique when a unique index covers it alone" do
      expect(text).to include("slug:string [unique]")
    end

    # Forem's articles.canonical_url is unique only among published rows.
    it "says a unique index is partial, in the hints and in the table view" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1, tables: {
          "articles" => {
            columns: [ { name: "canonical_url", type: "string" }, { name: "slug", type: "string" },
                       { name: "user_id", type: "bigint" } ],
            indexes: [
              { name: "index_articles_on_canonical_url", columns: %w[canonical_url], unique: true,
                where: "(published IS TRUE)" },
              { name: "index_articles_on_slug_and_user_id", columns: %w[slug user_id], unique: true,
                where: "(deleted_at IS NULL)" }
            ],
            foreign_keys: []
          }
        } },
        models: {}
      })

      expect(text).to include("canonical_url:string [unique where (published IS TRUE)]")
      expect(text).to include("user_id:bigint [unique with slug where (deleted_at IS NULL)]")
      table = described_class.call(table: "articles").content.first[:text]
      expect(table).to include("- `index_articles_on_canonical_url` on (canonical_url) (unique) where (published IS TRUE)")
    end

    it "keeps each condition when two partial unique indexes cover one column" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1, tables: {
          "articles" => {
            columns: [ { name: "slug", type: "string" }, { name: "code", type: "string" } ],
            indexes: [
              { name: "a", columns: %w[slug], unique: true, where: "(kind = 1)" },
              { name: "b", columns: %w[slug], unique: true, where: "(kind = 2)" },
              { name: "c", columns: %w[code], unique: true, where: "(kind = 1)" },
              { name: "d", columns: %w[code], unique: true }
            ],
            foreign_keys: []
          }
        } },
        models: {}
      })

      expect(text).to include("slug:string [unique where (kind = 1); unique where (kind = 2)]")
      expect(text).to include("code:string [unique]")
    end

    # Discourse's categories has a unique index on
    # (COALESCE(parent_category_id, '-1'::integer), name). The expression is
    # a key of its own, not the column inside it, and it is name's partner.
    it "names an expression partner as the expression" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1, tables: {
          "categories" => {
            columns: [ { name: "parent_category_id", type: "integer" }, { name: "name", type: "string" } ],
            indexes: [ { name: "u", columns: [ "COALESCE(parent_category_id, '-1'::integer)", "name" ], unique: true } ],
            foreign_keys: []
          }
        } },
        models: {}
      })

      expect(text).to include("parent_category_id:integer, name:string [unique with `COALESCE(parent_category_id, '-1'::integer)`]")
    end

    it "gives no column a hint from an index over one expression" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1, tables: {
          "users" => {
            columns: [ { name: "email", type: "string" } ],
            indexes: [ { name: "u", columns: [ "lower((email)::text)" ], unique: true } ],
            foreign_keys: []
          }
        } },
        models: {}
      })

      expect(text).to include("email:string\n")
    end

    # Unique alone already makes every combination containing it unique.
    it "adds no partner to a column that is unique by itself" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1, tables: {
          "members" => {
            columns: [ { name: "project_id", type: "bigint" }, { name: "user_id", type: "bigint" } ],
            indexes: [
              { name: "a", columns: %w[project_id user_id], unique: true },
              { name: "b", columns: %w[user_id], unique: true }
            ],
            foreign_keys: []
          }
        } },
        models: {}
      })

      expect(text).to include("user_id:bigint [unique]")
      # project_id leads the composite, so a lookup on it alone is indexed.
      expect(text).to include("project_id:bigint [indexed; unique with user_id]")
    end
  end

  # Only an index's leading column can be looked up through it. [indexed] on
  # every member of (project_id, user_id) told a reader that a query on
  # user_id alone was covered.
  describe "column hints for a plain composite index" do
    let(:hints_context) do
      { schema: { adapter: "postgresql", total_tables: 1, tables: {
        "memberships" => {
          columns: [
            { name: "project_id", type: "bigint" }, { name: "user_id", type: "bigint" },
            { name: "role", type: "string" }, { name: "status", type: "string" }
          ],
          indexes: [
            { name: "a", columns: %w[project_id user_id role], unique: false },
            { name: "b", columns: %w[status], unique: false }
          ],
          foreign_keys: []
        }
      } }, models: {} }
    end

    before { allow(described_class).to receive(:cached_context).and_return(hints_context) }

    let(:text) { described_class.call(detail: "standard").content.first[:text] }

    it "gives [indexed] to the leading column" do
      expect(text).to include("project_id:bigint [indexed]")
    end

    it "names what a non-leading column sits behind" do
      expect(text).to include("user_id:bigint [in index after project_id]")
      expect(text).to include("role:string [in index after project_id, user_id]")
    end

    # One clause per distinct index position, and a separator that no clause
    # uses inside itself.
    it "prints each trailing clause once and tells two apart" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1, tables: {
          "items" => {
            columns: [ { name: "a_id", type: "bigint" }, { name: "sku", type: "string" }, { name: "code", type: "string" } ],
            indexes: [
              { name: "p", columns: %w[a_id code], unique: false },
              { name: "q", columns: %w[a_id code sku], unique: false },
              { name: "r", columns: %w[a_id sku code], unique: false }
            ],
            foreign_keys: []
          }
        } },
        models: {}
      })

      expect(text).to include("code:string [in index after a_id; in index after a_id, sku]")
    end

    it "keeps [indexed] for a column that leads an index of its own" do
      expect(text).to include("status:string [indexed]")
    end

    # Discourse's allowed_pm_users has the same unique pair in both orders,
    # and assignments a column both in a unique set and behind another key.
    it "names a partner set once and adds no trailing hint beside a unique one" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1, tables: {
          "pairs" => {
            columns: [ { name: "a_id", type: "bigint" }, { name: "b_id", type: "bigint" }, { name: "kind", type: "string" } ],
            indexes: [
              { name: "x", columns: %w[a_id b_id], unique: true },
              { name: "y", columns: %w[b_id a_id], unique: true },
              { name: "z", columns: %w[a_id b_id kind], unique: true },
              { name: "w", columns: %w[b_id kind], unique: false }
            ],
            foreign_keys: []
          }
        } },
        models: {}
      })

      expect(text).to include("a_id:bigint [indexed; unique with b_id; unique with b_id, kind]")
      expect(text).to include("kind:string [unique with a_id, b_id]")
    end
  end

  # The replay note said how many table names were read off the file, and it
  # reached only .ai-context.json.
  describe "the section note" do
    let(:note) { "Reconstructed from 240 migration files (no DB connection, no schema.rb), 91 table names read from the file rather than the create_table call" }

    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "static_parse", tables: tables, total_tables: 3, note: note },
        models: {}
      })
    end

    %w[summary standard full].each do |detail|
      it "is printed at detail #{detail}" do
        expect(described_class.call(detail: detail).content.first[:text]).to include("_#{note}_")
      end
    end

    it "prints nothing when the section carries none" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "sqlite3", tables: tables, total_tables: 3 }, models: {}
      })

      expect(described_class.call(detail: "summary").content.first[:text]).not_to include("Reconstructed")
    end
  end

  describe ".call with no params" do
    it "reads a junk detail as standard" do
      text = described_class.call(detail: "verbose").content.first[:text]

      expect(text).to include("Schema (3 tables")
      expect(text).not_to include("# Database Schema")
    end

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

    it "leaves out the table of a model file that could not be read" do
      context = described_class.cached_context
      context[:models]["LegacyAudit"] = { error: "file is unreadable", file: "app/models/legacy_audit.rb" }
      allow(described_class).to receive(:cached_context).and_return(context)

      expect(warning_line).not_to include("legacy_audits")
      json = JSON.parse(described_class.call(format: "json").content.first[:text])
      expect(json["tables_without_model_file"]).not_to include("legacy_audits")
    end

    it "keeps a static table's unread calls out of the json, which the booted tier never has" do
      context = described_class.cached_context
      table = context[:schema][:tables].keys.first
      tables = context[:schema][:tables].merge(table => context[:schema][:tables][table].merge(unread_calls: %w[replica_identity_index]))
      allow(described_class).to receive(:cached_context).and_return(context.merge(schema: context[:schema].merge(tables: tables)))

      expect(described_class.call(format: "json").content.first[:text]).not_to include("unread_calls")
      expect(described_class.call(table: table, format: "json").content.first[:text]).not_to include("unread_calls")
    end

    it "takes an unreadable model file's table from what it declares over its file name" do
      context = described_class.cached_context
      context[:models]["LegacyAudit"] = { error: "file is unreadable", file: "app/models/legacy_audit.rb", table_name: "audit_log" }
      allow(described_class).to receive(:cached_context).and_return(context)

      expect(warning_line).to include("legacy_audits")
    end

    # The lists answer for the whole schema, whichever page and level is shown.
    %w[summary standard full].each do |level|
      it "names every unclaimed table at detail #{level}, past the page" do
        text = described_class.call(detail: level, limit: 1).content.first[:text]
        warning = text.lines.find { |l| l.start_with?("⚠") }.to_s

        expect(warning).to include("legacy_audits", "users", "comments")
      end
    end

    it "prints the gem lines at every level" do
      join_tables["good_jobs"] = { columns: [], indexes: [], foreign_keys: [] }
      allow(RailsAiContext::GemLock).to receive(:for)
        .and_return(RailsAiContext::GemLock::Spec.new({ "good_job" => "4.19.2" }))

      %w[summary standard full].each do |level|
        expect(described_class.call(detail: level, limit: 1).content.first[:text]).to include("Tables the good_job gem owns: good_jobs")
      end
    end

    it "caps a long list and says where the rest is" do
      30.times { |i| join_tables[format("orphan_%02d", i)] = { columns: [], indexes: [], foreign_keys: [] } }

      expect(warning_line).to include("orphan_00", "and 18 more")
      expect(warning_line).not_to include("orphan_29")
      expect(described_class.call.content.first[:text]).to include("`format:\"json\"` lists all 33")
      json = JSON.parse(described_class.call(format: "json").content.first[:text])
      expect(json["tables_without_model_file"].size).to eq(33)
    end

    it "still names a table nothing declares" do
      expect(warning_line).to include("legacy_audits")
    end

    it "names the gem that owns a table the lockfile has, instead of listing it" do
      join_tables.merge!(
        "good_jobs" => { columns: [], indexes: [], foreign_keys: [] },
        "oauth_applications" => { columns: [], indexes: [], foreign_keys: [] },
        "work_package_hierarchies" => { columns: [], indexes: [], foreign_keys: [] },
        "versions" => { columns: [], indexes: [], foreign_keys: [] }
      )
      allow(RailsAiContext::GemLock).to receive(:for)
        .and_return(RailsAiContext::GemLock::Spec.new({ "good_job" => "4.19.2", "closure_tree" => "9.7.0", "paper_trail" => "17.0.0" }))
      text = described_class.call.content.first[:text]

      expect(warning_line).not_to include("good_jobs")
      expect(warning_line).to include("oauth_applications")
      expect(text).to include("Tables the good_job gem owns: good_jobs")
      expect(text).to include("Tables the closure_tree gem owns: work_package_hierarchies")
      expect(text).to include("Tables the paper_trail gem owns: versions")
    end

    # The other side's table is the one its model records, not the name
    # tableized: Tag keeps legacy_tags, so the join table is legacy_tags_posts.
    it "names a join table from the other model's own table" do
      join_tables["legacy_tags_posts"] = { columns: [], indexes: [], foreign_keys: [] }
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "sqlite3", tables: join_tables, total_tables: 6 },
        models: {
          "Post" => { table_name: "posts",
                      associations: [ { name: "tags", type: "has_and_belongs_to_many", options: {} } ] },
          "Tag" => { table_name: "legacy_tags", associations: [] }
        }
      })

      expect(warning_line).not_to include("legacy_tags_posts")
    end

    it "finds the other side in the owner's namespace first" do
      join_tables["spree_products_taxons"] = { columns: [], indexes: [], foreign_keys: [] }
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "sqlite3", tables: join_tables, total_tables: 6 },
        models: {
          "Spree::Product" => { table_name: "spree_products",
                                associations: [ { name: "taxons", type: "has_and_belongs_to_many", options: {} } ] },
          "Spree::Taxon" => { table_name: "spree_taxons", associations: [] },
          "Taxon" => { table_name: "legacy_taxons", associations: [] }
        }
      })

      expect(warning_line).not_to include("spree_products_taxons")
    end

    it "leaves out a custom join table the booted record carries" do
      join_tables["post_labels"] = { columns: [], indexes: [], foreign_keys: [] }
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "sqlite3", tables: join_tables, total_tables: 6 },
        models: {
          "Post" => { table_name: "posts",
                      associations: [ { name: "labels", type: "has_and_belongs_to_many", class_name: "Tag",
                                        join_table: "post_labels" } ] }
        }
      })

      expect(warning_line).not_to include("post_labels")
    end

    it "leaves out a join table a lib patch's habtm names" do
      join_tables["done_statuses_for_project"] = { columns: [], indexes: [], foreign_keys: [] }
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib/patches"))
        File.write(File.join(dir, "lib/patches/project_patch.rb"),
                   "module ProjectPatch\n  included do\n    has_and_belongs_to_many :done_statuses, join_table: \"done_statuses_for_project\"\n  end\nend\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))

        expect(warning_line).to include("legacy_audits")
        expect(warning_line).not_to include("done_statuses_for_project")
      end
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
      expect(text).to include("- `user_id` → `users.id`")
    end

    # Every key to a partitioned table spans the partition column too.
    it "shows a foreign key over two columns as the column lists" do
      tables["posts"][:foreign_keys] = [ { column: %w[user_id user_day], to_table: "users", primary_key: %w[id day] } ]

      text = described_class.call(table: "posts").content.first[:text]
      expect(text).to include("- `(user_id, user_day)` → `users.(id, day)`")
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

    it "names the pending migration that adds the table" do
      text = described_class.call(table: "order_comments").content.first[:text]

      expect(text).to include("20260920000000 CreateOrderComments")
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

  # Both counts, and the header above them, take a virtual table as a table and
  # a view as a view, or "declares 3; has 3; 1 missing" cannot add up.
  describe "a missing table beside a view and a virtual table" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: {
          adapter: "sqlite3",
          tables: tables.merge(
            "active_users" => { kind: "view", columns: [], indexes: [], foreign_keys: [], sql: "SELECT 1" },
            "docs_fts" => { kind: "virtual_table", module: "fts5", columns: [ { name: "body" } ], indexes: [], foreign_keys: [] }
          ),
          declared_tables: tables.keys + [ "docs_fts", "order_comments" ]
        },
        models: {}
      })
    end

    it "counts the same kind of table on both sides and in the header" do
      text = described_class.call(detail: "summary").content.first[:text]
      connected = tables.size + 1

      expect(text).to include("# Schema Summary (#{connected} tables and 1 view)")
      expect(text).to include("declares #{connected + 1} tables; the connected database has #{connected}. Missing: order_comments")
    end
  end

  describe "a table a renamed dump declares and the database does not have" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "sqlite3", tables: tables, total_tables: 3,
                  declared_tables: tables.keys + [ "order_comments" ], declared_in: "db/schema_sqlite.rb" },
        models: {}
      })
    end

    it "names the file database.yml's schema_dump gives" do
      expect(described_class.call(table: "order_comments").content.first[:text]).to include("declared in db/schema_sqlite.rb")
      expect(described_class.call(detail: "summary").content.first[:text]).to include("db/schema_sqlite.rb declares 4")
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
              note: "Parsed from db/queue_schema.rb (from committed dump, not a live connection)",
              pending_migrations: [ { version: "20250101000001", name: "AddX" } ]
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
      expect(text).to include("pending migrations: 1 - 20250101000001")
    end
  end

  describe "a new app whose primary database has no tables yet" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: {
          tables: {}, total_tables: 0, note: "The primary database has no tables yet.",
          secondary_databases: {
            "queue" => { tables: { "solid_queue_jobs" => { columns: [] } }, total_tables: 1, note: "Parsed from db/queue_schema.rb" }
          }
        },
        models: {}
      })
    end

    it "lists the secondary databases at every detail" do
      %w[summary standard full].each do |detail|
        text = described_class.call(detail: detail).content.first[:text]
        expect(text).to include("The primary database has no tables yet.", "**queue**: 1 table (solid_queue_jobs)")
      end
    end
  end

  describe "a table in a secondary database" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: {
          tables: { "users" => { columns: [] } }, total_tables: 1,
          secondary_databases: {
            "analytics" => { tables: { "page_views" => { columns: [ { name: "path", type: "string", null: false } ] } },
                             total_tables: 1, note: "Parsed from db/analytics_schema.rb" }
          }
        },
        models: { "PageView" => { table_name: "page_views" } }
      })
    end

    it "answers its columns and names the database" do
      text = described_class.call(table: "page_views").content.first[:text]
      expect(text).to include("## Table: page_views", "**Database:** analytics", "path")
    end

    it "finds it by model name too" do
      expect(described_class.call(table: "PageView").content.first[:text]).to include("## Table: page_views")
    end

    it "names every database that holds the table" do
      orders = { tables: { "orders" => { columns: [ { name: "total_cents", type: "integer" } ] } } }
      allow(described_class).to receive(:cached_context).and_return({
        schema: { tables: { "users" => { columns: [] } }, secondary_databases: { "shard_one" => orders, "shard_two" => orders } }, models: {}
      })
      expect(described_class.call(table: "orders").content.first[:text]).to include("**Database:** shard_one, shard_two")
      expect(JSON.parse(described_class.call(table: "orders", format: "json").content.first[:text])["database"]).to eq("shard_one, shard_two")
    end

    it "shows each database's own columns and models when one name holds different tables" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { tables: { "users" => { columns: [ { name: "email", type: "string" } ] } },
                  secondary_databases: { "analytics" => { tables: { "users" => { columns: [ { name: "visitor_token", type: "string" } ] } } } } },
        models: { "User" => { table_name: "users" }, "Visitor" => { table_name: "users", database: { writing: "analytics" } } }
      })
      text = described_class.call(table: "users").content.first[:text]
      primary, analytics = text.split("## Table: users").drop(1)

      expect(primary).to include("**Database:** primary", "**Models:** User\n", "email")
      expect(primary).not_to include("visitor_token")
      expect(analytics).to include("**Database:** analytics", "**Models:** Visitor\n", "visitor_token")
      json = JSON.parse(described_class.call(table: "users", format: "json").content.first[:text])
      expect(json["databases"].transform_values { |t| t["columns"].map { |c| c["name"] } }).to eq("primary" => %w[email], "analytics" => %w[visitor_token])
    end

    it "lists a sharded model under every shard whose table differs" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { tables: {},
                  secondary_databases: { "shard_one" => { tables: { "orders" => { columns: [ { name: "total", type: "integer" } ] } } },
                                         "shard_two" => { tables: { "orders" => { columns: [ { name: "region", type: "string" } ] } } } } },
        models: { "Order" => { table_name: "orders", database: { connects_to: "connects_to shards: { ... }" } } }
      })
      one, two = described_class.call(table: "orders").content.first[:text].split("## Table: orders").drop(1)

      expect(one).to include("**Database:** shard_one", "**Models:** Order\n")
      expect(two).to include("**Database:** shard_two", "**Models:** Order\n")
    end

    it "lists it among the tables a miss names" do
      expect(described_class.call(table: "nope").content.first[:text]).to include("page_views")
    end
  end

  describe "pending migrations a database could not answer for" do
    let(:declared) { { "posts" => { columns: [ { name: "title", type: "string" } ] } } }

    it "says they are not known when the database does not answer" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "static_parse", tables: declared, schema_version: "20260101000000", note: "Parsed from db/schema.rb (no DB connection)",
                  pending_unknown: "the database does not exist yet (`bin/rails db:create`, then `bin/rails db:migrate`)" },
        models: {}
      })

      text = described_class.call.content.first[:text]
      expect(text).to include("**Pending migrations:** not known: the database does not exist yet")
      expect(text).not_to include("**Pending migrations:** none")
    end

    # Created but not migrated: the listing is the dump's, and the connection's pending list stands.
    it "says the connected database holds none of the dump's tables" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "static_parse", tables: declared, schema_version: "20260101000000", connected_tables: 0,
                  note: "Parsed from db/schema.rb (connected, no tables yet)", pending_migrations: [ { version: "20260101000000", name: "CreatePosts" } ] },
        models: {}
      })

      text = described_class.call.content.first[:text]
      expect(text).to include("_db/schema.rb declares 1 table; the connected database has none of them. Run `rails db:migrate`._")
      expect(text).to include("**Pending migrations:** 1 - 20260101000000")
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

  describe "a schema with views" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1, tables: {
          "users" => tables["users"], "instances" => { kind: "materialized_view", columns: [], indexes: [], foreign_keys: [], sql: "SELECT 1" }
        } },
        models: {}
      })
    end

    it "counts the views apart from the tables in every header" do
      expect(described_class.call(detail: "summary").content.first[:text]).to include("# Schema Summary (1 table and 1 view)")
      expect(described_class.call(detail: "standard").content.first[:text]).to include("# Schema (1 table and 1 view, showing 2)")
      expect(described_class.call(detail: "full").content.first[:text]).to include("# Schema Full Detail (2 of 1 table and 1 view)")
    end

    it "counts a secondary database's views apart from its tables" do
      view = { kind: "view", columns: [], indexes: [], foreign_keys: [], sql: "SELECT 1" }
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "postgresql", total_tables: 1, tables: { "users" => tables["users"] },
                  secondary_databases: { "reporting" => { total_tables: 1, tables: { "users" => tables["users"], "my_view" => view }, note: "Parsed" } } },
        models: {}
      })

      expect(described_class.call(detail: "summary").content.first[:text]).to include("- **reporting**: 1 table and 1 view (users, my_view)")
    end

    it "lists the indexes on a view whose columns the dump does not hold" do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "static_parse", total_tables: 0, tables: {
          "instances" => { kind: "materialized_view", columns: [], foreign_keys: [], sql: "SELECT 1",
                           indexes: [ { name: "index_instances_on_domain", columns: [ "domain" ], unique: true } ] }
        } },
        models: {}
      })

      text = described_class.call(table: "instances").content.first[:text]
      expect(text).to include("### Indexes\n- `index_instances_on_domain` on (domain) (unique)\n\n### Definition")
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

  it "says when a table's inherited columns come from a parent the dump does not hold" do
    allow(described_class).to receive(:cached_context).and_return({
      schema: { adapter: "static_parse", total_tables: 1, tables: {
        "orphan" => { columns: [ { name: "x", type: "integer", null: true } ], indexes: [], foreign_keys: [],
                      inherits_unresolved: %w[elsewhere.gone] }
      } },
      models: {}
    })

    text = described_class.call(table: "orphan").content.first[:text]

    expect(text).to include("Inherits from `elsewhere.gone`, which the structure.sql dump does not define: its columns are not shown.")
  end

  describe "views, virtual tables and a table the dumper could not write" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { adapter: "SQLite", adapter_source: "static_parse", total_tables: 4, tables: {
          "users" => { columns: [ { name: "email", type: "string" } ], indexes: [], foreign_keys: [] },
          "active_users" => { kind: "view", sql: "SELECT id FROM users", columns: [], indexes: [], foreign_keys: [] },
          "docs_fts" => { kind: "virtual_table", module: "fts5", columns: [ { name: "title" } ], indexes: [], foreign_keys: [] },
          "boxes" => { columns: [], indexes: [], foreign_keys: [], not_dumped: "StandardError: Unknown type 'virtual'" }
        } },
        models: {}
      })
    end

    it "labels each in the listing" do
      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("### active_users (view)", "### docs_fts (fts5 virtual table)", "### boxes (not dumped)")
    end

    it "shows a view's SQL and says its columns need a connection" do
      text = described_class.call(table: "active_users").content.first[:text]

      expect(text).to include("## View: active_users", "```sql\nSELECT id FROM users\n```")
      expect(text).to include("A view's columns are read from the database")
      expect(text).not_to include("| Column |")
    end

    it "says why a table has no columns when the dumper could not write it" do
      text = described_class.call(table: "boxes").content.first[:text]

      expect(text).to include("The schema dumper could not describe this table (StandardError: Unknown type 'virtual')")
    end

    it "says, without a connection, that a view the dump does not record cannot be listed" do
      text = described_class.call(table: "missing_view").content.first[:text]

      expect(text).to include("a view is listed only when the dump records it")
    end

    it "names a virtual table's module" do
      text = described_class.call(table: "docs_fts").content.first[:text]

      expect(text).to include("## Virtual table: docs_fts", "**Module:** fts5", "| Column |\n|--------|\n| title |")
      expect(text).not_to include("| Null")
    end

    it "lists a virtual table's columns without a type label" do
      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("### docs_fts (fts5 virtual table)\ntitle\n")
    end

    it "leaves views and virtual tables out of the tables with no model file" do
      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).to match(/Tables with no model file in this app\*\*: boxes, users$/)
    end
  end
end
