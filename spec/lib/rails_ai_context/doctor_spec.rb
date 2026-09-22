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

  describe ".report_lines" do
    # The struct check below is not what a user reads. The printed report is.
    it "prints the introspector's own error under its check" do
      allow(RailsAiContext.configuration).to receive(:introspectors).and_return([ :database_stats ])
      allow(ActiveRecord::Base).to receive(:connection)
        .and_raise(StandardError, "Database not found: no_such_db. Run bin/rails db:create")

      lines = described_class.report_lines(doctor.run)
      index = lines.index { |line| line.include?("Introspector health") }

      expect(lines[index]).to include("[WARN] Introspector health:")
      expect(lines[index + 1]).to include("Fix: database_stats: Database not found: no_such_db")
      expect(lines[index + 1]).not_to include("stimulus")
    end

    # The emoji icons are not one width, so indenting the Fix line by the
    # icon above it put the rake report's Fix lines at three columns.
    it "indents every Fix line to the same column under the emoji icons" do
      result = {
        checks: [
          described_class::Check.new(name: "Schema", status: :fail, message: "missing", fix: "run db:migrate"),
          described_class::Check.new(name: "Views", status: :warn, message: "none", fix: "add a view"),
          described_class::Check.new(name: "Gems", status: :pass, message: "ok", fix: nil)
        ]
      }

      lines = described_class.report_lines(result, icons: described_class::EMOJI_ICONS)
      fixes = lines.grep(/Fix:/)

      expect(fixes.size).to eq(2)
      expect(fixes.map { |line| line.index("Fix:") }.uniq.size).to eq(1)
    end
  end

  describe "#check_introspector_health" do
    subject(:check) { doctor.send(:check_introspector_health) }

    def only_introspectors(*names)
      allow(RailsAiContext.configuration).to receive(:introspectors).and_return(names)
    end

    it "quotes the error the introspector returned" do
      only_introspectors(:database_stats)
      allow(ActiveRecord::Base).to receive(:connection)
        .and_raise(StandardError, "Database not found: no_such_db. Run bin/rails db:create")

      expect(check.status).to eq(:warn)
      expect(check.message).to include("database_stats")
      expect(check.fix).to include("database_stats: Database not found: no_such_db")
      expect(check.fix).not_to include("stimulus")
    end

    it "keeps the message line to names when an introspector raises" do
      only_introspectors(:gems)
      allow_any_instance_of(RailsAiContext::Introspectors::GemIntrospector)
        .to receive(:call).and_raise(StandardError, "no Gemfile.lock here")

      expect(check.message).to eq("1 introspector returned errors: gems")
      expect(check.fix).to include("no Gemfile.lock here")
    end

    it "reports an introspector that raises a ScriptError" do
      only_introspectors(:gems)
      allow_any_instance_of(RailsAiContext::Introspectors::GemIntrospector)
        .to receive(:call).and_raise(SyntaxError, "app/models/user.rb:3: syntax error")

      expect(check.status).to eq(:warn)
      expect(check.fix).to include("app/models/user.rb:3: syntax error")
    end

    it "shows the first three errors and counts the rest" do
      only_introspectors(:gems, :routes, :schema, :controllers, :views)
      [
        RailsAiContext::Introspectors::GemIntrospector,
        RailsAiContext::Introspectors::RouteIntrospector,
        RailsAiContext::Introspectors::SchemaIntrospector,
        RailsAiContext::Introspectors::ControllerIntrospector,
        RailsAiContext::Introspectors::ViewIntrospector
      ].each do |klass|
        allow_any_instance_of(klass).to receive(:call).and_raise(StandardError, "boom")
      end

      expect(check.fix.scan("boom").size).to eq(3)
      expect(check.fix).to include("and 2 more introspectors")
    end

    it "keeps the rest of the report when a check raises a ScriptError" do
      allow(doctor).to receive(:check_introspector_health).and_raise(SyntaxError, "broken")
      result = nil

      expect { result = doctor.run }.to output(/check_introspector_health failed/).to_stderr
      expect(result[:checks].map(&:name)).to include("Schema")
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

    # An unguarded file is correct in an app that bundles the gem everywhere,
    # so this is a warn about another environment, never a fail.
    context "when the initializer has no guard at all" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          RailsAiContext.configure do |config|
          end
        RUBY
      end

      it "warns that it breaks where the gem is not loaded" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("no recognised guard")
        expect(check.fix).to include("defined?(RailsAiContext)")
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

    # The two generated spellings are not the only working guards, and a
    # readiness score must not be docked for a file that is already safe.
    context "when the initializer guards on respond_to? alone" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          if RailsAiContext.respond_to?(:configure)
            RailsAiContext.configure do |config|
            end
          end
        RUBY
      end

      it "returns nil" do
        expect(check).to be_nil
      end
    end

    context "when the initializer returns early unless the gem is defined" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          return unless defined?(RailsAiContext::Configuration)

          RailsAiContext.configure do |config|
          end
        RUBY
      end

      it "returns nil" do
        expect(check).to be_nil
      end
    end

    context "when the only mention of a guard comes after the configure call" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          RailsAiContext.configure do |config|
          end

          # TODO: wrap this in defined?(RailsAiContext)
        RUBY
      end

      it "still warns" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("no recognised guard")
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

    # The Codex config carries this machine's PATH and GEM_HOME, which is why
    # install gitignores it; the check never asked whether that survived.
    context "when .codex/config.toml is committed" do
      def gitignore_check_for(root)
        described_class.new(RailsAiContext::StaticApp.new(root)).send(:check_security_gitignore)
      end

      it "reports the Codex config as unignored" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, ".codex"))
          File.write(File.join(dir, ".codex/config.toml"), "[mcp_servers.rails-ai-context]\n")
          File.write(File.join(dir, ".gitignore"), "log/\n")

          check = gitignore_check_for(dir)

          expect(check.status).to eq(:fail)
          expect(check.message).to include(".codex/config.toml")
        end
      end

      it "passes once .gitignore covers it" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, ".codex"))
          File.write(File.join(dir, ".codex/config.toml"), "[mcp_servers.rails-ai-context]\n")
          File.write(File.join(dir, ".gitignore"), ".codex/config.toml\n")

          expect(gitignore_check_for(dir).status).to eq(:pass)
        end
      end
    end
  end

  describe "#check_context_freshness" do
    subject(:check) { doctor.send(:check_context_freshness) }

    let(:app) { Rails.application }

    # An MCP-only install asked for no context files, so "No context files
    # generated" is the configuration working, not something to fix.
    it "is skipped rather than warned under an MCP-only install" do
      allow(RailsAiContext.configuration).to receive(:context_files).and_return(false)

      expect(check).to be_nil
    end

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

    # The freshness check read five hardcoded directories while the watch
    # scope read many more, so an edit in a service or a pack left the
    # context reported as up to date.
    context "against a real app tree" do
      def freshness_for(root)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        described_class.new(RailsAiContext::StaticApp.new(root)).send(:check_context_freshness)
      end

      def write_context_file(root)
        path = File.join(root, "CLAUDE.md")
        File.write(path, "context")
        File.utime(Time.now - 3600, Time.now - 3600, path)
      end

      it "names any directory the watch scope covers" do
        Dir.mktmpdir do |root|
          write_context_file(root)
          FileUtils.mkdir_p(File.join(root, "app/services"))
          File.write(File.join(root, "app/services/billing.rb"), "class Billing; end")

          check = freshness_for(root)

          expect(check.status).to eq(:warn)
          expect(check.message).to include("app/services")
        end
      end

      it "calls the context stale when a model is newer than it" do
        Dir.mktmpdir do |root|
          write_context_file(root)
          FileUtils.mkdir_p(File.join(root, "app/models"))
          File.write(File.join(root, "app/models/user.rb"), "class User; end")

          check = freshness_for(root)

          expect(check.status).to eq(:warn)
          expect(check.message).to include("stale")
          expect(check.message).to include("app/models")
        end
      end

      it "warns after a routes edit, which the config directory covers" do
        Dir.mktmpdir do |root|
          write_context_file(root)
          FileUtils.mkdir_p(File.join(root, "config"))
          File.write(File.join(root, "config/routes.rb"), "Rails.application.routes.draw {}")

          check = freshness_for(root)

          expect(check.status).to eq(:warn)
          expect(check.message).to include("config")
        end
      end

      it "ignores our own initializer, which install writes in the same run" do
        Dir.mktmpdir do |root|
          write_context_file(root)
          FileUtils.mkdir_p(File.join(root, "config/initializers"))
          File.write(File.join(root, "config/initializers/rails_ai_context.rb"), "# installed")

          expect(freshness_for(root).status).to eq(:pass)
        end
      end
    end
  end

  describe "source file checks" do
    def check_named(dir, name)
      described_class.new(RailsAiContext::StaticApp.new(dir)).run[:checks].find { |c| c.name == name }
    end

    it "counts a pack's models and controllers" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "controllers"))
        File.write(File.join(dir, "packs", "billing", "app", "models", "invoice.rb"), "class Invoice; end\n")
        File.write(File.join(dir, "packs", "billing", "app", "controllers", "invoices_controller.rb"),
                   "class InvoicesController; end\n")

        expect(check_named(dir, "Models")).to have_attributes(status: :pass, message: "1 model file found")
        expect(check_named(dir, "Controllers")).to have_attributes(status: :pass, message: "1 controller file found")
      end
    end

    it "warns without naming one directory when no model file exists anywhere" do
      Dir.mktmpdir do |dir|
        expect(check_named(dir, "Models")).to have_attributes(status: :warn, message: "No model files")
      end
    end
  end

  describe "view counts" do
    def check_named(dir, name)
      described_class.new(RailsAiContext::StaticApp.new(dir)).run[:checks].find { |c| c.name == name }
    end

    # Two lines of one report counted different populations under the same
    # noun, so a reader saw two view counts and could not tell which was which.
    it "says what each of the two view lines counted" do
      Dir.mktmpdir do |dir|
        views = File.join(dir, "app", "views", "posts")
        FileUtils.mkdir_p(views)
        File.write(File.join(views, "index.html.erb"), "<h1>Posts</h1>\n")
        File.write(File.join(views, "show.html.erb"), "<h1>Post</h1>\n")
        File.write(File.join(views, "index.json.jbuilder"), "json.posts []\n")

        expect(check_named(dir, "Views").message).to eq("3 files under app/views")
        expect(check_named(dir, "View aggregation size").message)
          .to start_with("2 erb/haml/slim templates")
      end
    end
  end

  describe "model count" do
    it "is what SourceScan.paths resolves for the fixture, concerns included" do
      root = IntrospectedFixture::ROOT
      expected = RailsAiContext::Introspectors::SourceScan.paths(root, kind: "app/models", skip_concerns: false).count
      check = described_class.new(RailsAiContext::StaticApp.new(root)).run[:checks].find { |c| c.name == "Models" }
      expect(check.message).to eq("#{expected} model files found")
    end
  end
end
