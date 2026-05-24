# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::SchemaDslListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects create_table" do
    results = parse_and_dispatch('create_table "users" do |t|; end')
    tables = results.select { |r| r[:type] == :create_table }
    expect(tables.size).to eq(1)
    expect(tables.first).to include(table: "users")
  end

  it "detects string column" do
    results = parse_and_dispatch('t.string "email"')
    cols = results.select { |r| r[:type] == :column }
    expect(cols.size).to eq(1)
    expect(cols.first).to include(column_type: "string", name: "email")
  end

  it "detects column with options" do
    results = parse_and_dispatch('t.integer "age", null: false, default: 0')
    cols = results.select { |r| r[:type] == :column }
    expect(cols.first[:options]).to include(null: false, default: 0)
  end

  it "detects various column types" do
    results = parse_and_dispatch(<<~RUBY)
      t.string "name"
      t.integer "count"
      t.boolean "active"
      t.datetime "created_at"
      t.jsonb "metadata"
      t.uuid "external_id"
      t.references "user"
    RUBY

    cols = results.select { |r| r[:type] == :column }
    types = cols.map { |c| c[:column_type] }
    expect(types).to eq(%w[string integer boolean datetime jsonb uuid references])
  end

  it "detects t.index" do
    results = parse_and_dispatch('t.index ["email"], unique: true')
    indexes = results.select { |r| r[:type] == :index }
    expect(indexes.size).to eq(1)
    expect(indexes.first[:columns]).to eq([ "email" ])
    expect(indexes.first[:options]).to include(unique: true)
  end

  it "detects composite index" do
    results = parse_and_dispatch('t.index ["user_id", "created_at"]')
    indexes = results.select { |r| r[:type] == :index }
    expect(indexes.first[:columns]).to eq([ "user_id", "created_at" ])
  end

  it "detects add_foreign_key" do
    results = parse_and_dispatch('add_foreign_key "posts", "users"')
    fks = results.select { |r| r[:type] == :foreign_key }
    expect(fks.size).to eq(1)
    expect(fks.first).to include(from: "posts", to: "users")
  end

  it "detects create_enum" do
    results = parse_and_dispatch('create_enum "status", ["draft", "published", "archived"]')
    enums = results.select { |r| r[:type] == :enum }
    expect(enums.size).to eq(1)
    expect(enums.first).to include(name: "status", values: [ "draft", "published", "archived" ])
  end

  it "detects a full schema block" do
    results = parse_and_dispatch(<<~RUBY)
      create_table "users" do |t|
        t.string "email", null: false
        t.string "name"
        t.boolean "admin", default: false
        t.index ["email"], unique: true
      end
      add_foreign_key "posts", "users"
    RUBY

    types = results.map { |r| r[:type] }
    expect(types).to include(:create_table, :column, :index, :foreign_key)
  end

  it "includes line locations" do
    results = parse_and_dispatch(<<~RUBY)
      create_table "users" do |t|
        t.string "email"
      end
    RUBY

    table = results.find { |r| r[:type] == :create_table }
    col = results.find { |r| r[:type] == :column }
    expect(table[:location]).to eq(1)
    expect(col[:location]).to eq(2)
  end
end
