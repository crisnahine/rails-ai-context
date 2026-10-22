# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Claude Code plugin" do
  let(:repo) { File.expand_path("..", __dir__) }
  let(:plugin) { File.join(repo, "plugins", "rails-ai-context") }
  let(:launcher) { File.join(plugin, "scripts", "serve.rb") }

  # A child that sees only the gems under gem_home, and no bundle of the suite's.
  def gemless(gem_home)
    { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home, "RUBYOPT" => nil, "RUBYLIB" => nil,
      "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "CLAUDE_PROJECT_DIR" => nil }
  end

  # Without gem_home, the suite's bundle, where this checkout is the installed gem.
  def launch(dir, gem_home: nil)
    Open3.capture2e(gem_home ? gemless(gem_home) : {}, Gem.ruby, launcher, chdir: dir, stdin_data: "")
  end

  it "names the install when the gem is missing for that Ruby" do
    Dir.mktmpdir do |dir|
      out, status = launch(dir, gem_home: dir)

      expect(status.exitstatus).to eq(1), out
      expect(out).to include("gem install rails-ai-context")
    end
  end

  it "relays why an installed copy cannot start, rather than calling it missing" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "specifications"))
      File.write(File.join(dir, "specifications", "rails-ai-context-9.9.9.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "rails-ai-context"
          s.version = "9.9.9"
          s.summary = "stub"
          s.authors = [ "stub" ]
          s.files = []
          s.executables = [ "rails-ai-context" ]
          s.add_dependency "no-such-dependency-anywhere"
        end
      RUBY
      out, status = launch(dir, gem_home: dir)

      expect(status.exitstatus).to eq(1), out
      expect(out).to include("no-such-dependency-anywhere")
      expect(out).not_to include("is not installed")
    end
  end

  # The binary's own advice there is --app-path, which the plugin's entry has no way to pass.
  it "names where to start Claude Code in a folder of apps" do
    Dir.mktmpdir do |dir|
      %w[shop admin].each do |name|
        FileUtils.mkdir_p(File.join(dir, name, "config"))
        File.write(File.join(dir, name, "config", "application.rb"), "")
      end
      out, status = launch(dir)

      expect(status.exitstatus).to eq(1), out
      expect(out).to include("holds 2 Rails apps").and include("admin").and include("shop")
    end
  end

  it "names where to start Claude Code in a folder with no app" do
    Dir.mktmpdir do |dir|
      out, status = launch(dir)

      expect(status.exitstatus).to eq(1), out
      expect(out).to include("no Rails app").and include("start Claude Code in a Rails app's folder")
      expect(out).not_to include("--app-path")
    end
  end

  # An app root with no app source: the gem's own binary is what refuses it.
  it "runs the installed gem's serve" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin", "rails"), %(ENGINE_PATH = "x"\n))
      out, status = launch(dir)

      expect(status.exitstatus).to eq(1), out
      expect(out).to include("No Rails app found in")
    end
  end

  it "lists the plugin in the marketplace under its own name" do
    marketplace = JSON.parse(File.read(File.join(repo, ".claude-plugin", "marketplace.json")))
    entry = marketplace["plugins"].find { |p| p["name"] == "rails-ai-context" }
    manifest = JSON.parse(File.read(File.join(repo, entry["source"], ".claude-plugin", "plugin.json")))

    expect(File.expand_path(entry["source"], repo)).to eq(plugin)
    expect(manifest["name"]).to eq(entry["name"])
  end

  it "starts the server through ruby and the launcher" do
    server = JSON.parse(File.read(File.join(plugin, ".mcp.json")))["mcpServers"]["rails-ai-context"]
    script = server["args"].first.sub("${CLAUDE_PLUGIN_ROOT}", plugin)

    expect(server["command"]).to eq("ruby")
    expect(server["args"].size).to eq(1)
    expect(script).to eq(launcher)
  end

  describe "the rules at session start" do
    let(:hook) { File.join(plugin, "scripts", "session_start.rb") }

    def session_start(dir)
      out, status = Open3.capture2e({ "CLAUDE_PROJECT_DIR" => nil }, Gem.ruby, hook, chdir: dir)
      [ out, status.exitstatus ]
    end

    def app(dir)
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "")
    end

    let(:rules) { Class.new { include RailsAiContext::Serializers::ToolGuideHelper }.new.tools_anti_hallucination_section.join("\n") }

    # The plugin writes no context file, so the hook gives the rules the generator puts in one, word for word.
    it "prints the rules the context files open with in an app, and from a folder inside it" do
      Dir.mktmpdir do |dir|
        app(dir)
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        out, status = session_start(File.join(dir, "app", "models"))

        expect(status).to eq(0), out
        expect(rules.scan(/^\d\. /).size).to eq(6)
        expect(out).to include(rules)
      end
    end

    it "names only tools the server has" do
      named = File.read(File.join(plugin, "rules.md")).scan(/\brails_\w+/).uniq

      expect(named).not_to be_empty
      expect(named - RailsAiContext::Server.builtin_tools.map(&:tool_name)).to eq([])
    end

    it "prints the rules at an engine's root, which boots through bin/rails, and nothing at a bin/rails alone" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "bin"))
        File.write(File.join(dir, "bin", "rails"), %(ENGINE_PATH = File.expand_path("../lib/shop/engine", __dir__)\n))
        # The server refuses a folder with no app source, so the rules would name absent tools.
        expect(session_start(dir).first).to eq("")

        FileUtils.mkdir_p(File.join(dir, "app", "models", "shop"))
        File.write(File.join(dir, "app", "models", "shop", "item.rb"), "module Shop; class Item; end; end\n")
        expect(session_start(dir).first).to include("Verify before you write")
      end
    end

    it "prints the rules above the one app a folder holds, and nothing above two" do
      Dir.mktmpdir do |dir|
        app(File.join(dir, "work", "shop"))
        expect(session_start(dir).first).to include("Verify before you write")

        app(File.join(dir, "admin"))
        expect(session_start(dir).first).to eq("")
      end
    end

    # The server would not serve the app a dependency folder holds, so the rules would name absent tools.
    it "prints nothing for an app inside node_modules, as the server finds none there" do
      Dir.mktmpdir do |dir|
        app(File.join(dir, "node_modules", "fixture"))

        expect(session_start(dir).first).to eq("")
      end
    end

    it "prints nothing without the gem, since there is no server to name" do
      Dir.mktmpdir do |dir|
        app(dir)
        out, status = Open3.capture2e(gemless(dir), Gem.ruby, hook, chdir: dir)

        expect([ status.exitstatus, out ]).to eq([ 0, "" ])
      end
    end

    it "prints nothing for an app whose config file or initializer turns the rules off" do
      Dir.mktmpdir do |dir|
        app(dir)
        File.write(File.join(dir, ".rails-ai-context.yml"), "anti_hallucination_rules: false\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        # The gem's own reader takes a symbol key too.
        File.write(File.join(dir, ".rails-ai-context.yml"), ":anti_hallucination_rules: false\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        FileUtils.rm(File.join(dir, ".rails-ai-context.yml"))
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        initializer = File.join(dir, "config", "initializers", "rails_ai_context.rb")
        File.write(initializer, "RailsAiContext.configure do |c|\n  # c.anti_hallucination_rules = false\nend\n")
        expect(session_start(dir).first).to include("Verify before you write")

        File.write(initializer, "RailsAiContext.configure do |c|\n  c.anti_hallucination_rules = false\nend\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        # The initializer runs after the config file, so its value wins.
        File.write(File.join(dir, ".rails-ai-context.yml"), "anti_hallucination_rules: false\n")
        File.write(initializer, "RailsAiContext.configure do |c|\n  c.anti_hallucination_rules = true\nend\n")
        expect(session_start(dir).first).to include("Verify before you write")
      end
    end

    # Claude Code reads a CLAUDE.md below the folder it started in only once a file there is read.
    it "prints the rules above an app below, even when that app's CLAUDE.md carries them" do
      Dir.mktmpdir do |dir|
        app(File.join(dir, "shop"))
        File.write(File.join(dir, "shop", "CLAUDE.md"), rules)

        expect(session_start(dir).first).to include(rules)
      end
    end

    it "prints the rules when the app's CLAUDE.md cannot be read" do
      skip "root reads every file" if Process.uid.zero?

      Dir.mktmpdir do |dir|
        app(dir)
        File.write(File.join(dir, "CLAUDE.md"), "")
        File.chmod(0o000, File.join(dir, "CLAUDE.md"))
        out, status = session_start(dir)

        expect(status).to eq(0), out
        expect(out).to include("Verify before you write")
      end
    end

    it "prints nothing outside a Rails app" do
      Dir.mktmpdir do |dir|
        expect(session_start(dir)).to eq([ "", 0 ])
      end
    end

    it "prints nothing where the app's own context files carry the rules" do
      Dir.mktmpdir do |dir|
        app(dir)
        File.write(File.join(dir, "CLAUDE.md"), rules)
        expect(session_start(dir)).to eq([ "", 0 ])
      end
    end

    it "is the plugin's SessionStart hook" do
      hooks = JSON.parse(File.read(File.join(plugin, "hooks", "hooks.json")))["hooks"]["SessionStart"]
      commands = hooks.flat_map { |group| group["hooks"] }.map { |h| [ h["command"], *h["args"] ] }

      # Shell form, which a Claude Code too old for exec form runs too; the
      # path is substituted before any shell, and quoted for the spaces in it.
      expect(commands).to eq([ [ %(ruby "${CLAUDE_PLUGIN_ROOT}/scripts/session_start.rb") ] ])
      # A resumed session holds the rules from its start already.
      expect(hooks.map { |group| group["matcher"] }).to eq([ "startup|clear|compact" ])
    end
  end
end
