# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Confidence do
  describe ".for_node" do
    def parse_call(source)
      result = Prism.parse(source)
      # Find the first CallNode in the AST
      find_call_node(result.value)
    end

    def find_call_node(node)
      return node if node.is_a?(Prism::CallNode)

      node.child_nodes.compact.each do |child|
        found = find_call_node(child)
        return found if found
      end
      nil
    end

    it "returns VERIFIED for static symbol arguments" do
      node = parse_call("validates :email, presence: true")
      expect(described_class.for_node(node)).to eq("[VERIFIED]")
    end

    it "returns VERIFIED for no arguments" do
      node = parse_call("has_secure_password")
      expect(described_class.for_node(node)).to eq("[VERIFIED]")
    end

    it "returns INFERRED for lambda arguments" do
      node = parse_call("normalizes :email, with: ->(e) { e.strip }")
      expect(described_class.for_node(node)).to eq("[INFERRED]")
    end

    it "returns INFERRED for method call arguments" do
      node = parse_call("generates_token_for :reset, expires_in: 2.hours")
      expect(described_class.for_node(node)).to eq("[INFERRED]")
    end
  end

  describe ".static_node?" do
    def parse_expr(source)
      Prism.parse(source).value.statements.body.first
    end

    it "accepts symbol literals" do
      expect(described_class.static_node?(parse_expr(":foo"))).to be true
    end

    it "accepts string literals" do
      expect(described_class.static_node?(parse_expr('"hello"'))).to be true
    end

    it "accepts integers" do
      expect(described_class.static_node?(parse_expr("42"))).to be true
    end

    it "accepts true/false/nil" do
      expect(described_class.static_node?(parse_expr("true"))).to be true
      expect(described_class.static_node?(parse_expr("false"))).to be true
      expect(described_class.static_node?(parse_expr("nil"))).to be true
    end

    it "accepts constant reads" do
      expect(described_class.static_node?(parse_expr("Foo"))).to be true
    end

    it "accepts constant paths" do
      expect(described_class.static_node?(parse_expr("Foo::Bar"))).to be true
    end

    it "accepts static arrays" do
      expect(described_class.static_node?(parse_expr("[:a, :b, :c]"))).to be true
    end

    it "rejects arrays with dynamic elements" do
      expect(described_class.static_node?(parse_expr("[compute()]"))).to be false
    end

    it "accepts static hashes" do
      expect(described_class.static_node?(parse_expr("{ a: 1, b: 2 }"))).to be true
    end

    it "rejects hashes with dynamic keys" do
      expect(described_class.static_node?(parse_expr("{ compute() => :val }"))).to be false
    end

    it "rejects hashes with dynamic values" do
      expect(described_class.static_node?(parse_expr("{ key: compute() }"))).to be false
    end

    it "rejects method calls" do
      expect(described_class.static_node?(parse_expr("foo()"))).to be false
    end

    it "rejects lambda expressions" do
      expect(described_class.static_node?(parse_expr("-> { x }"))).to be false
    end
  end
end
