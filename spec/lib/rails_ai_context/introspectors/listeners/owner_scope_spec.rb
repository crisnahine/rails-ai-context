# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::OwnerScope do
  # Records the owner at each `mark :name` call, as the listeners that include the module do.
  let(:listener_class) do
    scope = described_class
    Class.new(RailsAiContext::Introspectors::Listeners::BaseListener) do
      include scope

      def on_call_node_enter(node)
        @results << { name: node.arguments.arguments.first.unescaped, owner: @owner_stack.dup } if node.name == :mark
      end
    end
  end

  def owners(source)
    listener = listener_class.new
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(Prism.parse(source).value)
    listener.results.to_h { |record| record.values_at(:name, :owner) }
  end

  it "reports no owner outside any class or module" do
    expect(owners("mark :top")).to eq("top" => [])
  end

  it "reports a class, and nothing again once the class ends" do
    expect(owners("class Post\n  mark :in\nend\nmark :after")).to eq("in" => %w[Post], "after" => [])
  end

  it "reports a module the same way" do
    expect(owners("module Taggable\n  mark :in\nend\nmark :after")).to eq("in" => %w[Taggable], "after" => [])
  end

  it "reports a nested class under its parents, and the parent again after it" do
    source = <<~RUBY
      module Blog
        class Post
          mark :before
          class Draft
            mark :inner
          end
          mark :after
        end
        mark :module
      end
    RUBY

    expect(owners(source)).to eq("before" => %w[Blog Post], "inner" => %w[Blog Post Draft], "after" => %w[Blog Post], "module" => %w[Blog])
  end

  it "reports a compact definition as written, with a leading :: taken off" do
    source = "class Blog::Post\n  mark :compact\nend\nmodule ::Admin::Reports\n  mark :rooted\nend\n"

    expect(owners(source)).to eq("compact" => %w[Blog::Post], "rooted" => %w[Admin::Reports])
  end

  it "reports a class opened from the root inside a module as the top-level class" do
    source = "module Shop\n  class ::Order\n    mark :rooted\n    class Line\n      mark :nested\n    end\n  end\n  mark :after\nend\n"

    expect(owners(source)).to eq("rooted" => %w[Order], "nested" => %w[Order Line], "after" => %w[Shop])
  end

  # Inside `module Shop`, Ruby finds the Shop of `class Shop::Draft` as ::Shop.
  it "reports a compact path whose first segment names an enclosing scope under that scope" do
    source = "module Shop\n  class Shop::Draft\n    mark :draft\n  end\n  class Other::Draft\n    mark :other\n  end\nend\n"

    expect(owners(source)).to eq("draft" => %w[Shop::Draft], "other" => %w[Shop Other::Draft])
  end

  it "reports a compact path under the nearest constant declared above it, as Ruby reads it" do
    nearer = "module Shop\n  module Shop; end\n  class Shop::Draft\n    mark :draft\n  end\nend\n"
    written = "module Shop\n  Shop::Draft = Class.new(Base) do\n    mark :draft\n  end\nend\n"

    expect(owners(nearer)["draft"].join("::")).to eq("Shop::Shop::Draft")
    expect(owners(written)["draft"].join("::")).to eq("Shop::Draft")
  end

  it "reports the class itself inside class << self" do
    source = "class Post\n  class << self\n    mark :singleton\n  end\n  mark :after\nend\n"

    expect(owners(source)).to eq("singleton" => %w[Post], "after" => %w[Post])
  end

  it "reports a reopened class each time it is opened" do
    source = "class Post\n  mark :first\nend\nclass Comment\n  mark :other\nend\nclass Post\n  mark :second\nend\n"

    expect(owners(source)).to eq("first" => %w[Post], "other" => %w[Comment], "second" => %w[Post])
  end

  describe "a constant built by Class.new, Struct.new, Module.new or Data.define with a block" do
    it "is the owner of what the block holds, under the name it is assigned to" do
      source = "class Post\n  Draft = Class.new(Post) do\n    mark :inner\n  end\n  mark :after\nend\n"

      expect(owners(source)).to eq("inner" => %w[Post Draft], "after" => %w[Post])
    end

    it "takes the full path it is assigned to" do
      expect(owners("Blog::Draft = Class.new do\n  mark :inner\nend\nmark :after")).to eq("inner" => %w[Blog::Draft], "after" => [])
    end

    it "opens the owner when the receiver is spelled ::Class" do
      source = "class Order\n  Line = ::Class.new(ApplicationRecord) do\n    mark :inner\n  end\n  mark :after\nend\n"

      expect(owners(source)).to eq("inner" => %w[Order Line], "after" => %w[Order])
    end

    # Struct.new, Module.new and Data.define evaluate their block in the new constant, as Class.new does.
    it "opens the owner for every builder that evaluates its block in the new constant" do
      source = "Limit = Struct.new(:max) do\n  mark :struct\nend\nMixin = ::Module.new do\n  mark :module\nend\n" \
               "Point = Data.define(:x) do\n  mark :data\nend\n"

      expect(owners(source)).to eq("struct" => %w[Limit], "module" => %w[Mixin], "data" => %w[Point])
    end

    # Ruby runs an `||=`'s right side only when the constant is not defined yet, so a block it never runs belongs to nothing.
    it "is the owner of an `||=` block that assigns, and no block's owner where the `||=` assigns nothing" do
      source = "class Post\n  Draft ||= Class.new(Post) do\n    mark :assigned\n  end\n  Blog::Line ||= Struct.new(:x) do\n    mark :path\n  end\n" \
               "  Draft ||= Class.new do\n    mark :unrun\n    class Inner\n      mark :unrun_inner\n    end\n  end\n  mark :after\nend\n"

      expect(owners(source)).to eq("assigned" => %w[Post Draft], "path" => %w[Post Blog::Line], "after" => %w[Post])
    end

    # Ruby: defined?(Loose), defined?(Inner) and defined?(Blog::Inner) are nil after each, as the block never runs.
    it "is no owner of a class an `||=` block that assigns nothing opens, at the top level, from the root or by a path" do
      expect(owners("class Post\n  Draft = 1\n  Draft ||= Class.new do\n    class ::Loose\n      mark :root_inner\n    end\n  end\nend\n")).to eq({})
      expect(owners("Draft = 1\nDraft ||= Class.new do\n  class Inner\n    mark :inner\n  end\nend\n")).to eq({})
      expect(owners("module Blog; end\nDraft = 1\nDraft ||= Module.new do\n  class Blog::Inner\n    mark :path\n  end\nend\n")).to eq({})
    end

    # Ruby: a block opens no scope, so `class Inner` in it defines Post::Inner, as Post::Inner.name says.
    it "owns a class a builder block opens by the scope around the block" do
      source = "class Post\n  Draft = Class.new do\n    class Inner\n      mark :inner\n    end\n    mark :draft\n  end\nend\n"

      expect(owners(source)).to eq("inner" => %w[Post Inner], "draft" => %w[Post Draft])
    end

    it "opens no owner for another call with a block" do
      source = "NAMES = build do\n  mark :call\nend\nKIND = Class.then do\n  mark :on_class\nend\nSHAPE = Data.new do\n  mark :data_new\nend\n"

      expect(owners(source)).to eq("call" => [], "on_class" => [], "data_new" => [])
    end

    it "keeps the outer one open when a constant is assigned inside its block" do
      source = "Draft = Class.new do\n  LIMIT = 3\n  mark :after_constant\nend\n"

      expect(owners(source)).to eq("after_constant" => %w[Draft])
    end
  end

  # Ruby: inside A::B, the Shop of `class Shop::Draft` is the A::Shop an `||=` or a multiple assignment wrote.
  it "reads a compact path's first segment against an `||=` or multiple assignment written above it" do
    [ "Shop ||= Module.new", "Shop, Mall = Module.new, Module.new" ].each do |write|
      expect(owners("module A\n  #{write}\n  module B\n    class Shop::Draft\n      mark :draft\n    end\n  end\nend\n")).to eq("draft" => %w[A::Shop::Draft])
    end
  end

  # Ruby: `V1 ||=` in V1 finds ::V1, and `M ||=` in Foo < Bar finds Bar::M, so neither assigns and each class nests where Ruby opens it.
  it "reads a compact path's first segment against the constant an `||=` that assigns nothing finds" do
    expect(owners("module V1\n  V1 ||= Module.new\n  class V1::Users\n    mark :users\n  end\nend\n")).to eq("users" => %w[V1::Users])
    expect(owners("class Bar\n  M = Module.new\nend\nclass Foo < Bar\n  M ||= Module.new\n  class M::Y\n    mark :y\n  end\nend\n"))
      .to eq("y" => %w[Bar::M::Y])
  end

  # Ruby: `Foo::M ||=` finds Bar::M through Foo's superclass and assigns nothing, so M in Foo is still Bar::M.
  it "reads a path `||=` as assigning nothing when the superclass of its scope holds the constant" do
    source = "class Bar\n  M = Module.new\nend\nclass Foo < Bar\n  Foo::M ||= Module.new\n  class M::Y\n    mark :y\n  end\nend\n"

    expect(owners(source)).to eq("y" => %w[Bar::M::Y])
  end

  # Ruby: Foo::M is Bar::M through Foo's superclass, so `class Foo::M::Y` opens Bar::M::Y.
  it "reads a compact path's later segments through the superclasses of the scope before them" do
    source = "class Bar\n  module M; end\nend\nclass Foo < Bar\n  Foo::M ||= Module.new\n  class Foo::M::Y\n    mark :y\n  end\nend\n"

    expect(owners(source)).to eq("y" => %w[Bar::M::Y])
  end
end
