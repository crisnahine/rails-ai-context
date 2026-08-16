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

    # A second assignment would win at boot while `read` returned the first,
    # which is the divergence this module exists to close. The selection line
    # is only rewritten in the shape the installer writes, so any other shape
    # must be left for the user rather than shadowed.
    it "does not add a second assignment beside a hand-written one" do
      write_initializer(<<~RUBY)
        RailsAiContext.configure do |config|
          config.ai_tools = [:claude, :cursor]
        end
      RUBY

      described_class.write([ :codex ], root: root)

      content = File.read(File.join(root, "config", "initializers", "rails_ai_context.rb"))
      expect(content.scan(/config\.ai_tools\s*=/).size).to eq(1)
      expect(content).to include("config.ai_tools = [:claude, :cursor]")
    end

    # Distinct from :absent. The initializer wins on read, so a selection this
    # module cannot rewrite leaves the user's new pick inert - they have to be
    # told, not just handed a cheerful "Updated .rails-ai-context.yml".
    it "reports a conflict when the initializer assigns in a shape it cannot rewrite" do
      write_initializer("RailsAiContext.configure do |config|\n  config.ai_tools = SOME_CONSTANT\nend\n")

      expect(described_class.write([ :codex ], root: root)).to include(initializer: :conflict)
    end

    it "still reports plain absence when there is no initializer at all" do
      expect(described_class.write([ :codex ], root: root)).to include(initializer: :absent)
    end

    # An ordinary context run refreshes this gem's own YAML but must leave the
    # user's Rails config alone.
    it "can be told to leave the initializer alone" do
      write_initializer("RailsAiContext.configure do |config|\n  config.ai_tools = %i[claude]\nend\n")

      result = described_class.write([ :codex ], root: root, initializer: false)

      expect(result).to include(initializer: :skipped)
      expect(File.read(File.join(root, "config", "initializers", "rails_ai_context.rb")))
        .to include("config.ai_tools = %i[claude]")
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

      # Reporting :unchanged here would have every entry print
      # "(unchanged)" while the user's new selection was quietly dropped.
      # This gem owns the file. Refusing to write because its previous
      # contents will not parse leaves the selection unrecordable for good:
      # one typo and install can never remember anything again. It is
      # replaced, and the caller is told it was replaced rather than updated.
      it "replaces a record it cannot parse, rather than refusing forever" do
        File.write(File.join(root, ".rails-ai-context.yml"), "ai_tools: [unclosed\n")

        expect(described_class.write([ :cursor ], root: root)).to include(yaml: :replaced)
        expect(described_class.read(root: root)).to eq([ :cursor ])
      end

      it "says out loud that it replaced an unreadable record" do
        File.write(File.join(root, ".rails-ai-context.yml"), "ai_tools: [unclosed\n")
        result = described_class.write([ :cursor ], root: root)

        level, text = described_class.messages(result).first
        expect(level).to eq(:warn)
        expect(text).to include("could not be read")
      end

      it "still reports a failure when the file cannot be written at all" do
        allow(File).to receive(:write).and_raise(Errno::EACCES)

        expect(described_class.write([ :cursor ], root: root)).to include(yaml: :failed)
      end

      it "keeps a record carrying a date, rather than failing to load it" do
        File.write(File.join(root, ".rails-ai-context.yml"),
                   "ai_tools:\n  - claude\ngenerated_at: 2026-01-01\n")

        expect(described_class.write([ :cursor ], root: root)).to include(yaml: :updated)
        expect(described_class.read(root: root)).to eq([ :cursor ])
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

  # Each entry prints in its own voice - Thor `say` with a colour, plain
  # `puts` with an emoji, `$stderr.puts`. What there is to say is the same,
  # and keeping three copies of that meant every new outcome had to be added
  # in three places at once.
  describe ".messages" do
    def messages_for(result)
      described_class.messages(result)
    end

    it "says nothing changed when nothing changed" do
      expect(messages_for(yaml: :unchanged, initializer: :unchanged))
        .to eq([ [ :muted, ".rails-ai-context.yml (unchanged)" ] ])
    end

    it "reports each file it wrote" do
      expect(messages_for(yaml: :created, initializer: :updated)).to eq([
        [ :ok, "Created .rails-ai-context.yml" ],
        [ :ok, "Updated config/initializers/rails_ai_context.rb" ]
      ])
    end

    it "treats an inserted initializer line as an update to report" do
      expect(messages_for(yaml: :unchanged, initializer: :inserted).last)
        .to eq([ :ok, "Updated config/initializers/rails_ai_context.rb" ])
    end

    it "warns loudly when the record could not be written" do
      level, text = messages_for(yaml: :failed, initializer: :absent).first

      expect(level).to eq(:warn)
      expect(text).to include("not saved")
    end

    it "warns when the initializer holds a selection it cannot rewrite" do
      level, text = messages_for(yaml: :updated, initializer: :conflict).last

      expect(level).to eq(:warn)
      expect(text).to include("config/initializers/rails_ai_context.rb")
      expect(text).to include("takes precedence")
    end

    it "says nothing about an initializer that is simply not there" do
      expect(messages_for(yaml: :updated, initializer: :absent))
        .to eq([ [ :ok, "Updated .rails-ai-context.yml" ] ])
    end

    it "says nothing about an initializer it was told to skip" do
      expect(messages_for(yaml: :updated, initializer: :skipped))
        .to eq([ [ :ok, "Updated .rails-ai-context.yml" ] ])
    end
  end

  # `rails ai:context:cursor` adds one tool to whatever is already recorded.
  # Doing that by hand against the initializer alone is what left the two
  # files disagreeing.
  describe ".add" do
    it "adds a tool to an existing selection in both files" do
      described_class.write(%i[claude], root: root)
      write_initializer("RailsAiContext.configure do |config|\n  config.ai_tools = %i[claude]\nend\n")

      described_class.add(:cursor, root: root)

      expect(described_class.read(root: root)).to eq(%i[claude cursor])
      expect(YAML.safe_load_file(File.join(root, ".rails-ai-context.yml"))["ai_tools"])
        .to eq(%w[claude cursor])
    end

    it "is a no-op when the tool is already recorded" do
      described_class.write(%i[claude cursor], root: root)

      expect(described_class.add(:cursor, root: root)).to include(tools: %i[claude cursor])
      expect(described_class.read(root: root)).to eq(%i[claude cursor])
    end

    it "records the first tool when nothing has been recorded yet" do
      described_class.add(:codex, root: root)

      expect(described_class.read(root: root)).to eq([ :codex ])
    end

    it "ignores a name that is not an AI tool" do
      described_class.write(%i[claude], root: root)

      described_class.add(:emacs, root: root)

      expect(described_class.read(root: root)).to eq([ :claude ])
    end

    # `json` is a real context format and a real rake task, but not an AI
    # tool. Seeding a selection first hid this: with nothing recorded, the
    # union was empty and an empty selection went into the user's files.
    it "writes nothing at all when the only name given is not an AI tool" do
      write_initializer("RailsAiContext.configure do |config|\n  config.preset = :full\nend\n")

      result = described_class.add(:json, root: root)

      expect(File.exist?(File.join(root, ".rails-ai-context.yml"))).to be(false)
      expect(File.read(File.join(root, "config", "initializers", "rails_ai_context.rb")))
        .not_to include("config.ai_tools")
      expect(result[:tools]).to eq([])
    end

    it "says nothing happened when it wrote nothing" do
      result = described_class.add(:json, root: root)

      expect(described_class.messages(result)).to be_empty
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

  describe ".tool_mode" do
    it "is nil when nothing has been recorded" do
      expect(described_class.tool_mode(root: root)).to be_nil
    end

    it "reads the YAML the installer wrote" do
      write_yaml("ai_tools:\n- claude\ntool_mode: cli\n")

      expect(described_class.tool_mode(root: root)).to eq(:cli)
    end

    it "lets the initializer line win over the YAML" do
      write_yaml("tool_mode: mcp\n")
      write_initializer("  config.tool_mode = :cli\n")

      expect(described_class.tool_mode(root: root)).to eq(:cli)
    end

    it "ignores the commented-out default in the generated initializer" do
      write_initializer("  # config.tool_mode = :cli\n")

      expect(described_class.tool_mode(root: root)).to be_nil
    end
  end

  describe ".write_tool_mode" do
    it "rewrites an existing uncommented line" do
      write_initializer("RailsAiContext.configure do |config|\n  config.tool_mode = :mcp\nend\n")

      expect(described_class.write_tool_mode(:cli, root: root)).to eq(:updated)
      expect(described_class.tool_mode(root: root)).to eq(:cli)
    end

    it "inserts beside the recorded tools line, leaving a commented default a comment" do
      write_initializer(<<~RUBY)
        RailsAiContext.configure do |config|
          config.ai_tools = %i[claude]
          # config.tool_mode = :cli
        end
      RUBY

      expect(described_class.write_tool_mode(:mcp, root: root)).to eq(:inserted)
      content = File.read(File.join(root, "config", "initializers", "rails_ai_context.rb"))
      expect(content).to include("config.ai_tools = %i[claude]\n  config.tool_mode = :mcp")
      expect(content).to include("# config.tool_mode = :cli")
    end

    it "inserts into a bare configure block" do
      write_initializer("RailsAiContext.configure do |config|\nend\n")

      expect(described_class.write_tool_mode(:cli, root: root)).to eq(:inserted)
      expect(described_class.tool_mode(root: root)).to eq(:cli)
    end

    it "reports an unchanged line and an absent file honestly" do
      expect(described_class.write_tool_mode(:cli, root: root)).to eq(:absent)

      write_initializer("RailsAiContext.configure do |config|\n  config.tool_mode = :cli\nend\n")
      expect(described_class.write_tool_mode(:cli, root: root)).to eq(:unchanged)
    end
  end
end
