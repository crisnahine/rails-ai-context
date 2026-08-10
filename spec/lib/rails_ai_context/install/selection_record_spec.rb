# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# No Rails boot anywhere here: the record is a file on disk, and reading it
# has to work from the standalone CLI where no app is loaded.
RSpec.describe RailsAiContext::Install::SelectionRecord do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  attr_reader :root

  def write_initializer(body)
    FileUtils.mkdir_p(File.join(root, "config", "initializers"))
    File.write(File.join(root, "config", "initializers", "rails_ai_context.rb"), body)
  end

  def write_yaml(body)
    File.write(File.join(root, ".rails-ai-context.yml"), body)
  end

  describe ".read" do
    it "is nil when nothing has been recorded" do
      expect(described_class.read(root: root)).to be_nil
    end

    it "reads the initializer's generated line" do
      write_initializer(<<~RUBY)
        RailsAiContext.configure do |config|
          config.ai_tools = %i[claude cursor]
        end
      RUBY

      expect(described_class.read(root: root)).to eq(%i[claude cursor])
    end

    it "reads the YAML record when there is no initializer" do
      write_yaml("ai_tools:\n  - claude\n  - codex\n")

      expect(described_class.read(root: root)).to eq(%i[claude codex])
    end

    # Rails config is the file a user hand-edits, so it outranks the record
    # the installer keeps for itself.
    it "lets a hand-edited initializer win over the YAML record" do
      write_initializer("config.ai_tools = %i[copilot]\n")
      write_yaml("ai_tools:\n  - claude\n  - cursor\n")

      expect(described_class.read(root: root)).to eq([ :copilot ])
    end

    it "falls through to YAML when the initializer has no selection line" do
      write_initializer("RailsAiContext.configure do |config|\n  config.preset = :full\nend\n")
      write_yaml("ai_tools:\n  - opencode\n")

      expect(described_class.read(root: root)).to eq([ :opencode ])
    end

    it "falls through to YAML when the initializer line is unparseable" do
      write_initializer("config.ai_tools = SOME_CONSTANT\n")
      write_yaml("ai_tools:\n  - opencode\n")

      expect(described_class.read(root: root)).to eq([ :opencode ])
    end

    it "falls through to YAML when the initializer names no tool" do
      write_initializer("config.ai_tools = %i[]\n")
      write_yaml("ai_tools:\n  - opencode\n")

      expect(described_class.read(root: root)).to eq([ :opencode ])
    end

    it "ignores a commented-out selection line" do
      write_initializer("# config.ai_tools = %i[claude cursor copilot opencode codex]  # default: all\n")
      write_yaml("ai_tools:\n  - codex\n")

      expect(described_class.read(root: root)).to eq([ :codex ])
    end

    it "survives unreadable YAML rather than raising" do
      write_yaml("ai_tools: [unclosed\n")

      expect(described_class.read(root: root)).to be_nil
    end

    it "drops a name that is not a known AI tool" do
      write_initializer("config.ai_tools = %i[claude emacs]\n")

      expect(described_class.read(root: root)).to eq([ :claude ])
    end
  end

  describe ".write" do
    it "always writes the YAML record" do
      described_class.write(%i[claude codex], root: root)

      expect(YAML.safe_load_file(File.join(root, ".rails-ai-context.yml"))["ai_tools"])
        .to eq(%w[claude codex])
    end

    it "round-trips through read" do
      described_class.write(%i[cursor copilot], root: root)

      expect(described_class.read(root: root)).to eq(%i[cursor copilot])
    end

    it "keeps the rest of an existing YAML record" do
      write_yaml("preset: full\nai_tools:\n  - claude\n")

      described_class.write([ :codex ], root: root)

      data = YAML.safe_load_file(File.join(root, ".rails-ai-context.yml"))
      expect(data["preset"]).to eq("full")
      expect(data["ai_tools"]).to eq(%w[codex])
    end

    it "updates the initializer's line when one exists" do
      write_initializer(<<~RUBY)
        RailsAiContext.configure do |config|
          config.ai_tools = %i[claude]
          config.preset = :full
        end
      RUBY

      described_class.write(%i[cursor codex], root: root)

      content = File.read(File.join(root, "config", "initializers", "rails_ai_context.rb"))
      expect(content).to include("config.ai_tools = %i[cursor codex]")
      expect(content).to include("config.preset = :full")
      expect(described_class.read(root: root)).to eq(%i[cursor codex])
    end

    it "leaves a project with no initializer alone" do
      described_class.write([ :claude ], root: root)

      expect(File.exist?(File.join(root, "config", "initializers", "rails_ai_context.rb"))).to be(false)
    end

    # Without this the entries diverge again: only one of them could put a
    # selection into an initializer that has a configure block but no line,
    # so which entry you ran decided whether the record was complete.
    it "inserts the selection into a configure block that has no line yet" do
      write_initializer(<<~RUBY)
        RailsAiContext.configure do |config|
          config.preset = :full
        end
      RUBY

      described_class.write(%i[codex], root: root)

      content = File.read(File.join(root, "config", "initializers", "rails_ai_context.rb"))
      expect(content).to include("config.ai_tools = %i[codex]")
      expect(content).to include("config.preset = :full")
      expect(described_class.read(root: root)).to eq([ :codex ])
    end

    it "does not invent a configure block that is not there" do
      write_initializer("# just a comment\n")

      described_class.write([ :codex ], root: root)

      expect(File.read(File.join(root, "config", "initializers", "rails_ai_context.rb")))
        .to eq("# just a comment\n")
    end

    # Each entry prints its own "Created/Updated/unchanged" line, so the one
    # writer has to say what it did or the entries keep their own copies of
    # the writing just to know what to print.
    describe "what it reports" do
      it "reports the YAML as created the first time" do
        expect(described_class.write([ :claude ], root: root)).to include(yaml: :created)
      end

      it "reports the YAML as updated when the selection changes" do
        described_class.write([ :claude ], root: root)

        expect(described_class.write([ :codex ], root: root)).to include(yaml: :updated)
      end

      it "reports the YAML as unchanged when nothing moved" do
        described_class.write([ :claude ], root: root)

        expect(described_class.write([ :claude ], root: root)).to include(yaml: :unchanged)
      end

      it "reports no initializer when the project has none" do
        expect(described_class.write([ :claude ], root: root)).to include(initializer: :absent)
      end

      it "reports the initializer as inserted when it had no selection line" do
        write_initializer("RailsAiContext.configure do |config|\n  config.preset = :full\nend\n")

        expect(described_class.write([ :codex ], root: root)).to include(initializer: :inserted)
      end

      it "reports the initializer as updated when it carried a selection" do
        write_initializer("RailsAiContext.configure do |config|\n  config.ai_tools = %i[claude]\nend\n")

        expect(described_class.write([ :codex ], root: root)).to include(initializer: :updated)
      end

      it "reports the initializer as unchanged when it already said this" do
        write_initializer("RailsAiContext.configure do |config|\n  config.ai_tools = %i[codex]\nend\n")

        expect(described_class.write([ :codex ], root: root)).to include(initializer: :unchanged)
      end

      it "reports the tools it actually recorded" do
        expect(described_class.write(%i[codex emacs], root: root)).to include(tools: [ :codex ])
      end
    end

    # A pattern loose enough to match the commented-out default would write the
    # selection onto the comment, where the next read cannot see it.
    it "does not write the selection onto a commented-out default" do
      write_initializer(<<~RUBY)
        RailsAiContext.configure do |config|
          # config.ai_tools = %i[claude cursor codex]
        end
      RUBY

      described_class.write([ :codex ], root: root)

      content = File.read(File.join(root, "config", "initializers", "rails_ai_context.rb"))
      expect(content).to include("# config.ai_tools = %i[claude cursor codex]")
    end
  end

  # The bug: re-running install through a different entry point dropped the
  # previous selection, because the generator only ever read the initializer
  # and the standalone CLI only ever read the YAML.
  describe "across entry points" do
    it "recovers a selection recorded by an entry that wrote only YAML" do
      write_yaml("ai_tools:\n  - copilot\n  - codex\n")

      expect(described_class.read(root: root)).to eq(%i[copilot codex])
    end

    it "recovers a selection recorded by an entry that wrote only the initializer" do
      write_initializer("config.ai_tools = %i[copilot codex]\n")

      expect(described_class.read(root: root)).to eq(%i[copilot codex])
    end
  end
end
