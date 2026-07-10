# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Doctor do
  let(:doctor) { described_class.new(Rails.application) }

  describe "#run" do
    subject(:result) { doctor.run }

    it "returns checks and a score" do
      expect(result).to have_key(:checks)
      expect(result).to have_key(:score)
    end

    it "returns an array of checks" do
      expect(result[:checks]).to all(be_a(RailsAiContext::Doctor::Check))
    end

    it "computes a score between 0 and 100" do
      expect(result[:score]).to be_between(0, 100)
    end

    it "checks schema presence" do
      names = result[:checks].map(&:name)
      expect(names).to include("Schema")
    end

    it "includes core checks" do
      names = result[:checks].map(&:name)
      expect(names).to include("Controllers", "Views", "Tests", "MCP server")
    end

    it "includes deep checks" do
      names = result[:checks].map(&:name)
      expect(names).to include("Context files", "Preset coverage", "Secrets in .gitignore", "MCP auto_mount")
    end

    it "runs at least 15 checks" do
      expect(result[:checks].size).to be >= 15
    end

    it "checks MCP server buildability" do
      mcp_check = result[:checks].find { |c| c.name == "MCP server" }
      expect(mcp_check.status).to eq(:pass)
    end

    it "all checks have a name and message" do
      result[:checks].each do |check|
        expect(check.name).to be_a(String)
        expect(check.message).to be_a(String)
        expect(%i[pass warn fail]).to include(check.status)
      end
    end

    it "checks security settings" do
      auto_mount = result[:checks].find { |c| c.name == "MCP auto_mount" }
      expect(auto_mount).not_to be_nil
      expect(auto_mount.status).to eq(:pass)
    end

    it "checks preset coverage" do
      preset = result[:checks].find { |c| c.name == "Preset coverage" }
      expect(preset).not_to be_nil
    end
  end

  describe "#check_codex_env_staleness" do
    subject(:check) { doctor.send(:check_codex_env_staleness) }

    let(:toml_path) { File.join(Rails.application.root, ".codex/config.toml") }

    context "when codex is not in ai_tools" do
      before do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude cursor])
      end

      it "returns nil (skipped)" do
        expect(check).to be_nil
      end
    end

    context "when codex is in ai_tools" do
      before do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude codex])
      end

      context "when .codex/config.toml does not exist" do
        before do
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(toml_path).and_return(false)
        end

        it "returns nil (skipped)" do
          expect(check).to be_nil
        end
      end

      context "when .codex/config.toml exists but has no env section" do
        before do
          toml_content = <<~TOML
            [mcp_servers.rails-ai-context]
            command = "bundle"
            args = ["exec", "rails", "ai:serve"]
          TOML
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(toml_path).and_return(true)
          allow(File).to receive(:read).and_call_original
          allow(File).to receive(:read).with(toml_path).and_return(toml_content)
        end

        it "returns nil (skipped)" do
          expect(check).to be_nil
        end
      end

      context "when env section exists but has no GEM_HOME" do
        before do
          toml_content = <<~TOML
            [mcp_servers.rails-ai-context]
            command = "bundle"
            args = ["exec", "rails", "ai:serve"]

            [mcp_servers.rails-ai-context.env]
            PATH = "/usr/local/bin:/usr/bin"
          TOML
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(toml_path).and_return(true)
          allow(File).to receive(:read).and_call_original
          allow(File).to receive(:read).with(toml_path).and_return(toml_content)
        end

        it "returns nil (skipped)" do
          expect(check).to be_nil
        end
      end

      context "when GEM_HOME directory exists on disk" do
        let(:gem_home) { Dir.mktmpdir("gem_home_test") }

        after { FileUtils.rm_rf(gem_home) }

        before do
          toml_content = <<~TOML
            [mcp_servers.rails-ai-context]
            command = "bundle"
            args = ["exec", "rails", "ai:serve"]

            [mcp_servers.rails-ai-context.env]
            GEM_HOME = "#{gem_home}"
            PATH = "/usr/local/bin:/usr/bin"
          TOML
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(toml_path).and_return(true)
          allow(File).to receive(:read).and_call_original
          allow(File).to receive(:read).with(toml_path).and_return(toml_content)
        end

        it "returns a pass check" do
          expect(check.status).to eq(:pass)
          expect(check.name).to eq("Codex env snapshot")
          expect(check.message).to include(gem_home)
        end
      end

      context "when GEM_HOME directory no longer exists" do
        let(:stale_gem_home) { "/nonexistent/path/to/gems/3.3.0" }

        before do
          toml_content = <<~TOML
            [mcp_servers.rails-ai-context]
            command = "bundle"
            args = ["exec", "rails", "ai:serve"]

            [mcp_servers.rails-ai-context.env]
            GEM_HOME = "#{stale_gem_home}"
            PATH = "/usr/local/bin:/usr/bin"
          TOML
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(toml_path).and_return(true)
          allow(File).to receive(:read).and_call_original
          allow(File).to receive(:read).with(toml_path).and_return(toml_content)
        end

        it "returns a warn check with stale GEM_HOME path" do
          expect(check.status).to eq(:warn)
          expect(check.name).to eq("Codex env snapshot")
          expect(check.message).to include("stale")
          expect(check.message).to include(stale_gem_home)
          expect(check.fix).to include("install")
        end
      end

      context "when env section is followed by another TOML section" do
        let(:gem_home) { Dir.mktmpdir("gem_home_boundary") }

        after { FileUtils.rm_rf(gem_home) }

        before do
          toml_content = <<~TOML
            [mcp_servers.rails-ai-context]
            command = "bundle"
            args = ["exec", "rails", "ai:serve"]

            [mcp_servers.rails-ai-context.env]
            GEM_HOME = "#{gem_home}"

            [mcp_servers.other-tool]
            command = "other"
          TOML
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with(toml_path).and_return(true)
          allow(File).to receive(:read).and_call_original
          allow(File).to receive(:read).with(toml_path).and_return(toml_content)
        end

        it "correctly parses the env section and returns pass" do
          expect(check.status).to eq(:pass)
          expect(check.message).to include(gem_home)
        end
      end
    end
  end

  describe "#check_initializer_guard" do
    subject(:check) { doctor.send(:check_initializer_guard) }

    let(:root) { Rails.application.root }
    let(:initializer_path) { File.join(root, "config/initializers/rails_ai_context.rb") }

    before do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:read).and_call_original
    end

    context "when no initializer exists" do
      before { allow(File).to receive(:exist?).with(initializer_path).and_return(false) }

      it "returns nil" do
        expect(check).to be_nil
      end
    end

    context "when the initializer uses the bare defined? guard" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          if defined?(RailsAiContext)
            RailsAiContext.configure do |config|
            end
          end
        RUBY
      end

      it "warns with a fix" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("defined?(RailsAiContext)")
        expect(check.fix).to include("respond_to?(:configure)")
      end
    end

    context "when the initializer already guards with respond_to?" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
            RailsAiContext.configure do |config|
            end
          end
        RUBY
      end

      it "returns nil" do
        expect(check).to be_nil
      end
    end
  end

  describe "#check_mcp_json" do
    subject(:check) { doctor.send(:check_mcp_json) }

    let(:root) { Rails.application.root }

    context "when tool_mode is :cli" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:cli)
      end

      it "returns pass with skip message" do
        expect(check.status).to eq(:pass)
        expect(check.message).to include("CLI-only")
      end
    end

    context "when multiple tools configured, some configs missing" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude cursor copilot])
        # .mcp.json exists and is valid
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(File.join(root, ".mcp.json")).and_return(true)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with(File.join(root, ".mcp.json")).and_return('{"mcpServers":{}}')
        # .cursor/mcp.json missing
        allow(File).to receive(:exist?).with(File.join(root, ".cursor/mcp.json")).and_return(false)
        # .vscode/mcp.json missing
        allow(File).to receive(:exist?).with(File.join(root, ".vscode/mcp.json")).and_return(false)
      end

      it "aggregates all failures into a single check" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("2 of 3")
        expect(check.message).to include(".cursor/mcp.json")
        expect(check.message).to include(".vscode/mcp.json")
      end
    end

    context "when all configs present and valid" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude opencode])
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(File.join(root, ".mcp.json")).and_return(true)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with(File.join(root, ".mcp.json")).and_return('{"mcpServers":{}}')
        allow(File).to receive(:exist?).with(File.join(root, "opencode.json")).and_return(true)
        allow(File).to receive(:read).with(File.join(root, "opencode.json")).and_return('{"mcp":{}}')
      end

      it "returns pass with count" do
        expect(check.status).to eq(:pass)
        expect(check.message).to include("2 of 2")
      end
    end

    context "when no tools configured (defaults to all)" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
        # Stub all 5 config files as present
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:read).and_call_original
        %w[.mcp.json .cursor/mcp.json .vscode/mcp.json opencode.json].each do |path|
          allow(File).to receive(:exist?).with(File.join(root, path)).and_return(true)
          allow(File).to receive(:read).with(File.join(root, path)).and_return("{}")
        end
        allow(File).to receive(:exist?).with(File.join(root, ".codex/config.toml")).and_return(true)
      end

      it "checks all 5 tools and returns pass" do
        expect(check.status).to eq(:pass)
        expect(check.message).to include("5 of 5")
      end
    end

    context "when a JSON config has invalid JSON" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(File.join(root, ".mcp.json")).and_return(true)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with(File.join(root, ".mcp.json")).and_return("not json{{{")
      end

      it "returns fail status with tool label" do
        expect(check.status).to eq(:fail)
        expect(check.message).to include("1 of 1")
        expect(check.message).to include(".mcp.json")
      end
    end
  end

  describe "#check_security_gitignore" do
    subject(:check) { doctor.send(:check_security_gitignore) }

    let(:root) { Rails.application.root }
    let(:master_key_path) { File.join(root, "config/master.key") }
    let(:env_path) { File.join(root, ".env") }
    let(:gitignore_path) { File.join(root, ".gitignore") }

    before do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:read).and_call_original
    end

    context "when no sensitive files are present" do
      before do
        allow(File).to receive(:exist?).with(env_path).and_return(false)
        allow(File).to receive(:exist?).with(master_key_path).and_return(false)
      end

      it "passes without needing a .gitignore" do
        expect(check.status).to eq(:pass)
      end
    end

    context "when a sensitive file exists but .gitignore is missing" do
      before do
        allow(File).to receive(:exist?).with(env_path).and_return(false)
        allow(File).to receive(:exist?).with(master_key_path).and_return(true)
        allow(File).to receive(:exist?).with(gitignore_path).and_return(false)
      end

      it "reports the missing .gitignore, not a missing entry" do
        expect(check.status).to eq(:fail)
        expect(check.message).to include("No .gitignore found")
        expect(check.message).to include("config/master.key")
        expect(check.fix).to include("Create .gitignore with")
        expect(check.fix).to include("config/master.key")
      end
    end

    context "when .gitignore exists but is missing an entry" do
      before do
        allow(File).to receive(:exist?).with(env_path).and_return(false)
        allow(File).to receive(:exist?).with(master_key_path).and_return(true)
        allow(File).to receive(:exist?).with(gitignore_path).and_return(true)
        allow(File).to receive(:read).with(gitignore_path).and_return("log/\ntmp/\n")
      end

      it "reports the file is not gitignored" do
        expect(check.status).to eq(:fail)
        expect(check.message).to include("config/master.key not in .gitignore")
        expect(check.fix).to include("Add to .gitignore")
      end
    end

    context "when .gitignore exists and covers the sensitive file" do
      before do
        allow(File).to receive(:exist?).with(env_path).and_return(false)
        allow(File).to receive(:exist?).with(master_key_path).and_return(true)
        allow(File).to receive(:exist?).with(gitignore_path).and_return(true)
        allow(File).to receive(:read).with(gitignore_path).and_return("config/master.key\n")
      end

      it "passes" do
        expect(check.status).to eq(:pass)
      end
    end
  end

  describe "#check_context_freshness" do
    subject(:check) { doctor.send(:check_context_freshness) }

    let(:app) { Rails.application }

    context "when cursor-only (split rules only, no root file)" do
      before do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[cursor])
        allow(File).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).and_call_original

        cursor_rules_path = File.join(app.root, ".cursor/rules")
        # No root file, but split rule directory exists
        allow(File).to receive(:exist?).with(cursor_rules_path).and_return(false)
        allow(Dir).to receive(:exist?).with(cursor_rules_path).and_return(true)
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with(cursor_rules_path).and_return(true)

        # Mock split rule files with recent mtime
        rule_files = [ File.join(cursor_rules_path, "rails-context.mdc") ]
        allow(Dir).to receive(:glob).and_call_original
        allow(Dir).to receive(:glob).with(File.join(cursor_rules_path, "**/*")).and_return(rule_files)
        allow(File).to receive(:mtime).and_call_original
        allow(File).to receive(:mtime).with(rule_files.first).and_return(Time.now)

        # No stale source dirs
        %w[app/models app/controllers app/views config db/migrate].each do |dir|
          allow(Dir).to receive(:exist?).with(File.join(app.root, dir)).and_return(false)
        end
      end

      it "detects .cursor/rules as valid context" do
        expect(check.status).to eq(:pass)
        expect(check.message).to include(".cursor/rules")
      end
    end

    context "when multi-tool configured with existing files" do
      before do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude copilot])
        allow(File).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).and_call_original

        claude_path = File.join(app.root, "CLAUDE.md")
        allow(File).to receive(:exist?).with(claude_path).and_return(true)
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with(claude_path).and_return(false)
        allow(File).to receive(:mtime).and_call_original
        allow(File).to receive(:mtime).with(claude_path).and_return(Time.now)

        %w[app/models app/controllers app/views config db/migrate].each do |dir|
          allow(Dir).to receive(:exist?).with(File.join(app.root, dir)).and_return(false)
        end
      end

      it "checks the first available file (CLAUDE.md)" do
        expect(check.status).to eq(:pass)
        expect(check.message).to include("CLAUDE.md")
      end
    end

    context "when no context files exist" do
      before do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude cursor])
        allow(File).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).and_call_original

        allow(File).to receive(:exist?).with(File.join(app.root, "CLAUDE.md")).and_return(false)
        allow(Dir).to receive(:exist?).with(File.join(app.root, "CLAUDE.md")).and_return(false)
        allow(File).to receive(:exist?).with(File.join(app.root, ".cursor/rules")).and_return(false)
        allow(Dir).to receive(:exist?).with(File.join(app.root, ".cursor/rules")).and_return(false)
      end

      it "returns warn with 'no context files generated'" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("No context files generated")
      end
    end

    context "when context file is stale" do
      before do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        allow(File).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).and_call_original

        claude_path = File.join(app.root, "CLAUDE.md")
        allow(File).to receive(:exist?).with(claude_path).and_return(true)
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with(claude_path).and_return(false)
        # Context generated 1 hour ago
        allow(File).to receive(:mtime).and_call_original
        allow(File).to receive(:mtime).with(claude_path).and_return(Time.now - 3600)

        # app/models exists and has a file newer than context
        models_dir = File.join(app.root, "app/models")
        allow(Dir).to receive(:exist?).with(models_dir).and_return(true)
        model_file = File.join(models_dir, "user.rb")
        allow(Dir).to receive(:glob).and_call_original
        allow(Dir).to receive(:glob).with(File.join(models_dir, "**/*.rb")).and_return([ model_file ])
        allow(File).to receive(:mtime).with(model_file).and_return(Time.now)

        # Other dirs don't exist
        %w[app/controllers app/views config db/migrate].each do |dir|
          allow(Dir).to receive(:exist?).with(File.join(app.root, dir)).and_return(false)
        end
      end

      it "returns warn with stale message" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("stale")
        expect(check.message).to include("app/models")
      end
    end
  end
end
