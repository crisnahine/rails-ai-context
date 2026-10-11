# frozen_string_literal: true

require_relative "e2e_helper"

# Install path B: Standalone - `gem install rails-ai-context` into an
# isolated GEM_HOME (no Gemfile entry), then run `rails-ai-context init`
# from inside the Rails app directory. CLAUDE.md #33 documents that this
# path pre-loads the gem before Rails boot and restores $LOAD_PATH entries
# stripped by `Bundler.setup`.
#
# This is the path most users take when they don't want to modify their
# Gemfile (shared apps, short-lived exploration, gem-install-then-try).
RSpec.describe "E2E: standalone install", type: :e2e do
  before(:all) do
    # The shared standalone fixture: the zeitwerk examples below change it
    # and put back every file they change.
    @builder = E2E.shared_app(install_path: :standalone)
    @cli = E2E::CliRunner.new(@builder)
  end

  describe "installation" do
    it "installs the gem to an isolated GEM_HOME" do
      expect(File.exist?(File.join(@builder.gem_home, "bin", "rails-ai-context"))).to be(true)
    end

    it "does NOT add a gem line to the Gemfile" do
      gemfile = File.read(File.join(@builder.app_path, "Gemfile"))
      expect(gemfile).not_to include("rails-ai-context")
    end

    it "generates per-AI-client MCP config files (same as in-Gemfile path)" do
      %w[.mcp.json .cursor/mcp.json .vscode/mcp.json opencode.json .codex/config.toml].each do |relative|
        path = File.join(@builder.app_path, relative)
        expect(File.exist?(path)).to be(true), "expected #{relative} to be generated"
      end
    end
  end

  describe "CLI works without a Gemfile entry" do
    it "`rails-ai-context version` reports the gem version" do
      result = @cli.cli("version")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to include(RailsAiContext::VERSION)
    end

    it "`rails-ai-context tool schema` returns the Post table" do
      result = @cli.cli_tool("schema")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to match(/posts|Post/)
    end

    it "`rails-ai-context tool routes` returns scaffolded post routes" do
      result = @cli.cli_tool("routes")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to match(/posts|Post/)
    end

    it "`rails-ai-context doctor` completes successfully" do
      result = @cli.cli("doctor")
      expect(result.success?).to be(true), result.to_s
    end
  end

  # The binstub activates the newest zeitwerk installed. An app that locks an
  # older one and fails in an initializer holds both copies; each wraps
  # Kernel#require, and every tool died with SystemStackError.
  describe "an app that locks a different zeitwerk and fails in an initializer" do
    around do |example|
      app = @builder.app_path
      skip "no zeitwerk below the newest installed (#{binstub_zeitwerk}) to lock" unless binstub_zeitwerk > locked_zeitwerk
      saved = %w[Gemfile Gemfile.lock config/boot.rb].to_h { |f| [ f, File.read(File.join(app, f)) ] }
      raiser = File.join(app, "config", "initializers", "zzz_e2e_raise.rb")

      File.write(File.join(app, "Gemfile"), saved["Gemfile"] + %(\ngem "zeitwerk", "#{locked_zeitwerk}"\n))
      out, status = Open3.capture2e(@builder.env, "bundle", "install", "--quiet", chdir: app)
      raise "bundle install with the pinned zeitwerk failed:\n#{out}" unless status.success?
      locked = Gem::Version.new(File.read(File.join(app, "Gemfile.lock"))[/^    zeitwerk \(([^)]+)\)/, 1].to_s)
      unless locked < binstub_zeitwerk
        raise "the app locks zeitwerk #{locked} and the binstub activates #{binstub_zeitwerk}: no second copy to test"
      end

      File.write(raiser, %(raise "E2E forced boot failure"\n))
      # Bootsnap's load-path cache resolves `require "zeitwerk"` to the copy
      # already loaded, which hides the second copy from this example.
      File.write(File.join(app, "config/boot.rb"), saved["config/boot.rb"].sub(%r{^require "bootsnap/setup".*$}, ""))

      example.run
    ensure
      FileUtils.rm_f(raiser) if raiser
      saved&.each { |f, contents| File.write(File.join(app, f), contents) }
    end

    # 2.7 and 2.8 share the Kernel#require wrapper's internals, so two copies
    # recurse; a 2.6 copy beside a 2.8 one fails differently.
    def locked_zeitwerk = Gem::Version.new("2.7.5")

    def binstub_zeitwerk
      @binstub_zeitwerk ||= Gem::Version.new(Open3.capture2(
        @builder.env, "ruby", "-e", 'puts Gem::Specification.find_all_by_name("zeitwerk").map(&:version).max'
      ).first.strip)
    end

    it "answers a tool from the static tier" do
      result = @cli.cli_tool("schema")

      expect(result.output).not_to include("stack level too deep"), result.to_s
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to include("[STATIC]"), result.to_s
      expect(result.stdout).to match(/posts|Post/), result.to_s
    end

    it "lists every tool over MCP" do
      mcp = E2E::McpStdioClient.new(@builder, timeout: 60).start!
      mcp.initialize!
      tools = mcp.list_tools.dig("result", "tools")

      expect(tools&.size).to eq(RailsAiContext::Server.builtin_tools.size)
    ensure
      mcp&.stop!
    end
  end

  # A tree with source and no config/environment.rb is what the static tier is
  # for. init used to write the config files, then refuse at the boot gate and
  # leave the tree half set up with no context files at all.
  describe "init on a source-only tree" do
    it "finishes and generates context from the static tier" do
      dir = File.join(E2E.root, "source_only_init")
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "config", "application.rb"), "")
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

      env = @builder.env.merge("BUNDLE_GEMFILE" => nil)
      out, status = Open3.capture2e(env, *@builder.cli_command, "init", chdir: dir, stdin_data: "a\n1\nn\n")

      expect(status.exitstatus).to eq(0), out
      expect(File.exist?(File.join(dir, "CLAUDE.md"))).to be(true), out
    end
  end
end
