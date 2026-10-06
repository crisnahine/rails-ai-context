# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SchemaConventions do
  describe ".implicit_primary_key" do
    it "adds an id of the adapter's type" do
      expect(described_class.implicit_primary_key({}, "bigint"))
        .to eq([ { name: "id", type: "bigint", default: nil, options: { null: false }, primary_key: true } ])
    end

    it "honours a named key and an explicit id type" do
      key = described_class.implicit_primary_key({ primary_key: "uuid", id: :uuid }, "bigint").first
      expect(key).to include(name: "uuid", type: "uuid")
    end

    it "takes the type and options from an id: hash, as set_primary_key does" do
      key = described_class.implicit_primary_key({ id: { type: :string, limit: 36 } }, "bigint").first
      expect(key).to include(name: "id", type: "string", options: { null: false, limit: 36 })
      expect(described_class.implicit_primary_key({ id: { limit: 4 } }, "integer").first).to include(type: "integer")
    end

    it "adds nothing for id: false or a composite key" do
      expect(described_class.implicit_primary_key({ id: false }, "bigint")).to eq([])
      expect(described_class.implicit_primary_key({ primary_key: %w[a b] }, "bigint")).to eq([])
    end
  end

  describe ".foreign_key_entry" do
    it "falls back to the conventional column and id" do
      expect(described_class.foreign_key_entry("posts", "users", nil, nil))
        .to eq(from_table: "posts", to_table: "users", column: "user_id", primary_key: "id")
    end

    it "infers the column from the bare table name of a schema-qualified target" do
      expect(described_class.foreign_key_entry("public.users", "other.widgets", nil, nil))
        .to include(to_table: "other.widgets", column: "widget_id")
    end

    it "keeps a composite column list" do
      entry = described_class.foreign_key_entry("a", "b", %w[x y], %w[p q])
      expect(entry).to include(column: %w[x y], primary_key: %w[p q])
    end

    it "names Rails 7.0's deferrable: true as immediate, the way structure.sql and Rails 7.1 do" do
      expect(described_class.foreign_key_entry("posts", "users", nil, nil, deferrable: true)).to include(deferrable: "immediate")
    end
  end

  describe ".default_index_name" do
    it "names a short index the Rails way" do
      expect(described_class.default_index_name("posts", %w[user_id created_at])).to eq("index_posts_on_user_id_and_created_at")
    end

    it "names an expression by its words" do
      expect(described_class.default_index_name("users", "lower(email)")).to eq("index_users_on_lower_email")
    end

    it "shortens a name past the limit with a hash" do
      name = described_class.default_index_name("a_really_long_table_name", %w[first_long_column second_long_column])
      expect(name).to start_with("idx_on_first_long_column")
      expect(name.bytesize).to be <= described_class::MAX_INDEX_NAME_SIZE
    end
  end

  describe ".lookup_indexed_columns" do
    it "takes each index's leading column and the primary key" do
      table = { indexes: [ { columns: %w[user_id created_at] }, { columns: [ "slug" ] } ], primary_key: "id" }
      expect(described_class.lookup_indexed_columns(table)).to eq(Set["user_id", "slug", "id"])
    end

    it "reads the primary key out of the options too" do
      expect(described_class.lookup_indexed_columns({ options: { primary_key: "uuid" } })).to eq(Set["uuid"])
    end
  end

  describe ".key_text" do
    it "writes one column bare and several in parentheses" do
      expect(described_class.key_text("id")).to eq("id")
      expect(described_class.key_text(%w[id day])).to eq("(id, day)")
    end
  end

  describe ".where_clause" do
    it "is empty without a condition" do
      expect(described_class.where_clause(nil)).to eq("")
      expect(described_class.where_clause("deleted_at IS NULL")).to eq(" where deleted_at IS NULL")
    end
  end

  describe ".leading_index?" do
    let(:indexes) { [ { columns: %w[account_id user_id created_at] } ] }

    it "matches the leading columns in any order" do
      expect(described_class.leading_index?(indexes, %w[user_id account_id])).to be true
    end

    it "does not match a column behind another key" do
      expect(described_class.leading_index?(indexes, [ "user_id" ])).to be false
    end
  end

  describe ".reference_definition" do
    it "declares the id column and its default index" do
      ref = described_class.reference_definition("posts", "user", {}, "bigint")
      expect(ref[:columns]).to eq([ { name: "user_id", type: "bigint" } ])
      expect(ref[:index]).to eq(name: "index_posts_on_user_id", columns: [ "user_id" ], unique: false)
    end

    it "adds the type column for a polymorphic reference and names its index by the reference" do
      ref = described_class.reference_definition("comments", "commentable", { polymorphic: true, null: false }, "bigint")
      expect(ref[:columns].map { |c| c[:name] }).to eq(%w[commentable_type commentable_id])
      expect(ref[:columns]).to all(include(null: false))
      expect(ref[:index][:name]).to eq("index_comments_on_commentable")
    end

    it "uses the pair name for a polymorphic index up to 6.0" do
      ref = described_class.reference_definition("comments", "commentable", { polymorphic: true }, "bigint", version: [ 6, 0 ])
      expect(ref[:index][:name]).to eq("index_comments_on_commentable_type_and_commentable_id")
    end

    it "adds no index by default up to 4.2, or when index: false" do
      expect(described_class.reference_definition("posts", "user", {}, "integer", version: [ 4, 2 ])[:index]).to be_nil
      expect(described_class.reference_definition("posts", "user", { index: false }, "bigint")[:index]).to be_nil
    end

    it "keeps a named unique index and an explicit type" do
      ref = described_class.reference_definition("posts", "user", { type: :uuid, index: { name: "by_user", unique: true } }, "bigint")
      expect(ref[:columns].first[:type]).to eq("uuid")
      expect(ref[:index]).to include(name: "by_user", unique: true)
    end
  end

  describe ".reference_column_name" do
    it "is the name plus _id" do
      expect(described_class.reference_column_name("author")).to eq("author_id")
    end
  end

  describe ".timestamps_columns" do
    it "is NOT NULL by default" do
      expect(described_class.timestamps_columns).to eq([
        { name: "created_at", type: "datetime", null: false },
        { name: "updated_at", type: "datetime", null: false }
      ])
    end

    it "allows NULL in a 4.2 migration and when asked" do
      expect(described_class.timestamps_columns({}, version: [ 4, 2 ]).map { |c| c.key?(:null) }).to eq([ false, false ])
      expect(described_class.timestamps_columns({ null: true }).map { |c| c.key?(:null) }).to eq([ false, false ])
    end

    it "carries a default as text" do
      expect(described_class.timestamps_columns({ default: :now }).first[:default]).to eq("now")
    end
  end

  describe "adapter lookup" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "config"))
        example.run
      end
    end

    def database_yml(text)
      File.write(File.join(@root, "config", "database.yml"), text)
    end

    it "types the implicit key integer on SQLite and bigint elsewhere" do
      database_yml("#{Rails.env}:\n  adapter: sqlite3\n")
      expect(described_class.implicit_pk_type(@root, "db/schema.rb")).to eq("integer")
      database_yml("#{Rails.env}:\n  adapter: postgresql\n")
      expect(described_class.implicit_pk_type(@root, "db/schema.rb")).to eq("bigint")
    end

    it "reads the running environment's adapter, not another environment's" do
      database_yml("other:\n  adapter: sqlite3\n#{Rails.env}:\n  adapter: postgresql\n")
      expect(described_class.database_adapter_for(@root, "primary")).to eq("postgresql")
    end

    it "reads the literal default of an ERB-computed adapter" do
      database_yml("#{Rails.env}:\n  adapter: <%= ENV[\"DB\"].presence || \"sqlite3\" %>\n")
      expect(described_class.database_adapter_for(@root, "primary")).to eq("sqlite3")
    end

    it "types each dump of a multi-db app by its own database" do
      database_yml("#{Rails.env}:\n  primary:\n    adapter: postgresql\n\n  queue:\n    adapter: sqlite3\n")
      expect(described_class.database_adapter_for(@root, "queue")).to eq("sqlite3")
      expect(described_class.implicit_pk_type(@root, "db/queue_schema.rb")).to eq("integer")
      expect(described_class.implicit_pk_type(@root, "db/structure.sql")).to eq("bigint")
      expect(described_class.implicit_pk_type(@root, database: "queue")).to eq("integer")
    end

    it "takes the adapter a DATABASE_URL names over database.yml, as Rails merges it" do
      database_yml("#{Rails.env}:\n  adapter: sqlite3\n")
      stub_const("ENV", ENV.to_h.merge("DATABASE_URL" => "postgresql://u@localhost:5432/fx"))
      expect(described_class.implicit_pk_type(@root, "db/schema.rb")).to eq("bigint")
    end

    it "types a dump whose database only another environment configures by that environment's adapter" do
      database_yml(<<~YAML)
        default: &default
          adapter: sqlite3
        #{Rails.env}:
          <<: *default
        production:
          primary:
            <<: *default
          queue:
            <<: *default
            migrations_paths: db/queue_migrate
      YAML
      expect(described_class.implicit_pk_type(@root, "db/queue_schema.rb")).to eq("integer")
    end

    it "falls back to the running primary's adapter for a dump no environment configures" do
      database_yml("#{Rails.env}:\n  adapter: sqlite3\n")
      expect(described_class.implicit_pk_type(@root, "db/orphan_schema.rb")).to eq("integer")
    end

    it "types the primary by another environment when the running one has no entry" do
      database_yml("production:\n  adapter: sqlite3\n")
      expect(described_class.implicit_pk_type(@root, "db/schema.rb")).to eq("integer")
    end

    it "is nil with no database.yml" do
      expect(described_class.database_adapter_for(@root, "primary")).to be_nil
    end
  end

  describe ".primary_key_value" do
    it "gives a name, a list, or nil" do
      expect(described_class.primary_key_value(:id)).to eq("id")
      expect(described_class.primary_key_value(%w[a b])).to eq(%w[a b])
      expect(described_class.primary_key_value([ "" ])).to be_nil
    end
  end

  describe ".primary_key_label" do
    it "defaults to id and joins a composite key" do
      expect(described_class.primary_key_label(nil)).to eq("id")
      expect(described_class.primary_key_label(%w[tag_id account_id])).to eq("tag_id, account_id")
    end
  end

  describe ".format_default" do
    it "stringifies and keeps nil" do
      expect(described_class.format_default(0)).to eq("0")
      expect(described_class.format_default(nil)).to be_nil
    end
  end
end
