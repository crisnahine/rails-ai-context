# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::MigrationAdvisor do
  describe ".call" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: {
          tables: {
            "users" => {
              columns: [
                { name: "email", type: "string" },
                { name: "name", type: "string" }
              ]
            },
            "posts" => {
              columns: [
                { name: "title", type: "string" },
                { name: "user_id", type: "integer" }
              ]
            }
          }
        },
        models: {
          User: { associations: [ { macro: :has_many, name: :posts, class_name: "Post" } ] },
          Post: { associations: [ { macro: :belongs_to, name: :user, class_name: "User" } ] }
        }
      })
    end

    it "generates add_column migration" do
      response = described_class.call(action: "add_column", table: "users", column: "phone", type: "string")
      text = response.content.first[:text]
      expect(text).to include("add_column :users, :phone, :string")
      expect(text).to include("Reversible:** Yes")
    end

    it "warns when adding a column that already exists" do
      response = described_class.call(action: "add_column", table: "users", column: "email", type: "string")
      text = response.content.first[:text]
      expect(text).to include("already exists")
      expect(text).to include("DuplicateColumn")
    end

    it "warns when adding an association FK that already exists" do
      response = described_class.call(action: "add_association", table: "posts", column: "user")
      text = response.content.first[:text]
      expect(text).to include("already exists")
    end

    it "warns when removing a nonexistent column" do
      response = described_class.call(action: "remove_column", table: "users", column: "totally_fake")
      text = response.content.first[:text]
      expect(text).to include("does not exist")
    end

    it "warns when renaming a nonexistent column" do
      response = described_class.call(action: "rename_column", table: "users", column: "totally_fake", new_name: "still_fake")
      text = response.content.first[:text]
      expect(text).to include("does not exist")
    end

    it "warns when adding index on nonexistent column" do
      response = described_class.call(action: "add_index", table: "users", column: "totally_fake")
      text = response.content.first[:text]
      expect(text).to include("does not exist")
    end

    it "warns when changing type of nonexistent column" do
      response = described_class.call(action: "change_type", table: "users", column: "totally_fake", type: "text")
      text = response.content.first[:text]
      expect(text).to include("does not exist")
    end

    it "warns when removing column from nonexistent table" do
      response = described_class.call(action: "remove_column", table: "nonexistent_table", column: "name")
      text = response.content.first[:text]
      expect(text).to include("not found")
    end

    it "generates remove_column migration with warning" do
      response = described_class.call(action: "remove_column", table: "users", column: "name")
      text = response.content.first[:text]
      expect(text).to include("remove_column :users, :name")
      expect(text).to include("Data loss")
    end

    it "generates add_index migration" do
      response = described_class.call(action: "add_index", table: "posts", column: "title")
      text = response.content.first[:text]
      expect(text).to include("add_index :posts, :title")
    end

    it "generates add_association migration" do
      response = described_class.call(action: "add_association", table: "posts", column: "categories")
      text = response.content.first[:text]
      expect(text).to include("add_reference")
      expect(text).to include("belongs_to")
      expect(text).to include("has_many")
    end

    it "generates create_table migration" do
      response = described_class.call(action: "create_table", table: "tags", column: "name:string,color:string")
      text = response.content.first[:text]
      expect(text).to include("create_table :tags")
      expect(text).to include("t.string :name")
    end

    it "warns about irreversible change_type" do
      response = described_class.call(action: "change_type", table: "posts", column: "title", type: "text")
      text = response.content.first[:text]
      expect(text).to include("Reversible:** No")
      expect(text).to include("data loss")
    end

    it "shows affected models" do
      response = described_class.call(action: "add_column", table: "users", column: "age", type: "integer")
      text = response.content.first[:text]
      expect(text).to include("Affected Models")
    end

    it "generates rename_column with new_name parameter" do
      response = described_class.call(action: "rename_column", table: "users", column: "name", new_name: "full_name")
      text = response.content.first[:text]
      expect(text).to include("rename_column :users, :name, :full_name")
      expect(text).to include("Reversible:** Yes")
      expect(text).to include(":name")
      expect(text).to include(":full_name")
    end

    it "falls back to type param for rename_column backward compat" do
      response = described_class.call(action: "rename_column", table: "users", column: "name", type: "full_name")
      text = response.content.first[:text]
      expect(text).to include("rename_column :users, :name, :full_name")
    end

    it "rejects invalid table names with special characters" do
      response = described_class.call(action: "add_column", table: "users; DROP TABLE", column: "name")
      text = response.content.first[:text]
      expect(text).to include("Invalid table name")
    end

    it "rejects invalid column names with special characters" do
      response = described_class.call(action: "add_column", table: "users", column: "name; DROP")
      text = response.content.first[:text]
      expect(text).to include("Invalid column name")
    end

    it "allows column definition strings for create_table" do
      response = described_class.call(action: "create_table", table: "tags", column: "name:string,slug:string")
      text = response.content.first[:text]
      expect(text).to include("create_table :tags")
      expect(text).to include("t.string :name")
    end
  end

  describe "Strong Migrations integration" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        schema: { tables: { "users" => { columns: [ { name: "email", type: "string" } ] } } },
        models: {}
      })
    end

    context "when strong_migrations gem is absent" do
      before { allow(described_class).to receive(:strong_migrations_gem_present?).and_return(false) }

      it "does not include the warnings section for remove_column" do
        response = described_class.call(action: "remove_column", table: "users", column: "email")
        text = response.content.first[:text]
        expect(text).not_to include("Strong Migrations Warnings")
      end
    end

    context "when strong_migrations gem is present" do
      before { allow(described_class).to receive(:strong_migrations_gem_present?).and_return(true) }

      it "warns about remove_column needing safety_assured + ignored_columns" do
        response = described_class.call(action: "remove_column", table: "users", column: "email")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("ignored_columns")
        expect(text).to include("safety_assured")
      end

      it "warns about rename_column being unsafe under load" do
        response = described_class.call(action: "rename_column", table: "users", column: "email", new_name: "email_address")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("unsafe under load")
      end

      it "warns about change_type blocking writes" do
        response = described_class.call(action: "change_type", table: "users", column: "email", type: "text")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("blocks writes")
      end

      it "warns about add_index without :concurrently" do
        response = described_class.call(action: "add_index", table: "users", column: "email")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("algorithm: :concurrently")
      end

      it "does not warn about add_index when :concurrently is already specified" do
        response = described_class.call(action: "add_index", table: "users", column: "email", options: "algorithm: :concurrently")
        text = response.content.first[:text]
        expect(text).not_to include("Strong Migrations Warnings")
      end

      it "warns about add_association needing two-step foreign key validation" do
        response = described_class.call(action: "add_association", table: "users", column: "tenant")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("validate: false")
        expect(text).to include("validate_foreign_key")
      end

      it "warns about NOT NULL add_column without default" do
        response = described_class.call(action: "add_column", table: "users", column: "phone", type: "string", options: "null: false")
        text = response.content.first[:text]
        expect(text).to include("Strong Migrations Warnings")
        expect(text).to include("NOT NULL")
      end

      it "does not warn about add_column when nullable" do
        response = described_class.call(action: "add_column", table: "users", column: "phone", type: "string")
        text = response.content.first[:text]
        expect(text).not_to include("Strong Migrations Warnings")
      end
    end
  end
end
