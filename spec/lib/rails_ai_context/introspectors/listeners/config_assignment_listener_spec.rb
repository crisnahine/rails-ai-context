# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::ConfigAssignmentListener do
  def parse_and_dispatch(source, *roots)
    result     = Prism.parse(source)
    listener   = described_class.new(*roots)
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(result.value)
    listener.results
  end

  def assignments(source, *roots)
    parse_and_dispatch(source, *roots).select { |r| r[:assignment] }
  end

  it "reads a flat config assignment" do
    results = assignments("config.timeout_in = 30.minutes")

    expect(results.size).to eq(1)
    expect(results.first[:path]).to eq([ :timeout_in ])
    expect(results.first[:source]).to eq("30.minutes")
  end

  it "reads a nested config assignment" do
    results = assignments("config.action_mailer.delivery_method = :smtp")

    expect(results.first[:path]).to eq([ :action_mailer, :delivery_method ])
    expect(results.first[:value]).to eq(:smtp)
  end

  it "extracts literal values" do
    results = assignments(<<~RUBY)
      config.maximum_attempts = 5
      config.lock_strategy = :failed_attempts
      config.reconfirmable = true
      config.mailer_sender = "noreply@example.com"
    RUBY

    expect(results.map { |r| [ r[:path].first, r[:value] ] }).to eq([
      [ :maximum_attempts, 5 ],
      [ :lock_strategy, :failed_attempts ],
      [ :reconfirmable, true ],
      [ :mailer_sender, "noreply@example.com" ]
    ])
  end

  it "keeps the raw source for values it cannot evaluate" do
    results = assignments("config.password_length = 6..128")

    expect(results.first[:source]).to eq("6..128")
  end

  it "matches a chain rooted deeper than the receiver" do
    results = assignments("Rails.application.config.assets.paths = paths")

    expect(results.first[:path]).to eq([ :assets, :paths ])
  end

  it "records a bare config reference so block sections are visible" do
    results = parse_and_dispatch(<<~RUBY)
      config.jwt do |jwt|
        jwt.secret = "x"
      end
    RUBY

    jwt = results.find { |r| r[:path] == [ :jwt ] }
    expect(jwt[:assignment]).to be false
  end

  it "ignores assignments on other receivers" do
    expect(assignments("settings.timeout_in = 5")).to be_empty
  end

  it "accepts a custom root name" do
    results = assignments("setup.timeout_in = 5", :setup)

    expect(results.first[:path]).to eq([ :timeout_in ])
  end

  it "reports line locations" do
    results = assignments("\nconfig.timeout_in = 5")

    expect(results.first[:location]).to eq(2)
  end
end
