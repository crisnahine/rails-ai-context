# frozen_string_literal: true

require "spec_helper"

# The Ruby a HAML or Slim view runs, as haml and slim compile it: every name
# below is one the compiled template reads, and none is one it does not.
RSpec.describe RailsAiContext::MarkupSource do
  describe ".pieces" do
    it "reads nothing from a template that is not HAML or Slim" do
      expect(described_class.pieces("<%= a %>", "a.html.erb")).to be_nil
    end

    it "reads a HAML view's scripts, attributes, object refs, interpolations and filters, and skips its comments" do
      source = "%p= @a\n%a{href: b, title: c} Hi \#{d}\n%a(href=e title=\"x \#{f}\")\n%div[g]\n-# @gone\n  @gone_too\n:ruby\n  h = 1\n"

      expect(described_class.pieces(source, "a.html.haml"))
        .to eq([ [ "@a", true ], [ "{href: b, title: c}", true ], [ "d", true ], [ "e", true ], [ "f", true ], [ "g", true ], [ "  h = 1", true ] ])
    end

    it "reads a Slim view's code, attributes and interpolations, and skips its comments" do
      source = "p = @a\na href=b title=\"x \#{c}\" Hi \#{d}\n/ @gone\n  @gone_too\n- e.each do\nruby:\n  f = 1\n"

      expect(described_class.pieces(source, "a.html.slim"))
        .to eq([ [ "@a", true ], [ "b", true ], [ "c", true ], [ "d", true ], [ "e.each do", true ], [ "\n  f = 1", true ] ])
    end

    # A shape the reader does not know costs a false hit, never a lost one.
    it "keeps a line it cannot parse whole, marked as not Ruby" do
      expect(described_class.pieces("%a{href: @unclosed\n", "a.html.haml")).to eq([ [ "%a{href: @unclosed", false ] ])
      expect(described_class.pieces("&nbsp; @kept\n", "a.html.slim")).to eq([ [ "&nbsp; @kept", false ] ])
    end
  end

  # A data URI or inline SVG in one attribute, and a hash left open to the end of a long file.
  describe "long input" do
    it "reads a 200 KB and a 400 KB Slim attribute in a fraction of a second", :cpu_timed do
      [ 200_000, 400_000 ].each do |size|
        value = "data:image/svg+xml;base64,#{'Q' * size}"
        pieces = nil
        expect(cpu_seconds { pieces = described_class.pieces(%(img src=#{value} alt="\#{@alt}"\n), "a.html.slim") }).to be < 1
        expect(pieces).to eq([ [ value, true ], [ "@alt", true ] ])
        expect(cpu_seconds { pieces = described_class.pieces(%(img src="#{value}" alt=@alt\n), "a.html.slim") }).to be < 1
        expect(pieces).to eq([ [ "@alt", true ] ])
      end
    end

    it "reads 100,000 characters of non-ASCII text and quoted attributes with interpolations in a fraction of a second", :cpu_timed do
      unit = "日本\#{@a}語"
      text = unit * 10_000
      {
        "%p #{text}\n" => "a.html.haml",
        %(%a(title="#{text}")\n) => "a.html.haml",
        "p #{text}\n" => "a.html.slim",
        %(a title="#{text}" href=@b\n) => "a.html.slim"
      }.each do |source, path|
        pieces = nil
        expect(cpu_seconds { pieces = described_class.pieces(source, path) }).to be < 1
        expect(pieces.map(&:first).tally).to eq({ "@a" => 10_000, "@b" => (1 if source.include?("@b")) }.compact)
      end
    end

    it "reads a Slim line of 50,000 attributes in a fraction of a second", :cpu_timed do
      pieces = nil
      expect(cpu_seconds { pieces = described_class.pieces("a#{' data-x="v" y=@b' * 50_000}\n", "a.html.slim") }).to be < 1
      expect(pieces.length).to eq(50_000)
    end

    it "keeps a HAML hash left open for 2000 lines whole, in a fraction of a second", :cpu_timed do
      source = "%a{href: x,\n#{"  b: c,\n" * 2000}"
      pieces = nil
      expect(cpu_seconds { pieces = described_class.pieces(source, "a.html.haml") }).to be < 1
      expect(pieces).to eq([ [ source.chomp, false ] ])
    end
  end

  describe ".interpolations" do
    it "reads `\#{}` with its braces balanced and skips an escaped one" do
      expect(described_class.interpolations("a \#{b {c}} \\\#{d} \#@e")).to eq([ "b {c}" ])
    end

    it "reads `\#@ivar` and `\#$global` when asked for sigils" do
      expect(described_class.interpolations("a \#@e \#$f \#{g}", sigils: true)).to eq(%w[@e $f g])
    end
  end
end
