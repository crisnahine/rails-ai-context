# frozen_string_literal: true

require "spec_helper"

# Three places reconstruct a namespaced constant name from a Prism node. They must
# all answer the same string, and that string is the source text with the root
# scope operator dropped.
RSpec.describe "constant path to string" do
  def superclass_node(source)
    Prism.parse(source).value.statements.body.first.superclass
  end

  def base_listener(node)
    RailsAiContext::Introspectors::Listeners::BaseListener.allocate.send(:constant_path_string, node)
  end

  def component(node)
    RailsAiContext::Introspectors::ComponentIntrospector.allocate.send(:constant_path_to_string, node)
  end

  def class_definition(node)
    RailsAiContext::Introspectors::Listeners::ClassDefinitionListener.allocate.send(:superclass_name, node)
  end

  def every_form(node)
    [ base_listener(node), component(node), class_definition(node) ]
  end

  {
    "Foo"                 => "Foo",
    "Foo::Bar"            => "Foo::Bar",
    "Foo::Bar::Baz"       => "Foo::Bar::Baz",
    "::Foo::Bar"          => "Foo::Bar",
    "ViewComponent::Base" => "ViewComponent::Base"
  }.each do |expression, expected|
    it "reads #{expression} as #{expected} everywhere" do
      expect(every_form(superclass_node("class X < #{expression}\nend"))).to all(eq(expected))
    end
  end

  it "keeps the call that roots a path rather than dropping it" do
    expect(every_form(superclass_node("class X < Foo.bar::Baz\nend"))).to all(eq("Foo.bar::Baz"))
  end

  it "keeps the self that roots a path rather than dropping it" do
    expect(every_form(superclass_node("class X < self::Foo\nend"))).to all(eq("self::Foo"))
  end

  it "answers a line-broken path with its source text, newline and all" do
    expect(every_form(superclass_node("class X < Foo::\n  Bar\nend"))).to all(eq("Foo::\n  Bar"))
  end

  it "agrees with DeclaredConstant, which already reads the name as source text" do
    node = superclass_node("class X < ::Admin::User\nend")
    expect(every_form(node)).to all(eq(node.slice.delete_prefix("::")))
  end

  it "answers nil where a non-constant superclass has no name" do
    node = superclass_node("class X < Struct.new(:a)\nend")
    expect(class_definition(node)).to be_nil
    expect(component(node)).to be_nil
  end
end
