# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MigrationDslListener do
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
    expect(results.size).to eq(1)
    expect(results.first).to include(action: :create_table, table: "users")
  end

  it "detects add_column" do
    results = parse_and_dispatch('add_column "users", "email", :string')
    expect(results.size).to eq(1)
    expect(results.first).to include(action: :add_column, table: "users", column: "email", column_type: "string")
  end

  it "detects remove_column" do
    results = parse_and_dispatch('remove_column "users", "legacy_field"')
    expect(results.size).to eq(1)
    expect(results.first).to include(action: :remove_column, table: "users", column: "legacy_field")
  end

  it "detects add_index with single column" do
    results = parse_and_dispatch('add_index "users", "email", unique: true')
    expect(results.size).to eq(1)
    expect(results.first).to include(action: :add_index, table: "users")
    expect(results.first[:columns]).to eq(["email"])
    expect(results.first[:options]).to include(unique: true)
  end

  it "detects add_index with multiple columns" do
    results = parse_and_dispatch('add_index "users", ["first_name", "last_name"]')
    expect(results.first[:columns]).to eq(["first_name", "last_name"])
  end

  it "detects rename_column" do
    results = parse_and_dispatch('rename_column "users", "name", "full_name"')
    expect(results.size).to eq(1)
    expect(results.first).to include(action: :rename_column, table: "users", column: "name", new_name: "full_name")
  end

  it "detects add_reference" do
    results = parse_and_dispatch('add_reference "posts", :user, foreign_key: true')
    expect(results.size).to eq(1)
    expect(results.first).to include(action: :add_reference, table: "posts", ref: "user")
    expect(results.first[:options]).to include(foreign_key: true)
  end

  it "detects change_column_default" do
    results = parse_and_dispatch('change_column_default "users", "admin", from: false, to: true')
    expect(results.size).to eq(1)
    expect(results.first).to include(action: :change_column_default, table: "users", column: "admin")
    expect(results.first[:options]).to include(from: false, to: true)
  end

  it "detects add_foreign_key" do
    results = parse_and_dispatch('add_foreign_key "posts", "users"')
    expect(results.size).to eq(1)
    expect(results.first).to include(action: :add_foreign_key, table: "posts", to_table: "users")
  end

  it "detects a full migration" do
    results = parse_and_dispatch(<<~RUBY)
      create_table "comments" do |t|
      end
      add_column "comments", "body", :text
      add_reference "comments", :post, foreign_key: true
      add_index "comments", ["post_id", "created_at"]
    RUBY

    actions = results.map { |r| r[:action] }
    expect(actions).to eq([:create_table, :add_column, :add_reference, :add_index])
  end

  it "detects drop_table" do
    results = parse_and_dispatch('drop_table "legacy_users"')
    expect(results.first).to include(action: :drop_table, table: "legacy_users")
  end

  it "includes line locations" do
    results = parse_and_dispatch(<<~RUBY)
      add_column "users", "phone", :string
      add_index "users", "phone"
    RUBY

    expect(results[0][:location]).to eq(1)
    expect(results[1][:location]).to eq(2)
  end
end
