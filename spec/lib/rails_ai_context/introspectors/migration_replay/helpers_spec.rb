# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::MigrationReplay::Helpers do
  def tree(source)
    Prism.parse(source).value
  end

  describe ".table_helper_defs" do
    it "finds a method that hands its first argument and block to create_table" do
      source = <<~RUBY
        class Tables
          def create_unlogged_table(name, &block)
            create_table(name, options: "UNLOGGED", &block)
          end
          def unrelated(name)
            puts name
          end
        end
      RUBY
      helpers = []

      ranges = described_class.table_helper_defs(tree(source), helpers)

      expect(helpers).to eq([ :create_unlogged_table ])
      expect(ranges).to eq([ 2..4 ])
    end
  end

  describe ".follow_local_methods" do
    # A migration's private method runs where change calls it, so its
    # statements take the call's place.
    it "splices a private method's statements in where change calls it" do
      source = <<~RUBY
        class AddThings < ActiveRecord::Migration[7.1]
          def change
            add_column :users, :a, :string
            add_more
          end

          private

          def add_more
            add_column :users, :b, :string
          end
        end
      RUBY
      entries = [ { action: :add_column, column: "a", location: 3 }, { action: :add_column, column: "b", location: 10 } ]

      result = described_class.follow_local_methods(tree(source), entries, [])

      expect(result.map { |entry| [ entry[:column], entry[:location] ] }).to eq([ [ "a", 3 ], [ "b", 4 ] ])
    end

    it "keeps a method only down calls out of the replay" do
      source = <<~RUBY
        class Undo < ActiveRecord::Migration[7.1]
          def up
            add_column :users, :a, :string
          end

          def down
            undo_it
          end

          def undo_it
            remove_column :users, :a
          end
        end
      RUBY
      entries = [ { action: :add_column, column: "a", location: 3 }, { action: :remove_column, column: "a", location: 11 } ]

      result = described_class.follow_local_methods(tree(source), entries, [])

      expect(result.map { |entry| entry[:action] }).to eq([ :add_column ])
    end
  end

  describe ".module_helper_entries" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    it "replays a one-statement module helper with the caller's arguments" do
      FileUtils.mkdir_p(File.join(@root, "lib"))
      File.write(File.join(@root, "lib", "migration_helpers.rb"), <<~RUBY)
        module MigrationHelpers
          def add_flag(table, name)
            add_column table, name, :boolean, default: false
          end
        end
      RUBY
      source = <<~RUBY
        class AddFlags < ActiveRecord::Migration[7.1]
          include MigrationHelpers
          def change
            add_flag :users, :admin
          end
        end
      RUBY

      entries = described_class.module_helper_entries(tree(source), @root)

      expect(entries).to contain_exactly(a_hash_including(action: :add_column, table: "users", column: "admin", location: 4))
    end

    it "substitutes a parameter read after multibyte text in the helper at its own place" do
      FileUtils.mkdir_p(File.join(@root, "lib"))
      File.write(File.join(@root, "lib", "migration_helpers.rb"), <<~RUBY)
        module MigrationHelpers
          def add_note(table, name)
            add_column table, :note, :string, comment: "é", default: name
          end
        end
      RUBY
      source = "class X < ActiveRecord::Migration[7.1]\n  include MigrationHelpers\n  def change\n    add_note :posts, \"x\"\n  end\nend\n"

      entries = described_class.module_helper_entries(tree(source), @root)

      expect(entries).to contain_exactly(a_hash_including(action: :add_column, table: "posts", column: "note", options: { comment: "é", default: "x" }))
    end

    it "marks a larger helper that reaches the schema as not replayed" do
      FileUtils.mkdir_p(File.join(@root, "lib"))
      File.write(File.join(@root, "lib", "migration_helpers.rb"), <<~RUBY)
        module MigrationHelpers
          def add_pair(table)
            add_column table, :a, :string
            add_column table, :b, :string
          end
        end
      RUBY
      source = "class X < ActiveRecord::Migration[7.1]\n  include MigrationHelpers\n  def change\n    add_pair :users\n  end\nend\n"

      entries = described_class.module_helper_entries(tree(source), @root)

      expect(entries).to eq([ { kind: :not_replayed, location: 4 } ])
    end
  end

  describe ".app_constant_call_markers" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    it "marks a call to a lib class method named for a schema change" do
      FileUtils.mkdir_p(File.join(@root, "lib"))
      File.write(File.join(@root, "lib", "schema_tools.rb"), "class SchemaTools\n  def self.add_audit_columns(t)\n  end\nend\n")
      source = "class X < ActiveRecord::Migration[7.1]\n  def change\n    SchemaTools.add_audit_columns(:users)\n  end\nend\n"

      expect(described_class.app_constant_call_markers(tree(source), @root)).to eq([ { kind: :not_replayed, location: 3 } ])
    end
  end
end
