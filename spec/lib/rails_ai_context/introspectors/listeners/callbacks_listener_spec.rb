# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::CallbacksListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects before_save callback" do
    results = parse_and_dispatch("before_save :normalize_email")
    expect(results.size).to eq(1)
    expect(results.first).to include(type: "before_save", method: "normalize_email")
  end

  it "detects after_create callback" do
    results = parse_and_dispatch("after_create :send_welcome")
    expect(results.first).to include(type: "after_create", method: "send_welcome")
  end

  it "detects after_commit with on: option" do
    results = parse_and_dispatch("after_commit :log_change, on: :update")
    expect(results.first[:type]).to eq("after_commit_on_update")
  end

  it "detects multiple callback methods" do
    results = parse_and_dispatch("before_save :normalize_email, :set_defaults")
    expect(results.size).to eq(2)
    methods = results.map { |r| r[:method] }
    expect(methods).to contain_exactly("normalize_email", "set_defaults")
  end

  it "includes confidence tag" do
    results = parse_and_dispatch("before_save :normalize_email")
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end

  it "emits separate entries for multi-event on: option" do
    results = parse_and_dispatch("after_commit :sync, on: [:create, :update]")
    expect(results.size).to eq(2)
    types = results.map { |r| r[:type] }
    expect(types).to contain_exactly("after_commit_on_create", "after_commit_on_update")
    expect(results.map { |r| r[:method] }).to all(eq("sync"))
  end

  it "includes line location" do
    results = parse_and_dispatch("after_destroy :cleanup")
    expect(results.first[:location]).to eq(1)
  end
end
