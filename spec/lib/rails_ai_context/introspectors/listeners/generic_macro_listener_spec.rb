# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::GenericMacroListener do
  it "detects specified macro calls" do
    results = parse_and_dispatch(<<~RUBY, :before_action, :after_action)
      before_action :authenticate!
      after_action :log_request
      some_other_call :foo
    RUBY

    expect(results.size).to eq(2)
    expect(results.map { |r| r[:macro] }).to contain_exactly(:before_action, :after_action)
  end

  # A nested describe would otherwise copy most of a spec file per level.
  it "records a block's source only for the macros asked to" do
    source = "describe 'x' do\n  # note\n  it 'y' do\n    run\n  end\nend\n"
    plain = parse_and_dispatch(source, :describe, :it)
    sourced = parse_and_dispatch(source, :describe, :it, block_source: [ :it ])

    expect(plain.map { |r| r[:block] }).to eq([ nil, nil ])
    expect(sourced.map { |r| r[:block] }).to eq([ nil, "do run; end" ])
  end

  it "records no source for a block passed as an argument" do
    results = parse_and_dispatch("queue_as(&PICK)", :queue_as, block_source: [ :queue_as ])
    expect(results.first[:block]).to be_nil
  end

  it "extracts symbol args" do
    results = parse_and_dispatch("before_action :auth, :set_locale", :before_action)
    expect(results.first[:args]).to eq([ :auth, :set_locale ])
  end

  it "reads an escaped symbol arg as the characters it names" do
    results = parse_and_dispatch('before_action :"set\tlocale"', :before_action)
    expect(results.first[:args]).to eq([ :"set\tlocale" ])
  end

  it "extracts keyword options" do
    results = parse_and_dispatch("before_action :auth, only: [:create, :update]", :before_action)
    expect(results.first[:options]).to have_key(:only)
  end

  it "detects self-receiver calls (self.method is a valid macro pattern)" do
    results = parse_and_dispatch("self.before_action :auth", :before_action)
    expect(results.size).to eq(1)
  end

  it "ignores calls with non-self receivers" do
    results = parse_and_dispatch("other.before_action :auth", :before_action)
    expect(results).to be_empty
  end

  it "includes line locations and confidence" do
    results = parse_and_dispatch("protect_from_forgery with: :exception", :protect_from_forgery)
    expect(results.first[:location]).to eq(1)
    expect(results.first[:confidence]).to be_a(String)
  end

  # A macro call inside another target macro's block is nested in it:
  # `string :title` inside `hash :order_params do ... end` is a key of that
  # hash, not a filter of the class.
  it "records the call whose block a nested call sits in" do
    results = parse_and_dispatch(<<~RUBY, :hash, :string, :object)
      hash :order_params do
        string :title, default: nil
      end

      object :account
    RUBY

    nested = results.find { |r| r[:macro] == :string }
    expect(nested[:parent_offset]).to be_an(Integer)
    expect(nested[:parent_offset]).to eq(results.find { |r| r[:macro] == :hash }[:offset])
    expect(results.find { |r| r[:macro] == :hash }[:parent_offset]).to be_nil
    expect(results.find { |r| r[:macro] == :object }[:parent_offset]).to be_nil
  end

  it "leaves a call in a block that is not a target macro unnested" do
    results = parse_and_dispatch(<<~RUBY, :string)
      %w[a b].each do |name|
        string name
      end
    RUBY

    expect(results.first).to include(parent_offset: nil)
    expect(results.first[:offset]).to be_a(Integer)
  end

  it "works with Proc factory in walk_source" do
    source = <<~RUBY
      devise :confirmable, :registerable
    RUBY

    result = RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, {
      devise: -> { described_class.new(:devise) }
    })

    expect(result[:devise].size).to eq(1)
    expect(result[:devise].first[:args]).to eq([ :confirmable, :registerable ])
  end
end
