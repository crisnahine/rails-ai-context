# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::ValidationsListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects validates with presence" do
    results = parse_and_dispatch("validates :email, presence: true")
    expect(results.size).to eq(1)
    expect(results.first[:kind]).to eq(:presence)
    expect(results.first[:attributes]).to eq([ "email" ])
  end

  it "splits multiple validation kinds" do
    results = parse_and_dispatch("validates :email, presence: true, uniqueness: true")
    kinds = results.map { |r| r[:kind] }
    expect(kinds).to contain_exactly(:presence, :uniqueness)
  end

  it "detects multiple attributes" do
    results = parse_and_dispatch("validates :first_name, :last_name, presence: true")
    expect(results.first[:attributes]).to contain_exactly("first_name", "last_name")
  end

  it "detects validates_presence_of" do
    results = parse_and_dispatch("validates_presence_of :title")
    expect(results.first[:kind]).to eq(:presence)
    expect(results.first[:attributes]).to eq([ "title" ])
  end

  it "detects custom validate" do
    results = parse_and_dispatch("validate :check_constraints")
    expect(results.first[:kind]).to eq(:custom)
    expect(results.first[:attributes]).to eq([ "check_constraints" ])
  end

  it "detects multiple custom validates" do
    results = parse_and_dispatch("validate :check_a, :check_b")
    expect(results.size).to eq(2)
    methods = results.flat_map { |r| r[:attributes] }
    expect(methods).to contain_exactly("check_a", "check_b")
  end

  it "includes confidence tag" do
    results = parse_and_dispatch("validates :email, presence: true")
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end
end
