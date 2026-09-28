# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Brackets do
  describe ".span" do
    it "returns the bracket at the index through its match, nested ones included" do
      text = %(x = { a: { b: 1 }, c: [2] } tail)

      expect(described_class.span(text, text.index("{"))).to eq(%({ a: { b: 1 }, c: [2] }))
    end

    it "skips a bracket inside a string, escaped quotes and all" do
      text = %{render("a)b", 'c(', "say \\"(\\"") rest}

      expect(described_class.span(text, text.index("("))).to eq(%{("a)b", 'c(', "say \\"(\\"")})
    end

    it "skips a brace inside a JavaScript template literal" do
      text = %(alias: { "~x": `${root}/}` } end)

      expect(described_class.span(text, text.index("{"))).to eq(%({ "~x": `${root}/}` }))
    end

    it "skips a JavaScript comment, an apostrophe in it included" do
      text = %(static values = {\n  a: String,\n  // the planner's range\n  /* it's } here */\n  b: String,\n} after)

      expect(described_class.span(text, text.index("{"), comments: :js)).to end_with("b: String,\n}")
    end

    it "skips a Ruby comment" do
      text = %{render(partial: "row", # the row's partial )\n  locals: {}) after}

      expect(described_class.span(text, text.index("("), comments: :ruby)).to end_with("locals: {})")
    end

    it "skips a JavaScript regex literal, a bracket or a quote in it included" do
      expect(described_class.span("{ re: /[{]/, b: 1 } x", 0, comments: :js)).to eq("{ re: /[{]/, b: 1 }")
      expect(described_class.span("{ re: /'/g, b: 1 } x", 0, comments: :js)).to eq("{ re: /'/g, b: 1 }")
      expect(described_class.span("{ half: a / 2, b: c / 3 } x", 0, comments: :js)).to eq("{ half: a / 2, b: c / 3 }")
    end

    it "skips a Ruby character literal and a percent literal" do
      expect(described_class.span("(?), b) x", 0, comments: :ruby)).to eq("(?), b)")
      expect(described_class.span("(%w[a )], b) x", 0, comments: :ruby)).to eq("(%w[a )], b)")
      expect(described_class.span("(x ? y : z, a % b) x", 0, comments: :ruby)).to eq("(x ? y : z, a % b)")
    end

    it "skips a Ruby regex literal, slash or %r, a bracket or a quote in it included" do
      expect(described_class.span("(a =~ /[)]/, b) x", 0, comments: :ruby)).to eq("(a =~ /[)]/, b)")
      expect(described_class.span("(x.match?(/'/), y) z", 0, comments: :ruby)).to eq("(x.match?(/'/), y)")
      expect(described_class.span("(%r{a)}, b) x", 0, comments: :ruby)).to eq("(%r{a)}, b)")
    end

    it "is nil when the bracket never closes, or the index is not a bracket" do
      expect(described_class.span("( a ( b )", 0)).to be_nil
      expect(described_class.span("abc", 0)).to be_nil
    end
  end

  describe ".each_top_level" do
    it "yields whole bracket groups and strings, and every other character alone" do
      pieces = []
      described_class.each_top_level('a("x,y"), "s(", b') { |piece, kind| pieces << [ piece, kind ] }

      expect(pieces).to eq([ [ "a", :char ], [ '("x,y")', :group ], [ ",", :char ], [ " ", :char ],
                             [ '"s("', :string ], [ ",", :char ], [ " ", :char ], [ "b", :char ] ])
    end
  end
end
