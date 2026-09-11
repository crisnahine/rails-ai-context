# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::CallbacksListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    listener   = described_class.new
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(result.value)
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

  it "names a callback whose argument is a class object" do
    results = parse_and_dispatch("around_create Mastodon::Snowflake::Callbacks")
    expect(results.first).to include(type: "around_create", method: "Mastodon::Snowflake::Callbacks")
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end

  it "detects the touch, initialize and find callbacks" do
    results = parse_and_dispatch(<<~RUBY)
      after_touch :bust
      after_initialize :set_from_account
      after_find :log
    RUBY
    expect(results.map { |r| r[:type] }).to contain_exactly("after_touch", "after_initialize", "after_find")
  end

  # A lambda has no name to print, and its source slice spans lines - it
  # would break the bullet it lands in.
  it "reports a lambda argument as an inline block" do
    results = parse_and_dispatch("before_save ->(rec) { rec.slug = rec.title }")
    expect(results.first).to include(type: "before_save", method: "[inline_block]")
    expect(results.first[:confidence]).to eq("[INFERRED]")
  end

  it "records the declared macro name alongside the resolved type" do
    results = parse_and_dispatch("after_commit :sync, on: :create")
    expect(results.first).to include(name: "after_commit", type: "after_commit_on_create")
  end

  # `after_commit on: :create` has no target at all; reporting a block that
  # is not in the source made every renderer print "runs a block here".
  it "reports nothing for a macro that carries only keyword options" do
    expect(parse_and_dispatch("after_commit on: :create")).to be_empty
    expect(parse_and_dispatch("after_save unless: :skip?")).to be_empty
  end
end
