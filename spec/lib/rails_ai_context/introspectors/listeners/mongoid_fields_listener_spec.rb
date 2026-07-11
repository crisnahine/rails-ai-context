# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MongoidFieldsListener do
  def results_for(source)
    listener = described_class.new
    dispatcher = Prism::Dispatcher.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(Prism.parse(source).value)
    listener.results
  end

  it "captures field declarations with types" do
    results = results_for(<<~RUBY)
      class User
        include Mongoid::Document
        field :name, type: String
        field :age, type: Integer
        field :tags
      end
    RUBY
    fields = results.select { |r| r[:macro] == :field }
    expect(fields.map { |f| f[:args].first }).to eq([ :name, :age, :tags ])
    expect(fields.first[:options][:type]).to eq("String")
  end

  it "captures embeds and store_in" do
    results = results_for(<<~RUBY)
      class Order
        embeds_many :line_items
        embedded_in :customer
        store_in collection: "legacy_orders"
      end
    RUBY
    expect(results.map { |r| r[:macro] }).to contain_exactly(:embeds_many, :embedded_in, :store_in)
    store = results.find { |r| r[:macro] == :store_in }
    expect(store[:options][:collection]).to eq("legacy_orders")
  end

  it "ignores receivered calls" do
    expect(results_for("config.field :nope")).to be_empty
  end
end
