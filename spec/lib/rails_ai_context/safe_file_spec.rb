# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe RailsAiContext::SafeFile do
  describe ".read" do
    it "returns file contents for a normal file" do
      Tempfile.create("safe_file_test") do |f|
        f.write("hello world")
        f.flush
        expect(described_class.read(f.path)).to eq("hello world")
      end
    end

    it "returns nil when the file does not exist" do
      expect(described_class.read("/tmp/nonexistent_#{SecureRandom.hex}.txt")).to be_nil
    end

    it "returns nil when path is nil" do
      expect(described_class.read(nil)).to be_nil
    end

    it "returns nil when path is a directory" do
      expect(described_class.read(Dir.tmpdir)).to be_nil
    end

    it "returns nil when the file exceeds the default max size" do
      Tempfile.create("safe_file_large") do |f|
        f.write("x" * 100)
        f.flush
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(50)
        expect(described_class.read(f.path)).to be_nil
      end
    end

    it "returns nil when the file exceeds an explicit max_size" do
      Tempfile.create("safe_file_explicit") do |f|
        f.write("x" * 100)
        f.flush
        expect(described_class.read(f.path, max_size: 50)).to be_nil
      end
    end

    it "returns contents when file is within explicit max_size" do
      Tempfile.create("safe_file_within") do |f|
        f.write("small")
        f.flush
        expect(described_class.read(f.path, max_size: 1_000)).to eq("small")
      end
    end

    it "handles encoding issues without raising" do
      Tempfile.create("safe_file_binary") do |f|
        f.binmode
        f.write("\xFF\xFE binary content \x80\x81")
        f.flush
        result = described_class.read(f.path)
        expect(result).to be_a(String)
        expect(result.encoding).to eq(Encoding::UTF_8)
      end
    end

    it "returns nil when file access is denied" do
      allow(File).to receive(:size).and_raise(Errno::EACCES)
      expect(described_class.read("/some/protected/file")).to be_nil
    end
  end

  describe ".atomic_write" do
    it "writes binary content byte for byte and leaves no temp file when the rename fails" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "doc.md")
        bytes = (+"caf\u00e9").force_encoding(Encoding::BINARY)
        described_class.atomic_write(path, bytes)
        expect(File.binread(path)).to eq(bytes)

        allow(File).to receive(:rename).and_raise(Errno::EACCES)
        expect { described_class.atomic_write(path, "new") }.to raise_error(Errno::EACCES)
        expect(Dir.children(dir)).to eq([ "doc.md" ])
      end
    end
  end
end
