# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Install::Cleanup do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  attr_reader :root

  MARKED = "<!-- BEGIN rails-ai-context -->\ngenerated\n<!-- END rails-ai-context -->\n"

  # A root context file as the gem writes it: nothing but the managed block.
  def touch(relative, content = MARKED)
    full = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(full))
    File.binwrite(full, content)
    full
  end

  def mkdir(relative)
    FileUtils.mkdir_p(File.join(root, relative)).first
  end

  describe ".remove" do
    it "removes a dropped tool's context files" do
      touch("CLAUDE.md")
      touch(".claude/rules/rails-schema.md", "x")

      described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.exist?(File.join(root, "CLAUDE.md"))).to be(false)
      expect(File.exist?(File.join(root, ".claude/rules"))).to be(false)
    end

    # The rules directory is shared with files the user writes by hand. Only
    # the names this gem generates are its to remove.
    it "leaves a hand-written rule file, and the directory that holds it" do
      touch(".claude/rules/rails-schema.md", "x")
      touch(".claude/rules/rails-accessibility.md", "x")
      mine = touch(".claude/rules/team-conventions.md", "mine")

      result = described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.read(mine)).to eq("mine")
      expect(File.exist?(File.join(root, ".claude/rules/rails-schema.md"))).to be(false)
      expect(File.exist?(File.join(root, ".claude/rules/rails-accessibility.md"))).to be(false)
      expect(result[:removed]).to include(".claude/rules/rails-schema.md")
      expect(result[:removed]).not_to include(".claude/rules/")
    end

    it "takes only its own block out of a file the user also wrote in" do
      path = touch("CLAUDE.md", "# Mine\n\n#{MARKED}\nMore of mine\n")

      result = described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.read(path)).to eq("# Mine\n\n\nMore of mine\n")
      expect(result[:trimmed]).to eq([ "CLAUDE.md" ])
      expect(result[:removed]).to be_empty
    end

    it "leaves a file this gem never wrote" do
      path = touch("CLAUDE.md", "# My own instructions\n")

      result = described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.read(path)).to eq("# My own instructions\n")
      expect(result).to eq(removed: [], trimmed: [], kept: [ "CLAUDE.md" ], failed: [])
    end

    # A blank line under a block in the middle of a file is the user's own:
    # the writer only adds one when it prepends.
    it "keeps the blank line between two of the user's paragraphs" do
      path = touch("CLAUDE.md", "Above.\n#{MARKED}\nBelow.\n")

      described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.read(path)).to eq("Above.\n\nBelow.\n")
    end

    it "keeps CRLF line endings around the block it takes out" do
      path = touch("CLAUDE.md", "# Mine\r\n#{MARKED.gsub("\n", "\r\n")}More\r\n".b)

      described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.binread(path)).to eq("# Mine\r\nMore\r\n".b)
    end

    it "leaves a rule file that is a symlink" do
      target = touch("shared/schema.md", "x")
      FileUtils.mkdir_p(File.join(root, ".claude/rules"))
      File.symlink(target, File.join(root, ".claude/rules/rails-schema.md"))

      described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.symlink?(File.join(root, ".claude/rules/rails-schema.md"))).to be(true)
      expect(File.exist?(target)).to be(true)
    end

    it "removes a split rules file it generated whole" do
      touch("AGENTS.md")
      split = touch("app/models/AGENTS.md", "# Models\n\n> #{described_class::GENERATED_NOTE}\n")

      described_class.remove(tools: [ :opencode ], keeping: [], root: root)

      expect(File.exist?(split)).to be(false)
    end

    it "leaves a split rules file the user wrote" do
      touch("AGENTS.md")
      split = touch("app/models/AGENTS.md", "# Our model rules\n")

      described_class.remove(tools: [ :opencode ], keeping: [], root: root)

      expect(File.read(split)).to eq("# Our model rules\n")
    end

    it "leaves a file that only quotes the generated note" do
      path = touch("CLAUDE.md", "The split files say #{described_class::GENERATED_NOTE} Leave them.\n")

      described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.exist?(path)).to be(true)
    end

    it "takes out every block when a file holds more than one" do
      path = touch("CLAUDE.md", "#{MARKED}\n#{MARKED}")

      described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.exist?(path)).to be(false)
    end

    it "leaves no blank line where a block the writer prepended used to be" do
      path = touch("CLAUDE.md", "#{MARKED}\n# mine\n")

      described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.read(path)).to eq("# mine\n")
    end

    it "keeps the user's bytes when they are not valid UTF-8" do
      path = touch("CLAUDE.md", "caf\xE9\n#{MARKED}".b)

      result = described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.binread(path)).to eq("caf\xE9\n".b)
      expect(result[:trimmed]).to eq([ "CLAUDE.md" ])
    end

    # Writing through the link would edit a file a kept tool still owns.
    it "leaves a root file that is a symlink, and the file it points at" do
      target = touch("AGENTS.md", "mine\n#{MARKED}")
      File.symlink(target, File.join(root, "CLAUDE.md"))

      result = described_class.remove(tools: [ :claude ], keeping: [ :codex ], root: root)

      expect(File.read(target)).to eq("mine\n#{MARKED}")
      expect(result).to eq(removed: [], trimmed: [], kept: [ "CLAUDE.md" ], failed: [])
    end

    it "leaves a rules directory that is a symlink" do
      real = File.dirname(touch("shared/rails-schema.md", "x"))
      FileUtils.mkdir_p(File.join(root, ".claude"))
      File.symlink(real, File.join(root, ".claude/rules"))

      described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.exist?(File.join(real, "rails-schema.md"))).to be(true)
    end

    it "removes what the real writers produce" do
      path = File.join(root, "CLAUDE.md")
      RailsAiContext::Serializers::SectionMarkerWriter.write_with_markers(path, "generated")

      described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(File.exist?(path)).to be(false)
    end

    it "names every rule file the serializers write" do
      {
        claude: RailsAiContext::Serializers::ClaudeRulesSerializer,
        cursor: RailsAiContext::Serializers::CursorRulesSerializer,
        copilot: RailsAiContext::Serializers::CopilotInstructionsSerializer
      }.each do |key, serializer|
        expect(RailsAiContext::Install::AiTool.find(key).rule_files).to match_array(serializer::RULE_FILES.keys)
      end
    end

    it "reports what it removed, so the caller can say so in its own voice" do
      touch("CLAUDE.md")

      removed = described_class.remove(tools: [ :claude ], keeping: [], root: root)

      expect(removed[:removed]).to include("CLAUDE.md")
    end

    it "marks a removed directory so the caller can print the trailing slash" do
      touch(".claude/rules/rails-schema.md", "x")

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
        .to eq(removed: [], trimmed: [], kept: [], failed: [])
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
      it "reports a rule file it could not remove as failed, not removed" do
        touch(".claude/rules/rails-schema.md", "x")
        File.chmod(0o500, File.join(root, ".claude/rules"))

        result = described_class.remove(tools: [ :claude ], keeping: [], root: root)

        expect(result[:failed]).to include(".claude/rules/rails-schema.md")
        expect(result[:removed]).to be_empty
        expect(File.exist?(File.join(root, ".claude/rules/rails-schema.md"))).to be(true)
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
