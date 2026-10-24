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
        described_class.atomic_write(path, bytes, root: dir)
        expect(File.binread(path)).to eq(bytes)

        allow(File).to receive(:rename).and_raise(Errno::EACCES)
        expect { described_class.atomic_write(path, "new", root: dir) }.to raise_error(Errno::EACCES)
        expect(Dir.children(dir)).to eq([ "doc.md" ])
      end
    end

    it "takes no write that names no root to keep it inside" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "doc.md")

        expect { described_class.atomic_write(path, "new") }.to raise_error(ArgumentError, /root/)
        expect(Dir.children(dir)).to be_empty
      end
    end

    it "writes through a link inside the root to the file it names" do
      Dir.mktmpdir do |dir|
        real = File.join(dir, "AGENTS.md")
        link = File.join(dir, "CLAUDE.md")
        File.write(real, "# Team notes\n")
        File.symlink("AGENTS.md", link)

        described_class.atomic_write(link, "new\n", root: dir)

        expect(File.symlink?(link)).to be(true)
        expect(File.read(real)).to eq("new\n")
      end
    end

    it "refuses a link that leads out of the root and leaves both files as they were" do
      Dir.mktmpdir do |outside|
        Dir.mktmpdir do |dir|
          real = File.join(outside, "shared.json")
          link = File.join(dir, ".mcp.json")
          File.write(real, "{}\n")
          File.symlink(real, link)

          expect { described_class.atomic_write(link, "new\n", root: dir) }.to raise_error(described_class::LinkedOut)
          expect(File.symlink?(link)).to be(true)
          expect(File.read(real)).to eq("{}\n")
          expect(Dir.children(dir)).to eq([ ".mcp.json" ])
        end
      end
    end

    it "says what stopped it when the link or the root cannot be followed" do
      skip "Windows keeps no POSIX mode to lock a directory with" if Gem.win_platform?

      Dir.mktmpdir do |dir|
        locked = File.join(dir, "locked")
        Dir.mkdir(locked)
        File.write(File.join(locked, "AGENTS.md"), "mine\n")
        link = File.join(dir, "CLAUDE.md")
        File.symlink("locked/AGENTS.md", link)

        expect { described_class.atomic_write(link, "new\n", root: File.join(dir, "gone")) }
          .to raise_error(described_class::LinkedOut, "Left #{link} as it is - #{described_class::LINKED} (it leads out of the app)")

        dangling = File.join(dir, "AGENTS.md")
        File.symlink("missing.md", dangling)
        expect { described_class.atomic_write(dangling, "new\n", root: dir) }
          .to raise_error(described_class::LinkedOut, "Left #{dangling} as it is - #{described_class::LINKED} (it leads nowhere)")

        make_unreadable(locked)
        expect { described_class.atomic_write(link, "new\n", root: dir) }
          .to raise_error(described_class::LinkedOut, /\ALeft #{Regexp.escape(link)} as it is - #{described_class::LINKED} \(Permission denied/)
      ensure
        File.chmod(0o755, locked)
      end
    end

    it "refuses a write into a directory a link carries out of the root" do
      Dir.mktmpdir do |outside|
        Dir.mktmpdir do |dir|
          File.symlink(outside, File.join(dir, ".claude"))

          expect { described_class.atomic_write(File.join(dir, ".claude/rules/rails-models.md"), "new\n", root: dir) }
            .to raise_error(described_class::LinkedOut)
          expect(Dir.children(outside)).to be_empty
        end
      end
    end

    it "keeps the mode the file had" do
      skip "Windows keeps no POSIX mode to carry over" if Gem.win_platform?

      Dir.mktmpdir do |dir|
        path = File.join(dir, "notes.md")
        File.write(path, "x\n")
        File.chmod(0o444, path)

        described_class.atomic_write(path, "y\n", root: dir)

        expect(File.read(path)).to eq("y\n")
        expect(File.stat(path).mode & 0o777).to eq(0o444)
      end
    end
  end
end
