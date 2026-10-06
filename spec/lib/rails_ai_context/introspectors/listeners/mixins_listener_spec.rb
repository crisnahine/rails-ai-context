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

  it "records the module a concerning block builds and includes, under the class's name" do
    results = parse_and_dispatch(<<~RUBY)
      class WidgetLog < ApplicationRecord
        concerning :Exporting do
          def export; end
        end
        concerning :Stamping, prepend: true do
        end
      end
    RUBY

    expect(results).to contain_exactly(
      include(macro: :include, name: "WidgetLog::Exporting", ancestor: true, location: 2, inline: true),
      include(macro: :prepend, name: "WidgetLog::Stamping", ancestor: true, location: 5, inline: true)
    )
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
    results = parse_and_dispatch("class Post\n  builder.include Publishable\n  base.singleton_class.include Auditable\nend\n")

    expect(results).to be_empty
  end

  it "reads an include or prepend on the class's own singleton class as giving class methods, not an ancestor" do
    results = parse_and_dispatch("class Post\n  singleton_class.include Publishable\n  self.singleton_class.prepend Auditable\n  singleton_class.extend Other\nend\n")

    expect(results.map { |r| [ r[:macro], r[:name], r[:ancestor] ] })
      .to eq([ [ :singleton_include, "Publishable", false ], [ :singleton_prepend, "Auditable", false ] ])
  end

  it "reads `send :include, X` as the include it is" do
    results = RailsAiContext::Introspectors::SourceIntrospector.walk_source(
      "class Post\n  send :include, Trackable\n  public_send(:extend, Finder)\n  send :before_save, :x\nend\n",
      { mixins: described_class }
    )[:mixins]

    expect(results.map { |r| [ r[:macro], r[:name], r[:ancestor] ] })
      .to eq([ [ :include, "Trackable", true ], [ :extend, "Finder", false ] ])
  end

  it "reads GitLab's prepend_mod_with and its siblings as mixing in each edition's module" do
    results = parse_and_dispatch(<<~RUBY)
      class Note
        include_mod_with "Noteable"
        prepend_mod
      end
      Note.prepend_mod_with("Note")
      Note.extend_mod_with(name)
      Note.prepend_mod_with("Note", namespace: Foo)
    RUBY

    expect(results.map { |r| r.slice(:macro, :name, :ancestor, :receiver, :edition) }).to eq([
      { macro: :include, name: "EE::Noteable", ancestor: true, edition: true },
      { macro: :include, name: "JH::Noteable", ancestor: true, edition: true },
      { macro: :prepend, name: "EE::Note", ancestor: true, edition: true },
      { macro: :prepend, name: "JH::Note", ancestor: true, edition: true },
      { macro: :prepend, name: "EE::Note", ancestor: false, receiver: "Note", edition: true },
      { macro: :prepend, name: "JH::Note", ancestor: false, receiver: "Note", edition: true }
    ])
  end
end
