# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::OwnerScope do
  # Records the owner at each `mark :name` call, as the listeners that include the module do.
  let(:listener_class) do
    scope = described_class
    Class.new(RailsAiContext::Introspectors::Listeners::BaseListener) do
      include scope

      def on_call_node_enter(node)
        @results << [ node.arguments.arguments.first.unescaped, @owner_stack.dup ] if node.name == :mark
      end
    end
  end

  def owners(source)
    listener = listener_class.new
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(Prism.parse(source).value)
    listener.results.to_h
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

  it "reports the class itself inside class << self" do
    source = "class Post\n  class << self\n    mark :singleton\n  end\n  mark :after\nend\n"

    expect(owners(source)).to eq("singleton" => %w[Post], "after" => %w[Post])
  end

  it "reports a reopened class each time it is opened" do
    source = "class Post\n  mark :first\nend\nclass Comment\n  mark :other\nend\nclass Post\n  mark :second\nend\n"

    expect(owners(source)).to eq("first" => %w[Post], "other" => %w[Comment], "second" => %w[Post])
  end

  describe "a class built by Class.new with a block" do
    it "is the owner of what the block holds, under the name it is assigned to" do
      source = "class Post\n  Draft = Class.new(Post) do\n    mark :inner\n  end\n  mark :after\nend\n"

      expect(owners(source)).to eq("inner" => %w[Post Draft], "after" => %w[Post])
    end

    it "takes the full path it is assigned to" do
      expect(owners("Blog::Draft = Class.new do\n  mark :inner\nend\nmark :after")).to eq("inner" => %w[Blog::Draft], "after" => [])
    end

    it "is the only constant value that opens an owner" do
      source = "LIMIT = Struct.new(:max) do\n  mark :struct\nend\nNAMES = build do\n  mark :call\nend\nKIND = Class.then do\n  mark :on_class\nend\n"

      expect(owners(source)).to eq("struct" => [], "call" => [], "on_class" => [])
    end

    it "keeps the outer one open when a constant is assigned inside its block" do
      source = "Draft = Class.new do\n  LIMIT = 3\n  mark :after_constant\nend\n"

      expect(owners(source)).to eq("after_constant" => %w[Draft])
    end
  end
end
