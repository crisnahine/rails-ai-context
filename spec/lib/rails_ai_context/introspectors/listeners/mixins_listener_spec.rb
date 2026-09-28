# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MixinsListener do
  it "detects an included module" do
    results = parse_and_dispatch(<<~RUBY)
      class Post < ApplicationRecord
        include Publishable
      end
    RUBY

    expect(results.first).to include(macro: :include, name: "Publishable", ancestor: true, location: 2)
  end

  it "detects a prepended module as reaching the ancestor chain" do
    results = parse_and_dispatch("class Post\n  prepend Auditable\nend\n")

    expect(results.first).to include(macro: :prepend, name: "Auditable", ancestor: true)
  end

  # `extend` puts the module on the singleton class, so it never appears in
  # `ancestors` - the flag is what keeps the static tier's answer equal to the
  # booted tier's.
  it "records an extended module but does not call it an ancestor" do
    results = parse_and_dispatch("class Post\n  extend Searchable\nend\n")

    expect(results.first).to include(macro: :extend, name: "Searchable", ancestor: false)
  end

  it "does not call a module included inside `class << self` an ancestor" do
    results = parse_and_dispatch("class Post\n  class << self\n    include Sneaky\n  end\nend\n")

    expect(results.first).to include(macro: :include, name: "Sneaky", ancestor: false)
  end

  it "goes back to reporting ancestors after the singleton block closes" do
    results = parse_and_dispatch(<<~RUBY)
      class Post
        class << self
          include Sneaky
        end
        include Publishable
      end
    RUBY

    expect(results.map { |r| [ r[:name], r[:ancestor] ] }).to eq([ [ "Sneaky", false ], [ "Publishable", true ] ])
  end

  it "keeps the full path of a namespaced module" do
    results = parse_and_dispatch("class Post\n  include Admin::Publishable\nend\n")

    expect(results.first[:name]).to eq("Admin::Publishable")
  end

  it "records every module of a multi-argument include" do
    results = parse_and_dispatch("class Post\n  include Publishable, Auditable\nend\n")

    expect(results.map { |r| r[:name] }).to eq(%w[Publishable Auditable])
  end

  it "ignores an include whose argument is not a constant" do
    results = parse_and_dispatch("class Post\n  include build_module(:x)\nend\n")

    expect(results).to be_empty
  end

  it "ignores an include called on a receiver" do
    results = parse_and_dispatch("class Post\n  singleton_class.include Publishable\nend\n")

    expect(results).to be_empty
  end

  it "reads `send :include, X` as the include it is" do
    results = RailsAiContext::Introspectors::SourceIntrospector.walk_source(
      "class Post\n  send :include, Trackable\n  public_send(:extend, Finder)\n  send :before_save, :x\nend\n",
      { mixins: described_class }
    )[:mixins]

    expect(results.map { |r| [ r[:macro], r[:name], r[:ancestor] ] })
      .to eq([ [ :include, "Trackable", true ], [ :extend, "Finder", false ] ])
  end
end
