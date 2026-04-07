# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe RailsAiContext::AstCache do
  before { described_class.clear }
  after  { described_class.clear }

  let(:source) { "class Foo; end" }
  let(:tmpfile) do
    f = Tempfile.new([ "test_model", ".rb" ])
    f.write(source)
    f.flush
    f
  end
  after { tmpfile.close! }

  describe ".parse" do
    it "returns a Prism::ParseResult" do
      result = described_class.parse(tmpfile.path)
      expect(result).to be_a(Prism::ParseResult)
    end

    it "caches repeated parses of the same file" do
      result1 = described_class.parse(tmpfile.path)
      result2 = described_class.parse(tmpfile.path)
      expect(result1).to equal(result2)
    end

    it "invalidates when content changes" do
      result1 = described_class.parse(tmpfile.path)
      tmpfile.rewind
      tmpfile.write("class Bar; end")
      tmpfile.flush
      result2 = described_class.parse(tmpfile.path)
      expect(result2).not_to equal(result1)
    end
  end

  describe ".parse_string" do
    it "parses source without caching" do
      result = described_class.parse_string("x = 1")
      expect(result).to be_a(Prism::ParseResult)
    end
  end

  describe ".invalidate" do
    it "removes cached entries for a path" do
      described_class.parse(tmpfile.path)
      expect(described_class.size).to be >= 1
      described_class.invalidate(tmpfile.path)
      expect(described_class.size).to eq(0)
    end
  end

  describe ".clear" do
    it "empties the entire cache" do
      described_class.parse(tmpfile.path)
      described_class.clear
      expect(described_class.size).to eq(0)
    end
  end

  describe "size guard" do
    it "raises ArgumentError for files exceeding MAX_PARSE_SIZE" do
      large = Tempfile.new([ "large_model", ".rb" ])
      large.write("x" * (described_class::MAX_PARSE_SIZE + 1))
      large.flush

      expect { described_class.parse(large.path) }.to raise_error(
        ArgumentError, /File too large for AST parsing/
      )
    ensure
      large.close!
    end
  end
end
