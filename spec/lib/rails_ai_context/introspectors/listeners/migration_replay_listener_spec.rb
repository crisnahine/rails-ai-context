# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MigrationReplayListener do
  def downs(results) = results.select { |r| r[:kind] == :down }.map { |r| r[:range] }
  def timestamps(results) = results.select { |r| r[:action] == :add_timestamps }.map { |r| r[:location] }

  it "records a down method and a down block as down ranges, and a revert block as its own" do
    results = parse_and_dispatch(<<~RUBY)
      class Migrate < ActiveRecord::Migration[7.1]
        def up
          create_table :a
        end

        def down
          drop_table :a
        end

        def change
          reversible do |dir|
            dir.down { drop_table :b }
          end
          revert do
            create_table :c
          end
        end
      end
    RUBY

    expect(downs(results)).to eq([ 6..8, 12..12 ])
    expect(results.select { |r| r[:kind] == :revert }.map { |r| r[:range] }).to eq([ 14..16 ])
  end

  it "records t.timestamps whether t reads as a local or a bare call" do
    results = parse_and_dispatch(<<~RUBY)
      create_table :posts do |t|
        t.timestamps
      end
      t.timestamps
      other.timestamps
    RUBY

    expect(timestamps(results)).to eq([ 2, 4 ])
  end

  it "reads a block's t. method as the statement it runs, on no table of its own" do
    results = parse_and_dispatch(<<~RUBY)
      change_table :posts do |t|
        t.rename :a, :b
        t.change_null :c, false
        t.remove_timestamps
      end
      remove_columns :posts, :d, :e
      remove_columns table_name, :f
    RUBY

    expect(results).to eq([
      { action: :rename_column, column: "a", new_name: "b", options: {}, location: 2, block: true },
      { action: :change_column_null, column: "c", null: false, options: {}, location: 3, block: true },
      { action: :remove_columns, columns: %w[created_at updated_at], options: {}, location: 4, block: true },
      { action: :remove_columns, table: "posts", columns: %w[d e], options: {}, location: 6 },
      { kind: :not_replayed, location: 7 }
    ])
  end

  it "does not see revert called with a migration class" do
    results = parse_and_dispatch("revert CreatePosts\n")

    expect(downs(results)).to be_empty
  end
end
