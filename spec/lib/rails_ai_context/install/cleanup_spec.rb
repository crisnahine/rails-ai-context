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

      expect(removed).to include("CLAUDE.md")
    end

    it "marks a removed directory so the caller can print the trailing slash" do
      mkdir(".claude/rules")

      expect(described_class.remove(tools: [ :claude ], keeping: [], root: root))
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
      expect(described_class.remove(tools: [ :claude ], keeping: [], root: root)).to be_empty
    end

    it "leaves files belonging to a tool it was not asked about" do
      touch("CLAUDE.md")
      touch(".cursorrules")

      described_class.remove(tools: [ :cursor ], keeping: [], root: root)

      expect(File.exist?(File.join(root, "CLAUDE.md"))).to be(true)
      expect(File.exist?(File.join(root, ".cursorrules"))).to be(false)
    end

    it "ignores a name that is not an AI tool" do
      expect { described_class.remove(tools: [ :emacs ], keeping: [], root: root) }.not_to raise_error
    end
  end
end
