# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::MigrationReplay::Statements do
  let(:tables) { {} }

  def apply(entry)
    described_class.apply({ options: {} }.merge(entry), tables, "bigint")
  end

  def columns(table)
    tables[table][:columns].map { |column| column[:name] }
  end

  # The replay keeps whether the key has its own sequence until its tables are read.
  it "seeds a created table with the key column a dump would show" do
    apply(action: :create_table, table: "users")

    expect(tables["users"][:columns]).to eq([ { name: "id", type: "bigint", null: false, primary_key: true, own_sequence: true } ])
  end

  it "adds, renames and removes columns the way the migration runs them" do
    apply(action: :create_table, table: "users")
    apply(action: :add_column, table: "users", column: "age", column_type: "integer", options: { null: false })
    apply(action: :add_column, table: "users", column: "email", column_type: "string", options: { default: "x" })
    apply(action: :rename_column, table: "users", column: "age", new_name: "years")
    apply(action: :remove_column, table: "users", column: "email")

    expect(columns("users")).to eq(%w[id years])
    expect(tables["users"][:columns].last).to include(name: "years", type: "integer", null: false)
  end

  it "renames and drops a table" do
    apply(action: :create_table, table: "users")
    apply(action: :rename_table, table: "users", new_name: "people")
    expect(tables.keys).to eq(%w[people])

    apply(action: :drop_table, table: "people")
    expect(tables).to be_empty
  end

  it "sets and clears a column's null constraint and default" do
    apply(action: :create_table, table: "users")
    apply(action: :add_column, table: "users", column: "state", column_type: "string")
    apply(action: :change_column_null, table: "users", column: "state", null: false)
    apply(action: :change_column_default, table: "users", column: "state", options: { from: nil, to: "open" })

    state = tables["users"][:columns].find { |column| column[:name] == "state" }
    expect(state).to include(null: false)
    expect(state[:default]).to be_present

    apply(action: :change_column_null, table: "users", column: "state", null: true)
    expect(state).not_to have_key(:null)
  end

  it "adds an index to the table it names" do
    apply(action: :create_table, table: "users")
    apply(action: :add_column, table: "users", column: "email", column_type: "string")
    apply(action: :add_index, table: "users", columns: [ "email" ], options: { unique: true })

    expect(tables["users"][:indexes]).to include(a_hash_including(columns: [ "email" ], unique: true))
  end

  # Compatibility::V5_0#create_table gives an integer or bigint key default: nil, except a bigint key on MySQL.
  it "gives a Migration[5.0] key the default Rails' compatibility layer gives it" do
    entry = { migration_version: [ 5, 0 ] }
    given = %w[postgresql trilogy mysql2].product(%w[integer bigint]).map do |adapter, id|
      described_class.legacy_key_options({ id: id }, entry, adapter).key?(:default)
    end

    expect(given).to eq([ true, true, true, false, true, false ])
  end

  it "leaves a statement on a table it never created alone" do
    apply(action: :add_column, table: "ghosts", column: "x", column_type: "string")

    expect(tables).to be_empty
  end
end
