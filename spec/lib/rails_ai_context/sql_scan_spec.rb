# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::SqlScan do
  def scan(sql, family)
    described_class.new(sql, family: family)
  end

  describe "#split" do
    # [family, text, separator, the parts]
    [
      [ :postgresql, "a, 'x,y', b", ",", [ "a", "'x,y'", "b" ] ],
      [ :postgresql, "a, 'it''s, fine', b", ",", [ "a", "'it''s, fine'", "b" ] ],
      [ :postgresql, %q('a\', b), ",", [ %q('a\'), "b" ] ],
      [ :postgresql, %q(E'a\', b', c), ",", [ %q(E'a\', b'), "c" ] ],
      [ :postgresql, %q(me'a\', b), ",", [ %q(me'a\'), "b" ] ],
      [ :postgresql, "$$a;b$$; SELECT 1", ";", [ "$$a;b$$", "SELECT 1" ] ],
      [ :postgresql, "$tag$ ' ; $tag$; SELECT 2", ";", [ "$tag$ ' ; $tag$", "SELECT 2" ] ],
      [ :postgresql, "$é$a;b$é$; c", ";", [ "$é$a;b$é$", "c" ] ],
      [ :postgresql, "SELECT 1 AS →$a$; DELETE FROM users; SELECT 1 AS →$a$", ";", [ "SELECT 1 AS →$a$", "DELETE FROM users", "SELECT 1 AS →$a$" ] ],
      [ :postgresql, "SELECT $→$ ' $→$; DELETE FROM users; SELECT ' '", ";", [ "SELECT $→$ ' $→$", "DELETE FROM users", "SELECT ' '" ] ],
      [ :unknown, "$$a;b$$; SELECT 1", ";", [ "$$a;b$$", "SELECT 1" ] ],
      [ "sqlserver", "a /* x /* y; */ z; */; b", ";", [ "a /* x /* y; */ z; */", "b" ] ],
      [ :postgresql, %("we,ird", "a""b,c", d), ",", [ %("we,ird"), %("a""b,c"), "d" ] ],
      [ :postgresql, "f(a, b), (c, (d, e)), g", ",", [ "f(a, b)", "(c, (d, e))", "g" ] ],
      [ :postgresql, "x[1,2], y", ",", [ "x[1,2]", "y" ] ],
      [ :postgresql, "a -- x, y\n, b /* c, d */, e", ",", [ "a -- x, y", "b /* c, d */", "e" ] ],
      [ :postgresql, "a /* x /* y, */ z, */, b", ",", [ "a /* x /* y, */ z, */", "b" ] ],
      [ :postgresql, "a, b,", ",", [ "a", "b" ] ],
      [ :postgresql, "", ",", [] ],
      [ :postgresql, "f(a, b", ",", [ "f(a, b" ] ],
      [ :postgresql, "'a, b", ",", [ "'a, b" ] ],
      [ :mysql, %q('a\'b', c), ",", [ %q('a\'b'), "c" ] ],
      [ :mysql, %q('C:\\\\', d), ",", [ %q('C:\\\\'), "d" ] ],
      [ :mysql, %q("a\"b, c", d), ",", [ %q("a\"b, c"), "d" ] ],
      [ :mysql, "`x``y,z`, w", ",", [ "`x``y,z`", "w" ] ],
      [ :mysql, "a # b, c\n, d", ",", [ "a # b, c", "d" ] ],
      [ :mysql, "a --x, b", ",", [ "a --x", "b" ] ],
      [ :mysql, "$$a, b$$", ",", [ "$$a", "b$$" ] ],
      [ :mysql, "a /*!50100 b, c */, d", ",", [ "a /*!50100 b, c */", "d" ] ],
      [ :sqlite, "[a, b], c", ",", [ "[a, b]", "c" ] ],
      [ :sqlite, %q('a\', b), ",", [ %q('a\'), "b" ] ],
      [ :sqlite, "a # b, c", ",", [ "a # b", "c" ] ],
      [ :mysql, "x[1,2], y", ",", [ "x[1,2]", "y" ] ]
    ].each do |family, text, separator, parts|
      it "splits #{text.inspect} on #{separator.inspect} as #{family} reads it" do
        expect(scan(text, family).split(separator)).to eq(parts)
      end
    end
  end

  describe "#quoted_spans" do
    {
      [ :postgresql, %q(SELECT 'a', "b" -- c) ] => [ [ :string, 7, 10 ], [ :quoted, 12, 15 ], [ :comment, 16, 20 ] ],
      [ :postgresql, "SELECT $$x$$, [y]" ] => [ [ :string, 7, 12 ] ],
      [ :postgresql, "SELECT $$x" ] => [],
      [ :postgresql, "SELECT $→$a -- b$→$ AS v" ] => [ [ :string, 7, 23 ] ],
      [ :postgresql, "SELECT 'é', 1" ] => [ [ :string, 7, 11 ] ],
      [ :mysql, %q(SELECT 'a\'b' # c) ] => [ [ :string, 7, 13 ], [ :comment, 14, 17 ] ],
      [ :mysql, "SELECT `a`, $$b$$" ] => [ [ :quoted, 7, 10 ] ],
      [ :sqlite, "SELECT [a b], 'c'" ] => [ [ :quoted, 7, 12 ], [ :string, 14, 17 ] ]
    }.each do |(family, text), spans|
      it "reads the spans of #{text.inspect} as #{family} does" do
        expect(scan(text, family).quoted_spans).to eq(spans)
      end
    end
  end

  describe "#top_level? and #paren_group" do
    it "takes a byte outside every span and every parenthesis as top level, the parentheses themselves too" do
      text = "f(a) 'b' (c) d"
      found = text.bytesize.times.select { |i| scan(text, :postgresql).top_level?(i) }
      expect(found.map { |i| text.byteslice(i) }.join).to eq("f()  () d")
    end

    it "gives the byte index of the parenthesis that closes the one at an index, quotes and comments respected" do
      text = %q[x (a, (b), 'c)', "d)" /* ) */) y]
      expect(scan(text, :postgresql).paren_group(2)).to eq(text.bytesize - 3)
      expect(scan(text, :postgresql).paren_group(6)).to eq(8)
      expect(scan("(a", :postgresql).paren_group(0)).to be_nil
    end

    it "closes a group after a MySQL string with a backslash-escaped quote, which PostgreSQL reads as still open" do
      text = %q[(a DEFAULT 'it\'s') x]
      expect(scan(text, :mysql).paren_group(0)).to eq(18)
      expect(scan(text, :postgresql).paren_group(0)).to be_nil
    end

    it "counts by byte past a non-ASCII character" do
      text = "('é', (b)) c"
      expect(scan(text, :postgresql).paren_group(0)).to eq(text.bytesize - 3)
      expect(scan(text, :postgresql).paren_group(7)).to eq(9)
    end
  end

  describe "#masked" do
    it "blanks every string and comment byte for byte and keeps quoted names" do
      text = %(a = 'x;é' AND "n;m" -- z;\nb)
      masked = scan(text, :postgresql).masked
      expect(masked.bytesize).to eq(text.bytesize)
      expect(masked).to eq(%(a = #{' ' * 6} AND "n;m" #{' ' * 5}\nb))
    end

    it "blanks a dollar-quoted string on PostgreSQL" do
      expect(scan("a $$;$$ b", :postgresql).masked).to eq("a #{' ' * 5} b")
    end
  end

  describe ".unquote" do
    {
      [ :postgresql, "'it''s'" ] => "it's",
      [ :postgresql, %q('C:\temp') ] => %q(C:\temp),
      [ :mysql, %q('C:\\\\temp') ] => %q(C:\temp),
      [ :mysql, %q('the user\'s login') ] => "the user's login",
      [ :mysql, "'the user''s login'" ] => "the user's login",
      [ :mysql, %q('a\nb\tc\0\Z\%\_\q') ] => "a\nb\tc\0\x1A\\%\\_q",
      [ :sqlite, "'a''b'" ] => "a'b",
      [ :postgresql, "'a''" ] => nil,
      [ :postgresql, "'a' || 'b'" ] => nil,
      [ :mysql, %q('a\') ] => nil,
      [ :postgresql, "E'a'" ] => nil,
      [ :postgresql, "1" ] => nil
    }.each do |(family, literal), value|
      it "reads #{literal.inspect} as #{value.inspect} on #{family}" do
        expect(described_class.unquote(literal, family: family)).to eq(value)
      end
    end
  end

  # The dot of a name and the dots between names stay apart: a part holding a dot or a quote is quoted in the joined name.
  describe ".join_qualified, .qualified_parts and .split_qualified" do
    {
      %w[users] => "users",
      %w[public users] => "public.users",
      [ "x", "y.z" ] => 'x."y.z"',
      [ "x.y", "z" ] => '"x.y".z',
      [ "a\"b", "c" ] => '"a""b".c',
      [ "my table" ] => "my table"
    }.each do |parts, joined|
      it "joins #{parts.inspect} as #{joined} and reads it back" do
        expect(described_class.join_qualified(*parts)).to eq(joined)
        expect(described_class.qualified_parts(joined)).to eq(parts)
      end
    end

    it "splits a joined name into its schema and name, the schema nil for a bare one" do
      expect(described_class.split_qualified("users")).to eq([ nil, "users" ])
      expect(described_class.split_qualified('x."y.z"')).to eq([ "x", "y.z" ])
      expect(described_class.split_qualified('"x.y".z')).to eq([ "x.y", "z" ])
    end

    it "reads an unclosed quote and a long run of them in linear time" do
      expect { Timeout.timeout(2) { [ '"' * 64_000, '"a' * 32_000, "a." * 32_000 + '"' ].each { |text| described_class.split_qualified(text) } } }.not_to raise_error
    end
  end

  describe ".strip_array_suffix" do
    it "drops every trailing bracket pair, with a size or a blank, and says whether there was one" do
      expect(described_class.strip_array_suffix("integer")).to eq([ "integer", false ])
      expect(described_class.strip_array_suffix("integer[]")).to eq([ "integer", true ])
      expect(described_class.strip_array_suffix("integer [3] [] ")).to eq([ "integer", true ])
      expect(described_class.strip_array_suffix("character varying(10)[][]")).to eq([ "character varying(10)", true ])
      expect(described_class.strip_array_suffix("a[1]b[]")).to eq([ "a[1]b", true ])
      expect(described_class.strip_array_suffix("a[x]")).to eq([ "a[x]", false ])
      expect(described_class.strip_array_suffix("[]")).to eq([ "", true ])
    end
  end

  it "takes a family by the name DatabaseFamily reads, or the family itself" do
    expect(scan(%q('a\'b', c), "mysql2").split(",")).to eq([ %q('a\'b'), "c" ])
    expect(scan(%q('a\'b', c), RailsAiContext::DatabaseFamily::MYSQL).split(",")).to eq([ %q('a\'b'), "c" ])
  end
end
