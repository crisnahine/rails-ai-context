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
        allow(RailsAiContext::SafeFile).to receive(:atomic_write).and_raise(Errno::EACCES)

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

    # The YAML is a config file people annotate (STANDALONE.md's sample is
    # full of comments). Re-dumping it on every run threw their notes away
    # even when no value had moved.
    describe "a YAML record someone annotated" do
      let(:yaml_path) { File.join(root, ".rails-ai-context.yml") }
      let(:annotated) do
        <<~YAML
          ---
          # Picked at the team meeting.
          ai_tools:
          - claude
          # - cursor (back once the rules are reviewed)
          - copilot
          tool_mode: mcp  # keep MCP, the agents rely on it
          context_files: true

          # team: lower log tail for our noisy dev log
          log_lines: 30
        YAML
      end

      before { write_yaml(annotated) }

      it "is left byte for byte when no value changed" do
        result = described_class.write(%i[claude copilot], root: root,
                                                           extra_yaml: { "tool_mode" => "mcp", "context_files" => true })

        expect(result).to include(yaml: :unchanged)
        expect(File.read(yaml_path)).to eq(annotated)
      end

      it "reads the tools as a set, so their order is no change" do
        result = described_class.write(%i[copilot claude], root: root)

        expect(result).to include(yaml: :unchanged)
      end

      it "changes a scalar where it stands and keeps the comment after it" do
        described_class.write(%i[claude copilot], root: root, extra_yaml: { "tool_mode" => "cli" })

        expect(File.read(yaml_path)).to eq(annotated.sub("tool_mode: mcp  #", "tool_mode: cli  #"))
      end

      it "changes a list in place, keeping the tools it still holds and the comments between them" do
        described_class.write(%i[claude copilot codex], root: root)

        expect(File.read(yaml_path)).to eq(annotated.sub("- copilot\n", "- copilot\n- codex\n"))

        described_class.write(%i[copilot], root: root)

        expect(File.read(yaml_path)).to eq(annotated.sub("- claude\n", ""))
        expect(described_class.read(root: root)).to eq([ :copilot ])
      end

      it "adds a key it did not hold at the end, leaving the rest alone" do
        File.write(yaml_path, "# mine\nai_tools:\n  - claude\n")

        described_class.write(%i[claude], root: root, extra_yaml: { "context_files" => false })

        expect(File.read(yaml_path)).to eq("# mine\nai_tools:\n  - claude\ncontext_files: false\n")
      end

      it "rewrites a flow list on its line" do
        File.write(yaml_path, "ai_tools: [claude]   # ours\npreset: full\n")

        described_class.write(%i[claude cursor], root: root)

        expect(File.read(yaml_path)).to eq("ai_tools: [claude, cursor]   # ours\npreset: full\n")
      end

      it "reads a symbol as its name" do
        File.write(yaml_path, "ai_tools:\n- claude\ntool_mode: :mcp\n")

        expect(described_class.write(%i[claude], root: root, extra_yaml: { "tool_mode" => "mcp" })).to include(yaml: :unchanged)
      end

      # A shape the line edit does not know is caught by reading the result
      # back; the record is then written whole, so the value is never wrong.
      it "writes the record whole when it cannot edit it in place" do
        File.write(yaml_path, "\"ai_tools\": [claude]\n")

        described_class.write(%i[cursor], root: root)

        expect(described_class.read(root: root)).to eq([ :cursor ])
        expect(YAML.safe_load_file(yaml_path).keys).to eq([ "ai_tools" ])
      end

      it "writes through a link to the file it names, keeping its mode" do
        real = File.join(root, "shared.yml")
        File.write(real, annotated)
        File.chmod(0o640, real)
        File.delete(yaml_path)
        File.symlink(real, yaml_path)

        described_class.write(%i[claude copilot], root: root, extra_yaml: { "tool_mode" => "cli" })

        expect(File.symlink?(yaml_path)).to be(true)
        expect(File.read(real)).to include("tool_mode: cli")
        expect(File.stat(real).mode & 0o777).to eq(0o640)
      end
    end

    # The initializer is the user's Rails config. A rewrite at two spaces
    # inside the guard's four-space block, with the note dropped, broke their
    # Rubocop and announced an update when nothing had changed.
    describe "an initializer line someone indented and annotated" do
      let(:initializer) do
        <<~RUBY
          if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
            RailsAiContext.configure do |config|
              config.ai_tools = %i[claude cursor]
              config.tool_mode = :mcp   # MCP primary + CLI fallback
              config.context_files = true # set by ops
            end
          end
        RUBY
      end
      let(:path) { File.join(root, "config", "initializers", "rails_ai_context.rb") }

      before { write_initializer(initializer) }

      it "is left byte for byte when it already holds the values" do
        expect(described_class.write(%i[cursor claude], root: root)).to include(initializer: :unchanged)
        expect(described_class.write_tool_mode(:mcp, root: root)).to eq(:unchanged)
        expect(described_class.write_context_files(true, root: root)).to eq(:unchanged)
        expect(File.read(path)).to eq(initializer)
      end

      it "changes the value where it stands, swapping the generator's note for the new value's" do
        expect(described_class.write_tool_mode(:cli, root: root)).to eq(:updated)

        expect(File.read(path)).to eq(initializer.sub(
          "    config.tool_mode = :mcp   # MCP primary + CLI fallback",
          "    config.tool_mode = :cli    # CLI only (no MCP server needed)"
        ))
      end

      it "keeps a note of the user's own" do
        described_class.write_context_files(false, root: root)

        expect(File.read(path)).to include("\n    config.context_files = false # set by ops\n")
      end

      it "keeps the indentation when the tools change" do
        described_class.write(%i[claude cursor codex], root: root)

        expect(File.read(path)).to include("\n    config.ai_tools = %i[claude cursor codex]\n")
      end

      it "inserts a missing line at the indentation of the line it sits beside" do
        File.write(path, initializer.sub("    config.tool_mode = :mcp   # MCP primary + CLI fallback\n", ""))

        expect(described_class.write_tool_mode(:cli, root: root)).to eq(:inserted)
        expect(File.read(path)).to include(
          "    config.ai_tools = %i[claude cursor]\n    config.tool_mode = :cli    # CLI only (no MCP server needed)\n"
        )
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

  # MCP-only: the same two records, the same precedence.
  describe ".context_files" do
    it "is nil when nothing has been recorded" do
      expect(described_class.context_files(root: root)).to be_nil
    end

    it "reads the YAML the installer wrote" do
      write_yaml("ai_tools:\n- claude\ncontext_files: false\n")

      expect(described_class.context_files(root: root)).to be(false)
    end

    it "lets the initializer line win over the YAML" do
      write_yaml("context_files: true\n")
      write_initializer("  config.context_files = false\n")

      expect(described_class.context_files(root: root)).to be(false)
    end

    it "ignores the commented-out default in the generated initializer" do
      write_initializer("  # config.context_files = true\n")

      expect(described_class.context_files(root: root)).to be_nil
    end
  end

  describe ".write_context_files" do
    it "rewrites an existing uncommented line" do
      write_initializer("RailsAiContext.configure do |config|\n  config.context_files = true\nend\n")

      expect(described_class.write_context_files(false, root: root)).to eq(:updated)
      expect(described_class.context_files(root: root)).to be(false)
    end

    it "inserts beside the recorded tools line" do
      write_initializer(<<~RUBY)
        RailsAiContext.configure do |config|
          config.ai_tools = %i[claude]
        end
      RUBY

      expect(described_class.write_context_files(false, root: root)).to eq(:inserted)
      expect(described_class.context_files(root: root)).to be(false)
    end

    it "says so when there is no initializer to write to" do
      expect(described_class.write_context_files(false, root: root)).to eq(:absent)
    end
  end

  describe ".write_tool_mode" do
    # A second line beside it would lose at boot and win on read.
    it "does not add a line beside an assignment it cannot rewrite" do
      FileUtils.mkdir_p(File.join(root, "config", "initializers"))
      path = File.join(root, "config", "initializers", "rails_ai_context.rb")
      body = "RailsAiContext.configure do |config|\n  config.tool_mode = ENV.fetch(\"MODE\", \"mcp\").to_sym\nend\n"
      File.write(path, body)

      expect(described_class.write_tool_mode(:cli, root: root)).to eq(:conflict)
      expect(File.read(path)).to eq(body)
      expect(described_class.conflict_message(:tool_mode, :conflict).last).to include("config.tool_mode")
      expect(described_class.conflict_message(:tool_mode, :updated)).to be_nil
      # Settled, whatever its shape, so `rails ai:context` does not ask on every run.
      expect(described_class.tool_mode_set?(root: root)).to be(true)
    end

    it "reads the tool mode as unset when nothing assigns it" do
      expect(described_class.tool_mode_set?(root: root)).to be(false)
    end

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
