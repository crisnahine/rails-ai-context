# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rails/generators"
require "generators/rails_ai_context/install/install_generator"

RSpec.describe RailsAiContext::Generators::InstallGenerator do
  subject(:generator) do
    described_class.new([], {}, destination_root: tmpdir).tap do |instance|
      instance.instance_variable_set(:@selected_formats, %i[claude copilot])
      instance.instance_variable_set(:@tool_mode, :mcp)
    end
  end

  let(:tmpdir) { Dir.mktmpdir }
  let(:initializer_path) { File.join(tmpdir, "config/initializers/rails_ai_context.rb") }

  before do
    FileUtils.mkdir_p(File.dirname(initializer_path))
    allow(Rails).to receive(:root).and_return(Pathname.new(tmpdir))
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  describe "#create_initializer" do
    it "creates a guarded initializer for fresh installs" do
      generator.create_initializer

      content = File.read(initializer_path)

      expect(content).to start_with(<<~RUBY)
        # frozen_string_literal: true

        if defined?(RailsAiContext)
          RailsAiContext.configure do |config|
      RUBY
      expect(content).to include("  config.ai_tools = %i[claude copilot]")
      expect(content).to include("  config.tool_mode = :mcp   # MCP primary + CLI fallback")
      expect(content).to end_with("  end\nend\n")
    end

    it "adds the guard when updating an existing unguarded initializer" do
      File.write(initializer_path, <<~RUBY)
        # frozen_string_literal: true

        RailsAiContext.configure do |config|
          config.ai_tools = %i[claude]
          config.tool_mode = :cli
        end
      RUBY

      generator.create_initializer

      content = File.read(initializer_path)

      expect(content.scan("if defined?(RailsAiContext)").size).to eq(1)
      expect(content).to include("  config.ai_tools = %i[claude copilot]")
      expect(content).to include("  config.tool_mode = :mcp   # MCP primary + CLI fallback")
      expect(content).to match(/if defined\?\(RailsAiContext\)\n  RailsAiContext.configure do \|config\|.*\n  end\nend\n/m)
    end

    it "keeps added sections inside the configure block for guarded initializers" do
      File.write(initializer_path, <<~RUBY)
        # frozen_string_literal: true

        if defined?(RailsAiContext)
          RailsAiContext.configure do |config|
            config.ai_tools = %i[claude]
          end
        end
      RUBY

      generator.create_initializer

      content = File.read(initializer_path)

      expect(content.scan("if defined?(RailsAiContext)").size).to eq(1)
      expect(content).to include("    config.ai_tools = %i[claude copilot]")
      expect(content).to include("    # ── Introspection")
      expect(content).to include("    # config.tool_mode = :mcp")
      expect(content).not_to include("\n  config.ai_tools = %i[claude copilot]")
      expect(content).to match(/if defined\?\(RailsAiContext\)\n  RailsAiContext.configure do \|config\|.*# ── Introspection.*\n  end\nend\n/m)
    end

    it "preserves indentation when replacing config lines in guarded initializers" do
      File.write(initializer_path, <<~RUBY)
        # frozen_string_literal: true

        if defined?(RailsAiContext)
          RailsAiContext.configure do |config|
            config.ai_tools = %i[claude]
            config.tool_mode = :cli
          end
        end
      RUBY

      generator.create_initializer

      content = File.read(initializer_path)

      expect(content).to include("    config.ai_tools = %i[claude copilot]")
      expect(content).to include("    config.tool_mode = :mcp   # MCP primary + CLI fallback")
      expect(content).not_to include("\n  config.tool_mode = :mcp   # MCP primary + CLI fallback")
    end
  end

  describe "#install_validation_hook" do
    let(:hook_path) { File.join(tmpdir, ".git/hooks/pre-commit") }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, ".git"))
      allow(generator).to receive(:ask).and_return("y")
    end

    it "passes staged files to validation without collapsing newlines into spaces" do
      generator.install_validation_hook

      content = File.read(hook_path)

      expect(content).to include("files=$(printf '%s\\n' \"$changed_files\" | tr '\\n' ',')")
      expect(content).to include("rails 'ai:tool[validate]' files=\"$files\"")
      expect(content).not_to include("echo $changed_files")
    end
  end

  describe "#create_yaml_config" do
    let(:yaml_path) { File.join(tmpdir, ".rails-ai-context.yml") }

    it "creates the file and reports Created on first run" do
      expect { generator.create_yaml_config }.to output(/Created \.rails-ai-context\.yml/).to_stdout
      expect(File.read(yaml_path)).to include("ai_tools:")
    end

    it "reports unchanged and does not rewrite the file when content is identical" do
      generator.create_yaml_config
      mtime_before = File.mtime(yaml_path)

      expect { generator.create_yaml_config }.to output(/\.rails-ai-context\.yml \(unchanged\)/).to_stdout
      expect(File.mtime(yaml_path)).to eq(mtime_before)
    end

    it "reports Updated when the selection changed" do
      generator.create_yaml_config
      generator.instance_variable_set(:@selected_formats, %i[claude])

      expect { generator.create_yaml_config }.to output(/Updated \.rails-ai-context\.yml/).to_stdout
      expect(File.read(yaml_path)).to include("- claude")
      expect(File.read(yaml_path)).not_to include("- copilot")
    end
  end

  describe "#add_to_gitignore" do
    let(:gitignore_path) { File.join(tmpdir, ".gitignore") }

    it "does not create .gitignore when the project doesn't have one" do
      generator.add_to_gitignore
      expect(File.exist?(gitignore_path)).to be(false)
    end

    it "appends both .ai-context.json and .codex/config.toml when .gitignore exists" do
      File.write(gitignore_path, "*.log\n")

      generator.add_to_gitignore

      content = File.read(gitignore_path)
      expect(content).to include(".ai-context.json")
      expect(content).to include(".codex/config.toml")
    end

    it "does not duplicate entries that are already present" do
      File.write(gitignore_path, "*.log\n.ai-context.json\n.codex/config.toml\n")

      expect { generator.add_to_gitignore }.to output("").to_stdout

      content = File.read(gitignore_path)
      expect(content.scan(".ai-context.json").size).to eq(1)
      expect(content.scan(".codex/config.toml").size).to eq(1)
    end
  end
end
