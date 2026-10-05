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

  describe ".parse_string" do
    before { described_class.clear }

    it "parses a source string once and serves the rest from the cache" do
      source = "class CachedProbe\n  def index; end\nend\n"

      expect(Prism).to receive(:parse).once.and_call_original
      first = described_class.parse_string(source)
      second = described_class.parse_string(source)

      expect(second).to equal(first)
      expect(described_class.size).to eq(1)
    end

    it "keeps distinct sources distinct" do
      a = described_class.parse_string("class A; end\n")
      b = described_class.parse_string("class B; end\n")

      expect(a).not_to equal(b)
      expect(described_class.size).to eq(2)
    end

    it "bypasses the cache for oversize sources instead of raising" do
      stub_const("RailsAiContext::AstCache::MAX_PARSE_SIZE", 10)

      result = described_class.parse_string("class TooBigForTheCache; end\n")
      expect(result).to be_a(Prism::ParseResult)
      expect(described_class.size).to eq(0)
    end
  end

  # Canvas's config/initializers/active_record.rb reaches every model's
  # concern walk: 1,996 reads and SHA256s of one unchanged file in a run.
  describe "an unchanged file" do
    it "is neither read nor hashed again" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "big.rb")
        File.write(path, "class Big\nend\n")
        # Old enough that no rewrite can share its mtime tick.
        File.utime(Time.now - 60, Time.now - 60, path)
        described_class.clear
        first = described_class.parse(path)
        allow(File).to receive(:read).and_call_original
        allow(Digest::SHA256).to receive(:hexdigest).and_call_original

        3.times { expect(described_class.parse(path)).to equal(first) }

        expect(File).not_to have_received(:read).with(path)
        expect(Digest::SHA256).not_to have_received(:hexdigest)
      end
    end

    it "is read again once it changes" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "big.rb")
        File.write(path, "class Big\nend\n")
        described_class.clear
        described_class.parse(path)
        File.write(path, "class Bigger\n  def x; end\nend\n")

        expect(described_class.parse(path).value.slice).to include("Bigger")
      end
    end

    it "forgets a file's stat when its parse is evicted" do
      stub_const("#{described_class}::MAX_SIZE", 4)
      Dir.mktmpdir do |dir|
        described_class.clear
        12.times do |i|
          path = File.join(dir, "f#{i}.rb")
          File.write(path, "class F#{i}; end\n")
          described_class.parse(path)
        end

        expect(described_class::SEEN.size).to be <= described_class::MAX_SIZE
        expect(described_class::SEEN.values.map { |entry| entry[1] }).to all(satisfy { |key| described_class::STORE.key?(key) })
      end
    end

    # Linux stamps mtime from a coarse clock, so a same-size rewrite right after
    # a parse can leave mtime, size and inode all as they were. The tie is
    # forced here, so the answer does not depend on the filesystem's clock.
    it "is read again after a same-size rewrite that keeps its stat" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "tie.rb")
        File.write(path, "class Aaaa\nend\n")
        stamp = File.mtime(path)
        inode = File.stat(path).ino
        described_class.clear
        described_class.parse(path)

        File.write(path, "class Bbbb\nend\n")
        File.utime(stamp, stamp, path)
        expect([ File.mtime(path), File.stat(path).ino ]).to eq([ stamp, inode ])

        expect(described_class.parse(path).value.slice).to include("Bbbb")
      end
    end
  end

  describe "parsing as a given Ruby" do
    let(:source) { "cells[0, strict: true] = v\n" }

    it "parses with that Ruby's grammar, the oldest prism knows for an older one, and the newest when unknown" do
      expect(described_class.parse_string(source, ruby: "3.3.9").success?).to be true
      expect(described_class.parse_string(source, ruby: "3.1.6").success?).to be true
      expect(described_class.parse_string(source, ruby: "3.4.1").success?).to be false
      expect(described_class.parse_string(source, ruby: "99.0.0").success?).to be false
      expect(described_class.parse_string(source).success?).to be false
    end

    it "reads a malformed version as no version" do
      [ nil, "", "jruby-9.4", "\xFF", "3" ].each do |ruby|
        expect(described_class.prism_version(ruby)).to be_nil
      end
    end

    it "keeps one parse per grammar for a file" do
      path = File.join(Dir.mktmpdir, "grid.rb")
      File.write(path, source)

      expect(described_class.parse(path, ruby: "3.3.0").success?).to be true
      expect(described_class.parse(path).success?).to be false
      expect(described_class.parse(path, ruby: "3.3.0").success?).to be true
    end
  end
end
