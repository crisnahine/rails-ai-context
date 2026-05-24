# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::ChainedCallListener do
  def parse_and_dispatch(source, *methods)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new(*methods)
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects method calls with receivers" do
    results = parse_and_dispatch(<<~RUBY, :variant)
      class User < ApplicationRecord
        def thumb
          avatar.variant(:thumb, resize_to_limit: [100, 100])
        end
      end
    RUBY

    expect(results.size).to eq(1)
    expect(results.first[:method]).to eq("variant")
    expect(results.first[:args]).to eq([ :thumb ])
  end

  it "ignores receiver-less calls" do
    results = parse_and_dispatch("variant(:thumb)", :variant)
    expect(results).to be_empty
  end

  it "filters by target method names" do
    results = parse_and_dispatch(<<~RUBY, :variant)
      image.variant(:thumb)
      image.purge
      image.url
    RUBY

    expect(results.size).to eq(1)
    expect(results.first[:method]).to eq("variant")
  end

  it "extracts keyword options" do
    results = parse_and_dispatch(<<~RUBY, :variant)
      avatar.variant(:thumb, resize_to_limit: [100, 100])
    RUBY

    expect(results.first[:options]).to have_key(:resize_to_limit)
  end

  it "accepts multiple target methods" do
    results = parse_and_dispatch(<<~RUBY, :variant, :includes)
      avatar.variant(:thumb)
      Post.includes(:comments)
    RUBY

    expect(results.size).to eq(2)
    methods = results.map { |r| r[:method] }
    expect(methods).to contain_exactly("variant", "includes")
  end

  it "includes line locations" do
    results = parse_and_dispatch(<<~RUBY, :variant)
      avatar.variant(:thumb)
    RUBY

    expect(results.first[:location]).to eq(1)
  end
end

RSpec.describe RailsAiContext::Introspectors::Listeners::VariantCallListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects variant calls without constructor args" do
    results = parse_and_dispatch("image.variant(:thumb)")
    expect(results.size).to eq(1)
    expect(results.first[:args]).to eq([ :thumb ])
  end
end
