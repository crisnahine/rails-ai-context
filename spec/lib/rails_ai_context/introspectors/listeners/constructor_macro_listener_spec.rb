# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::ConstructorMacroListener do
  def records(source)
    RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { macros: described_class })[:macros]
  end

  it "records each macro's parameters and the class it is written in" do
    found = records(<<~RUBY)
      module Billing
        class Charge
          extend Dry::Initializer
          param :order, default: proc { nil }
          option :gateway, default: -> { :stripe }
        end
      end
    RUBY

    expect(found.map { |r| r[:owner] }.uniq).to eq([ %w[Billing Charge] ])
    expect(found.flat_map { |r| r[:params] }).to eq([ [ :opt, "order", "nil" ], [ :key, "gateway", ":stripe" ] ])
    expect(found.first[:values]).to eq([ "Dry::Initializer" ])
  end

  it "credits a Class.new block's macros to the constant it is assigned to" do
    found = records("module Svc\n  Money = Class.new(T::Struct) do\n    const :cents, Integer\n  end\nend\n")

    expect(found.map { |r| r[:owner] }).to eq([ %w[Svc Money] ])
  end

  it "reads static_facade's names after the method name" do
    expect(records("class A\n  static_facade :run, :user\nend\n").first[:params]).to eq([ [ :req, "user", nil ] ])
  end

  it "survives a macro with no literal name" do
    expect(records("class A < T::Struct\n  const name_var, String\n  prop\nend\n").flat_map { |r| r[:params] }).to eq([])
  end
end
