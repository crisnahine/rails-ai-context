# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Install::Cleanup do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  attr_reader :root

  def touch(relative)
    full = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "x")
    full
  end

  def mkdir(relative)
    FileUtils.mkdir_p(File.join(root, relative)).first
  end

  describe ".remove" do
    it "removes a dropped tool's context files" do
      touch("CLAUDE.md")
      mkdir(".claude/rules")

      described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.exist?(File.join(root, "CLAUDE.md"))).to be(false)
      expect(File.exist?(File.join(root, ".claude/rules"))).to be(false)
    end

    it "reports what it removed, so the caller can say so in its own voice" do
      touch("CLAUDE.md")

      removed = described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(removed[:removed]).to include("CLAUDE.md")
    end

    it "marks a removed directory so the caller can print the trailing slash" do
      mkdir(".claude/rules")

      expect(described_class.remove(tools: [ :claude ], keeping: [], root: root)[:removed])
        .to include(".claude/rules/")
    end

    # AGENTS.md belongs to both opencode and codex. Dropping one must not take
    # the file the other still needs.
    it "keeps a path another selected tool still needs" do
      touch("AGENTS.md")

      described_class.remove(tools: [ :opencode ], keeping: [ :codex ], root: root)

      expect(File.exist?(File.join(root, "AGENTS.md"))).to be(true)
    end

    it "removes a shared path once no selected tool needs it" do
      touch("AGENTS.md")

      described_class.remove(tools: %i[opencode codex], keeping: [], root: root)

      expect(File.exist?(File.join(root, "AGENTS.md"))).to be(false)
    end

    it "says nothing about a file that was never there" do
      expect(described_class.remove(tools: [ :claude ], keeping: [], root: root))
        .to eq(removed: [], failed: [])
    end

    it "leaves files belonging to a tool it was not asked about" do
      touch("CLAUDE.md")
      touch(".cursorrules")

      described_class.remove(tools: [ :cursor ], keeping: [], root: root)

      expect(File.exist?(File.join(root, "CLAUDE.md"))).to be(true)
      expect(File.exist?(File.join(root, ".cursorrules"))).to be(false)
    end

    # rm_rf and rm_f both swallow a permission error, so the installer used to
    # print "Removed" over files that were still there.
    context "when the filesystem refuses the removal", skip: (Process.uid.zero? ? "root can remove anything" : false) do
      it "reports a directory it could not remove as failed, not removed" do
        mkdir(".claude/rules")
        File.write(File.join(root, ".claude/rules/a.md"), "x")
        File.chmod(0o500, File.join(root, ".claude/rules"))

        result = described_class.remove(tools: [ :claude ], keeping: [], root: root)

        expect(result[:failed]).to include(".claude/rules/")
        expect(result[:removed]).not_to include(".claude/rules/")
        expect(File.exist?(File.join(root, ".claude/rules/a.md"))).to be(true)
      ensure
        File.chmod(0o700, File.join(root, ".claude/rules"))
      end

      it "reports a file it could not remove as failed, not removed" do
        touch("CLAUDE.md")
        File.chmod(0o500, root)

        result = described_class.remove(tools: [ :claude ], keeping: [], root: root)

        expect(result[:failed]).to include("CLAUDE.md")
        expect(result[:removed]).not_to include("CLAUDE.md")
      ensure
        File.chmod(0o700, root)
      end
    end

    it "ignores a name that is not an AI tool" do
      expect { described_class.remove(tools: [ :emacs ], keeping: [], root: root) }.not_to raise_error
    end
  end
end
