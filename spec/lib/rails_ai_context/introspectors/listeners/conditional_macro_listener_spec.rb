# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::ConditionalMacroListener do
  def calls_in(source)
    RailsAiContext::Introspectors::SourceIntrospector
      .walk_source(source, { calls: -> { described_class.new(:use) } })[:calls]
  end

  it "records the branch a macro sits under, and none for one outside a branch" do
    calls = calls_in(<<~RUBY)
      use Rack::Deflater
      if Rails.env.test?
        use Rack::Lint
      end
    RUBY

    expect(calls.map { |call| [ call[:values].first, call.key?(:condition) ] }).to eq([ [ "Rack::Deflater", false ], [ "Rack::Lint", true ] ])
    expect(calls.last[:condition].to_s).to include("Rails.env.test?")
  end
end
