# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::GenericMacroListener do
  def parse_and_dispatch(source, *methods)
    result     = Prism.parse(source)
    listener   = described_class.new(*methods)
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(result.value)
    listener.results
  end

  it "detects specified macro calls" do
    results = parse_and_dispatch(<<~RUBY, :before_action, :after_action)
      before_action :authenticate!
      after_action :log_request
      some_other_call :foo
    RUBY

    expect(results.size).to eq(2)
    expect(results.map { |r| r[:macro] }).to contain_exactly(:before_action, :after_action)
  end

  it "extracts symbol args" do
    results = parse_and_dispatch("before_action :auth, :set_locale", :before_action)
    expect(results.first[:args]).to eq([ :auth, :set_locale ])
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
  it "records the target macro a nested call sits inside" do
    results = parse_and_dispatch(<<~RUBY, :hash, :string, :object)
      hash :order_params do
        string :title, default: nil
      end

      object :account
    RUBY

    nested = results.find { |r| r[:macro] == :string }
    expect(nested[:nested_in]).to eq(:hash)
    expect(nested[:parent_location]).to eq(1)
    expect(results.find { |r| r[:macro] == :hash }[:nested_in]).to be_nil
    expect(results.find { |r| r[:macro] == :object }[:nested_in]).to be_nil
  end

  it "leaves a call in a block that is not a target macro unnested" do
    results = parse_and_dispatch(<<~RUBY, :string)
      %w[a b].each do |name|
        string name
      end
    RUBY

    expect(results.first[:nested_in]).to be_nil
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
