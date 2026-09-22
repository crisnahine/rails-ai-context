# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "stringio"
require "fileutils"

RSpec.describe RailsAiContext::LegacyCleanup do
  describe ".prompt_legacy_files" do
    let(:io) { StringIO.new }

    # Path constants for test readability
    UI_CLAUDE  = ".claude/rules/rails-ui-patterns.md"
    UI_CURSOR  = ".cursor/rules/rails-ui-patterns.mdc"
    UI_COPILOT = ".github/instructions/rails-ui-patterns.instructions.md"
    A11Y       = ".claude/rules/rails-accessibility.md"

    def create(root, *rel_paths)
      rel_paths.each do |rel|
        full = File.join(root, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, "# stale")
      end
    end

    it "no-ops silently when no legacy files exist" do
      Dir.mktmpdir do |dir|
        described_class.prompt_legacy_files(nil, root: dir, io: io)
        expect(io.string).to be_empty
      end
    end

    it "lists all four files when ai_tools is nil and all exist" do
      Dir.mktmpdir do |dir|
        create(dir, UI_CLAUDE, UI_CURSOR, UI_COPILOT, A11Y)
        described_class.prompt_legacy_files(nil, root: dir, io: io, warn_only: true)
        expect(io.string).to include(UI_CLAUDE)
        expect(io.string).to include(UI_CURSOR)
        expect(io.string).to include(UI_COPILOT)
        expect(io.string).to include(A11Y)
      end
    end

    it "filters to only ai_tools the user selected" do
      Dir.mktmpdir do |dir|
        create(dir, UI_CLAUDE, UI_CURSOR, UI_COPILOT, A11Y)
        described_class.prompt_legacy_files([ :claude ], root: dir, io: io, warn_only: true)
        expect(io.string).to include(UI_CLAUDE)
        expect(io.string).to include(A11Y)  # accessibility is claude-only
        expect(io.string).not_to include(UI_CURSOR)
        expect(io.string).not_to include(UI_COPILOT)
      end
    end

    it "includes accessibility file under claude filter" do
      Dir.mktmpdir do |dir|
        create(dir, A11Y)
        described_class.prompt_legacy_files([ :claude ], root: dir, io: io, warn_only: true)
        expect(io.string).to include(A11Y)
      end
    end

    it "excludes accessibility file when claude not selected" do
      Dir.mktmpdir do |dir|
        create(dir, A11Y)
        described_class.prompt_legacy_files([ :cursor, :copilot ], root: dir, io: io, warn_only: true)
        expect(io.string).to be_empty
      end
    end

    it "accepts string tool names and normalizes to symbols" do
      Dir.mktmpdir do |dir|
        create(dir, UI_CURSOR)
        described_class.prompt_legacy_files([ "cursor" ], root: dir, io: io, warn_only: true)
        expect(io.string).to include(UI_CURSOR)
      end
    end

    it "ignores unknown ai_tools entries" do
      Dir.mktmpdir do |dir|
        create(dir, UI_CLAUDE)
        described_class.prompt_legacy_files([ :unknown, :claude ], root: dir, io: io, warn_only: true)
        expect(io.string).to include(UI_CLAUDE)
      end
    end

    it "prints manual-delete instructions when warn_only is true (no prompt)" do
      Dir.mktmpdir do |dir|
        create(dir, UI_CLAUDE)
        described_class.prompt_legacy_files(nil, root: dir, io: io, warn_only: true)
        expect(io.string).to include("Delete manually when ready:")
        expect(io.string).to include("rm -f #{UI_CLAUDE}")
        expect(File.exist?(File.join(dir, UI_CLAUDE))).to be true
      end
    end

    it "prints manual-delete instructions when stdin is not a TTY" do
      allow($stdin).to receive(:tty?).and_return(false)
      Dir.mktmpdir do |dir|
        create(dir, UI_CLAUDE)
        described_class.prompt_legacy_files(nil, root: dir, io: io)
        expect(io.string).to include("Delete manually when ready:")
        expect(File.exist?(File.join(dir, UI_CLAUDE))).to be true
      end
    end

    it "deletes files when TTY user answers y" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow($stdin).to receive(:gets).and_return("y\n")
      Dir.mktmpdir do |dir|
        create(dir, UI_CLAUDE, UI_CURSOR, A11Y)
        described_class.prompt_legacy_files(nil, root: dir, io: io)
        expect(io.string).to include("Removed #{UI_CLAUDE}")
        expect(io.string).to include("Removed #{UI_CURSOR}")
        expect(io.string).to include("Removed #{A11Y}")
        expect(File.exist?(File.join(dir, UI_CLAUDE))).to be false
        expect(File.exist?(File.join(dir, UI_CURSOR))).to be false
        expect(File.exist?(File.join(dir, A11Y))).to be false
      end
    end

    it "says a file could not be removed rather than claiming it went" do
      skip "root can remove anything" if Process.uid.zero?

      allow($stdin).to receive(:tty?).and_return(true)
      allow($stdin).to receive(:gets).and_return("y\n")
      Dir.mktmpdir do |dir|
        create(dir, UI_CLAUDE)
        parent = File.dirname(File.join(dir, UI_CLAUDE))
        File.chmod(0o500, parent)

        described_class.prompt_legacy_files(nil, root: dir, io: io)

        expect(io.string).to include("Could not remove #{UI_CLAUDE}")
        expect(io.string).not_to include("  Removed #{UI_CLAUDE}")
      ensure
        File.chmod(0o700, parent)
      end
    end

    it "deletes files when TTY user answers yes" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow($stdin).to receive(:gets).and_return("yes\n")
      Dir.mktmpdir do |dir|
        create(dir, UI_CURSOR)
        described_class.prompt_legacy_files(nil, root: dir, io: io)
        expect(File.exist?(File.join(dir, UI_CURSOR))).to be false
      end
    end

    it "keeps files when TTY user answers n" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow($stdin).to receive(:gets).and_return("n\n")
      Dir.mktmpdir do |dir|
        create(dir, UI_CLAUDE)
        described_class.prompt_legacy_files(nil, root: dir, io: io)
        expect(io.string).to include("Kept.")
        expect(File.exist?(File.join(dir, UI_CLAUDE))).to be true
      end
    end

    it "keeps files on empty input (default N)" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow($stdin).to receive(:gets).and_return("\n")
      Dir.mktmpdir do |dir|
        create(dir, UI_CLAUDE)
        described_class.prompt_legacy_files(nil, root: dir, io: io)
        expect(File.exist?(File.join(dir, UI_CLAUDE))).to be true
      end
    end

    it "keeps files when gets returns nil (stdin closed)" do
      allow($stdin).to receive(:tty?).and_return(true)
      allow($stdin).to receive(:gets).and_return(nil)
      Dir.mktmpdir do |dir|
        create(dir, UI_CLAUDE)
        described_class.prompt_legacy_files(nil, root: dir, io: io)
        expect(File.exist?(File.join(dir, UI_CLAUDE))).to be true
      end
    end

    it "accepts a Pathname root" do
      Dir.mktmpdir do |dir|
        create(dir, UI_CLAUDE)
        described_class.prompt_legacy_files(nil, root: Pathname.new(dir), io: io, warn_only: true)
        expect(io.string).to include(UI_CLAUDE)
      end
    end
  end
end
