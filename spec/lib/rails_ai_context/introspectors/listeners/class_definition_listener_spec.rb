# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::ClassDefinitionListener do
  def classes(source)
    RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, {
      classes: described_class
    })[:classes]
  end

  it "reads a class and its superclass" do
    results = classes("class Post < ApplicationRecord; end")

    expect(results.first).to include(name: "Post", superclass: "ApplicationRecord")
  end

  it "resolves namespaced names on both sides" do
    results = classes("class Admin::User < Admin::BaseRecord; end")

    expect(results.first).to include(name: "Admin::User", superclass: "Admin::BaseRecord")
  end

  it "resolves a class nested inside a module" do
    results = classes(<<~RUBY)
      module Admin
        class User < ApplicationRecord
        end
      end
    RUBY

    expect(results.first[:name]).to eq("User")
  end

  it "reports nil for a class with no superclass" do
    expect(classes("class Plain; end").first[:superclass]).to be_nil
  end

  it "reports nil for a computed superclass" do
    results = classes("class Point < Struct.new(:x, :y); end")

    expect(results.first).to include(name: "Point", superclass: nil)
  end

  it "returns every class in source order with its line" do
    results = classes(<<~RUBY)
      class First < ApplicationRecord
      end

      class Second < First
      end
    RUBY

    expect(results.map { |c| [ c[:name], c[:location] ] }).to eq([ [ "First", 1 ], [ "Second", 4 ] ])
  end

  it "ignores singleton class bodies" do
    results = classes(<<~RUBY)
      class Post < ApplicationRecord
        class << self
          def scope_names = []
        end
      end
    RUBY

    expect(results.map { |c| c[:name] }).to eq([ "Post" ])
  end

  it "records the nesting a bare superclass is read in" do
    results = classes(<<~RUBY)
      class Admin::Compact < Base; end
      module Admin
        class Nested < Base; end
        module Reports
          class Deep < Base; end
          class Rooted < ::Base; end
        end
        class ::Top < Base; end
      end
    RUBY

    expect(results.to_h { |r| [ r[:name], r[:nesting] ] }).to eq(
      "Admin::Compact" => [], "Nested" => %w[Admin], "Deep" => %w[Admin::Reports Admin],
      "Rooted" => [], "Top" => %w[Admin]
    )
  end

  # Inside `module Shop`, the Shop of `class Shop::Draft` is ::Shop, so Module.nesting in Draft is [Shop::Draft, Shop].
  it "nests a compact path whose first segment names an enclosing scope under that scope" do
    results = classes("module Shop\n  class Shop::Draft\n    class Line < Base; end\n  end\nend\n")

    expect(results.to_h { |r| [ r[:name], r[:nesting] ] }).to eq("Shop::Draft" => %w[Shop], "Line" => %w[Shop::Draft Shop])
  end

  # Ruby tries Shop::Shop before ::Shop: Module.nesting in Line is [Shop::Shop::Draft::Line, Shop::Shop::Draft, Shop].
  it "nests a compact path under the nearest constant declared above it" do
    results = classes("module Shop\n  module Shop; end\n  class Shop::Draft\n    class Line < Base; end\n  end\nend\n")

    expect(results.to_h { |r| [ r[:name], r[:nesting] ] }).to eq("Shop::Draft" => %w[Shop], "Line" => %w[Shop::Shop::Draft Shop])
  end

  # A constant write declares the constant as a module open does: Module.nesting in Line is [Shop::Shop::Draft::Line, Shop::Shop::Draft, Shop].
  it "reads a compact path's first segment against a constant written above it" do
    results = classes("module Shop\n  Shop = Class.new\n  class Shop::Draft\n    class Line < Base; end\n  end\nend\n")

    expect(results.to_h { |r| [ r[:name], r[:nesting] ] }).to eq("Shop::Draft" => %w[Shop], "Line" => %w[Shop::Shop::Draft Shop])
  end

  # Ruby: Module.nesting in Line is [A::Shop::Draft::Line, A::Shop::Draft, A::B, A] after `Shop ||=` or `Shop, Mall =` in A.
  it "reads a compact path's first segment against a constant an `||=` or a multiple assignment wrote" do
    [ "Shop ||= Module.new", "Shop, Mall = Module.new, Module.new" ].each do |write|
      results = classes("module A\n  #{write}\n  module B\n    class Shop::Draft < Base\n      class Line < Base; end\n    end\n  end\nend\n")

      expect(results.find { |r| r[:name] == "Line" }[:nesting]).to eq(%w[A::Shop::Draft A::B A])
    end
  end

  # Ruby: Module.nesting in Line is [V1::Users::Line, V1::Users, V1], and [Bar::M::Y::Line, Bar::M::Y, Foo] where Foo < Bar.
  it "reads a compact path's first segment against the constant an `||=` that assigns nothing finds" do
    results = classes("module V1\n  V1 ||= Module.new\n  class V1::Users\n    class Line; end\n  end\nend\n" \
                      "class Bar\n  M = Module.new\nend\nclass Foo < Bar\n  M ||= Module.new\n  class M::Y\n    class Line; end\n  end\nend\n")

    expect(results.select { |r| r[:name] == "Line" }.map { |r| r[:nesting] }).to eq([ %w[V1::Users V1], %w[Bar::M::Y Foo] ])
  end
end
