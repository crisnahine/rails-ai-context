# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Claude Code plugin" do
  let(:repo) { File.expand_path("..", __dir__) }
  let(:plugin) { File.join(repo, "plugins", "rails-ai-context") }
  let(:floor) do
    require File.join(plugin, "scripts", "gem_requirement")
    Gem::Requirement.new(RailsAiContextPlugin::GEM_REQUIREMENT)
  end
  # The oldest release it accepts, as CI reads it: an upper bound may come first.
  let(:floor_version) { floor.requirements.find { |op, _| %w[>= ~> =].include?(op) }.last }

  # A child that sees only the gems under gem_home, and no bundle of the suite's.
  def gemless(gem_home)
    { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home, "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil,
      "BUNDLE_BIN_PATH" => nil, "BUNDLE_LOCKFILE" => nil, "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil, "CLAUDE_PROJECT_DIR" => nil }
  end

  # The server's own command line, as Claude Code runs it.
  def server_args = JSON.parse(File.read(File.join(plugin, ".mcp.json")))["mcpServers"]["rails-ai-context"]["args"]

  # What Claude Code sends first, one JSON-RPC message a line.
  def handshake(*more)
    [ { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } } },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "tools/list" }, *more ].map { |request| "#{request.is_a?(String) ? request : JSON.generate(request)}\n" }.join
  end

  # Without gem_home, the suite's bundle, where this checkout is the installed gem.
  def launch(dir, gem_home: nil, env: {}, stdin: handshake)
    Open3.popen3((gem_home ? gemless(gem_home) : {}).merge("CLAUDE_PLUGIN_ROOT" => plugin).merge(env), Gem.ruby, *server_args,
                 chdir: dir) do |input, output, errors, wait|
      err = Thread.new { errors.read }
      out = HeldInput.exchange(input, output, stdin.lines)
      [ out, err.value, wait.value ]
    end
  end

  # Where the gem cannot serve, the server still connects, with no tools, and gives its reason in one line:
  # on stderr for its log, and as the instructions the session reads. Stdout carries JSON-RPC alone.
  def refusal(dir, **options)
    out, err, status = launch(dir, **options)
    replies = out.lines.map { |line| JSON.parse(line) }
    reason = replies.first.dig("result", "instructions")

    expect(status.exitstatus).to eq(0), err
    expect(replies.map { |reply| reply["id"] }).to eq([ 1, 2 ])
    expect(replies.first["result"]).to include("protocolVersion" => "2025-06-18", "capabilities" => { "tools" => {} })
    expect(replies.last["result"]).to eq("tools" => [])
    expect(err).to eq("#{reason}\n")
    expect(reason).not_to include("\n")
    reason
  end

  def stub_spec(gem_home, version, bindir: "bin", dependency: nil, executables: [ "rails-ai-context" ])
    FileUtils.mkdir_p(File.join(gem_home, "specifications"))
    File.write(File.join(gem_home, "specifications", "rails-ai-context-#{version}.gemspec"), <<~RUBY)
      Gem::Specification.new do |s|
        s.name = "rails-ai-context"
        s.version = "#{version}"
        s.summary = "stub"
        s.authors = [ "stub" ]
        s.files = []
        s.bindir = "#{bindir}"
        s.executables = #{executables.inspect}
        #{%(s.add_dependency "#{dependency}") if dependency}
      end
    RUBY
  end

  # This checkout's lib and exe, installed under gem_home as `version` the way
  # RubyGems lays a gem out, with none of its dependencies.
  def install_checkout(gem_home, version, executables: [ "rails-ai-context" ])
    dir = File.join(gem_home, "gems", "rails-ai-context-#{version}")
    FileUtils.mkdir_p(dir)
    FileUtils.cp_r([ File.join(repo, "lib"), File.join(repo, "exe") ], dir)
    stub_spec(gem_home, version, bindir: "exe", executables: executables)
  end

  it "runs a gem this checkout's version satisfies" do
    expect(floor).to be_satisfied_by(Gem::Version.new(RailsAiContext::VERSION))
  end

  it "names in SETUP.md the allowlist entry that admits its server" do
    args = JSON.parse(File.read(File.join(plugin, ".mcp.json")))["mcpServers"]["rails-ai-context"]["args"]

    expect(File.read(File.join(repo, "docs", "SETUP.md"))).to include(JSON.generate("serverCommand" => [ "ruby", *args ]))
  end

  it "names in SETUP.md the version it needs" do
    expect(File.read(File.join(repo, "docs", "SETUP.md"))).to include("The plugin needs rails-ai-context #{floor_version} or later")
  end

  # Claude Code skips a plugin server that failed to start, in every folder, for some minutes after,
  # so a server that cannot serve here still connects and says why.
  it "answers a ping, and any other request with the reason, until its input ends" do
    Dir.mktmpdir do |dir|
      out, err, status = launch(dir, stdin: handshake({ jsonrpc: "2.0", id: 3, method: "ping" }, "not json",
                                                      { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "rails_get_schema" } }))
      replies = out.lines.map { |line| JSON.parse(line) }
      reason = "#{File.realpath(dir)} holds no Rails app. Start Claude Code in a Rails app's folder."

      expect([ err, status.exitstatus ]).to eq([ "#{reason}\n", 0 ])
      expect(replies[0]).to eq("jsonrpc" => "2.0", "id" => 1,
                               "result" => { "protocolVersion" => "2025-06-18", "capabilities" => { "tools" => {} },
                                             "serverInfo" => { "name" => "rails-ai-context", "version" => "0" }, "instructions" => reason })
      expect(replies.drop(1)).to eq([ { "jsonrpc" => "2.0", "id" => 2, "result" => { "tools" => [] } },
                                      { "jsonrpc" => "2.0", "id" => 3, "result" => {} },
                                      { "jsonrpc" => "2.0", "id" => 4, "error" => { "code" => -32_601, "message" => reason } } ])
    end
  end

  # Claude Code keeps the server's input open while it waits for the reply.
  it "answers initialize before its input ends" do
    Dir.mktmpdir do |dir|
      Open3.popen3({ "CLAUDE_PLUGIN_ROOT" => plugin }, Gem.ruby, *server_args, chdir: dir) do |stdin, stdout, _stderr, wait|
        stdin.write(handshake.lines.first)
        stdin.flush
        ready = IO.select([ stdout ], nil, nil, 10)
        reply = ready && JSON.parse(stdout.gets)
        stdin.close
        wait.value

        expect(reply).to include("id" => 1, "result" => include("instructions" => include("holds no Rails app")))
      end
    end
  end

  it "names the Ruby to start Claude Code with where the one on its PATH is too old" do
    Dir.mktmpdir do |dir|
      old = File.join(dir, "old_ruby.rb")
      File.write(old, %(Object.send(:remove_const, :RUBY_VERSION)\nRUBY_VERSION = "3.0.7"\n))

      expect(refusal(dir, env: { "RUBYOPT" => "-r#{old}" })).to include("needs Ruby 3.1 or later").and include("is 3.0.7")
    end
  end

  # A gem path a newer Ruby filled may hold a json the old Ruby cannot load.
  it "answers with the Ruby's own json where a newer one is installed" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p([ File.join(dir, "specifications"), File.join(dir, "gems", "json-99.0.0", "lib") ])
      File.write(File.join(dir, "specifications", "json-99.0.0.gemspec"),
                 %(Gem::Specification.new { |s| s.name = "json"; s.version = "99.0.0"; s.summary = "x"; s.authors = [ "x" ]; s.files = [] }\n))
      File.write(File.join(dir, "gems", "json-99.0.0", "lib", "json.rb"), %(raise SyntaxError, "unexpected ..."\n))
      old = File.join(dir, "old_ruby.rb")
      File.write(old, %(Object.send(:remove_const, :RUBY_VERSION)\nRUBY_VERSION = "2.6.10"\n))

      expect(refusal(dir, gem_home: dir, env: { "RUBYOPT" => "-r#{old}" })).to include("is 2.6.10")
    end
  end

  it "names the install, the Ruby and the folder that picked it, when the gem is missing for that Ruby" do
    Dir.mktmpdir do |dir|
      reason = refusal(dir, gem_home: dir)

      expect(reason).to include("gem install rails-ai-context").and include("Ruby #{RUBY_VERSION}").and include(File.realpath(dir))
      expect(reason).to include("vendor/bundle")
    end
  end

  it "names the update when the installed gem is older than the plugin needs" do
    Dir.mktmpdir do |dir|
      install_checkout(dir, "5.0.0")

      expect(refusal(dir, gem_home: dir)).to include("rails-ai-context 5.0.0").and include("gem update rails-ai-context")
    end
  end

  # RubyGems' own message runs to two lines, and the MCP log shows one line per entry.
  it "relays why an installed copy cannot start, in one line, rather than calling it missing" do
    Dir.mktmpdir do |dir|
      stub_spec(dir, "9.9.9", dependency: "no-such-dependency-anywhere")
      reason = refusal(dir, gem_home: dir)

      expect(reason).to include("no-such-dependency-anywhere")
      expect(reason).not_to include("is not installed")
    end
  end

  # Ruby 3.1's error_highlight writes its snippet into a NameError's message itself.
  it "relays a NameError raised while activating the gem in one line" do
    Dir.mktmpdir do |dir|
      stub_spec(dir, "9.9.9")
      broken = File.join(dir, "broken.rb")
      File.write(broken, "module Gem\n  def self.activate_bin_path(*)\n    nil.request\n  end\nend\n")
      reason = refusal(dir, gem_home: dir, env: { "RUBYOPT" => "-r#{broken}" })

      expect(reason).to include("cannot start under").and include("undefined method")
      expect(reason).not_to include("nil.request")
    end
  end

  # A C locale tags the folder's name binary, and json 3 refuses to write such a string.
  it "refuses in a folder named outside ASCII under a C locale" do
    Dir.mktmpdir do |gems|
      Dir.mktmpdir do |base|
        install_checkout(gems, RailsAiContext::VERSION)
        dir = File.join(base, "café").tap { |path| FileUtils.mkdir_p(path) }
        out, err, status = launch(dir, gem_home: gems, env: { "LANG" => "C", "LC_ALL" => nil, "LC_CTYPE" => nil })

        expect(status.exitstatus).to eq(0), err
        expect(err).not_to include("JSON.generate")
        expect(JSON.parse(out.lines.first).dig("result", "instructions")).to include("café")
      end
    end
  end

  describe "its own refusal under a C locale" do
    # The line comes in tagged US-ASCII, which json refuses to parse once a byte is outside ASCII.
    it "answers a request line outside ASCII" do
      Dir.mktmpdir do |dir|
        hello = handshake.sub('"name":"spec"', %("name":"caf\u00e9"))
        out, err, status = launch(dir, gem_home: dir, env: { "LANG" => "C", "LC_ALL" => "C", "LC_CTYPE" => nil }, stdin: hello)

        expect(status.exitstatus).to eq(0), err
        expect(out.lines.map { |line| JSON.parse(line)["id"] }).to eq([ 1, 2 ])
      end
    end
  end

  # bundler/setup from the environment Claude Code started in leaves only that
  # bundle's gems, so the installed one is out of reach whatever is installed.
  it "names the bundle Claude Code inherited when it lacks the gem, without a backtrace" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), %(source "https://rubygems.org"\n))
      reason = refusal(dir, env: { "BUNDLE_GEMFILE" => File.join(dir, "Gemfile"), "RUBYOPT" => "-rbundler/setup", "BUNDLE_BIN_PATH" => nil,
                                   "BUNDLE_LOCKFILE" => nil, "BUNDLE_FROZEN" => nil, "BUNDLE_DEPLOYMENT" => nil })

      expect(reason).to match(/bundle of \S*Gemfile/).and include("bundle exec")
      expect(reason).not_to include("is not installed")
    end
  end

  # A checkout of this gem that calls itself release 5.0.0, as a bundle would lock it.
  def old_copy(dir)
    File.join(dir, "old").tap do |old|
      FileUtils.mkdir_p(old)
      FileUtils.cp_r([ File.join(repo, "lib"), File.join(repo, "exe") ], old)
      File.write(File.join(old, "rails-ai-context.gemspec"),
                 %(Gem::Specification.new { |s| s.name = "rails-ai-context"; s.version = "5.0.0"; s.summary = "x"; s.authors = [ "x" ]; ) +
                 %(s.files = []; s.bindir = "exe"; s.executables = [ "rails-ai-context" ] }\n))
    end
  end

  def lock_old_copy(folder, old)
    gemfile = File.join(folder, "Gemfile")
    FileUtils.mkdir_p(File.join(folder, "config"))
    File.write(File.join(folder, "config", "application.rb"), "")
    File.write(gemfile, %(gem "rails-ai-context", path: #{old.inspect}\n))
    File.write("#{gemfile}.lock", "PATH\n  remote: #{old}\n  specs:\n    rails-ai-context (5.0.0)\n\nPLATFORMS\n  ruby\n\n" \
                                  "DEPENDENCIES\n  rails-ai-context!\n")
    gemfile
  end

  # Bundler's activate_bin_path takes no requirement, so the bundle's older copy would start, or crash on a file it lacks.
  it "names the bundle Claude Code inherited when it locks an older copy, and the hook gives no rules" do
    Dir.mktmpdir do |dir|
      gemfile = lock_old_copy(File.join(dir, "bundle"), old_copy(dir))
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "config"))
      File.write(File.join(app, "config", "application.rb"), "")
      env = { "BUNDLE_GEMFILE" => gemfile, "RUBYOPT" => "-rbundler/setup", "BUNDLE_BIN_PATH" => nil, "BUNDLE_LOCKFILE" => nil,
              "BUNDLE_FROZEN" => nil, "BUNDLE_DEPLOYMENT" => nil, "CLAUDE_PROJECT_DIR" => nil, "CLAUDE_CONFIG_DIR" => nil }

      expect(refusal(app, env: env)).to include("bundle of #{gemfile}").and include("rails-ai-context 5.0.0").and include(floor.to_s)
      out, status = Open3.capture2e(env, Gem.ruby, File.join(plugin, "scripts", "session_start.rb"), chdir: app)
      expect([ out, status.exitstatus ]).to eq([ "", 0 ])
    end
  end

  # Each app's own bundle decides the copy that serves it, as for a single app.
  it "gives no rules above several apps whose bundles lock an older copy, and the rules where one does not" do
    Dir.mktmpdir do |dir|
      gems = File.join(dir, "gems")
      install_checkout(gems, RailsAiContext::VERSION)
      env = gemless(gems).merge("CLAUDE_CONFIG_DIR" => nil)
      old = old_copy(dir)
      lock_old_copy(File.join(dir, "apps", "alpha"), old)
      lock_old_copy(File.join(dir, "apps", "beta"), old)
      script = File.join(plugin, "scripts", "session_start.rb")

      out, status = Open3.capture2e(env, Gem.ruby, script, chdir: File.join(dir, "apps"))
      expect([ out, status.exitstatus ]).to eq([ "", 0 ])

      FileUtils.mkdir_p(File.join(dir, "apps", "gamma", "config"))
      File.write(File.join(dir, "apps", "gamma", "config", "application.rb"), "")
      out, = Open3.capture2e(env, Gem.ruby, script, chdir: File.join(dir, "apps"))
      expect(out).to include("Verify Before You Write").and include("alpha (served by its own bundled copy), beta (served by its own bundled copy), gamma. ")
    end
  end

  # A gem with no router serves one app; the plugin's entry has no way to pass the --app-path the binary asks for.
  it "names where to start Claude Code in a folder of apps, by their paths from there, on a gem that serves one app" do
    Dir.mktmpdir do |gems|
      Dir.mktmpdir do |dir|
        install_checkout(gems, RailsAiContext::VERSION)
        FileUtils.rm(Dir.glob(File.join(gems, "gems", "*", "lib", "rails_ai_context", "{cli/refusal,workspace_server}.rb")))
        %w[shop/web admin/web].each do |name|
          FileUtils.mkdir_p(File.join(dir, name, "config"))
          File.write(File.join(dir, name, "config", "application.rb"), "")
        end
        reason = refusal(dir, gem_home: gems)

        expect(reason).to include("holds 2 Rails apps (admin/web, shop/web)").and include("start Claude Code in one of them")
        # The model can still run each app's tools now, as commands.
        expect(reason).to include("Until then, each app's tools run as `rails-ai-context --app-path <app> tool <name>`, with <app> one of: admin/web, shop/web.")
        expect(reason).to include("`claude plugin disable rails-ai-context@rails-ai-context --scope project` run here, or with `--scope local` " \
                                  "where a --scope local install turns it on. On macOS and Linux, a local setting at the root of a git " \
                                  "repository the apps share reaches them too.")
      end
    end
  end

  it "serves a folder of apps through one server, each tool taking the app" do
    skip "on Windows the plugin serves one app per session" if Gem.win_platform?

    Dir.mktmpdir do |dir|
      %w[shop/web admin/web].each do |name|
        FileUtils.cp_r(File.join(repo, "spec", "fixtures", "static_app"), File.join(dir, name).tap { |path| FileUtils.mkdir_p(File.dirname(path)) })
      end
      call = { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "rails_get_schema", arguments: { app: "shop-web", detail: "summary" } } }
      out, err, status = launch(dir, stdin: handshake(call))
      replies = out.lines.map { |line| JSON.parse(line) }.to_h { |reply| [ reply["id"], reply ] }

      expect(status.exitstatus).to eq(0), err
      expect(replies[1].dig("result", "instructions")).to include("admin-web (admin/web/), shop-web (shop/web/)")
      tools = replies[2].dig("result", "tools")
      expect(tools.size).to be > 20
      expect(tools.map { |tool| tool.dig("inputSchema", "properties", "app", "enum") }.uniq).to eq([ %w[admin-web shop-web] ])
      expect(tools.map { |tool| tool.dig("inputSchema", "required") }).to all(include("app"))
      expect(replies[3]["result"]).to include("isError" => false).or(satisfy { |result| !result.key?("isError") })
      expect(replies[3].dig("result", "content", 0, "text")).to include("users"), err
    end
  end

  it "refuses a folder of apps on Windows, naming each app and the command that runs its tools" do
    Dir.mktmpdir do |dir|
      %w[shop/web admin/web].each do |name|
        FileUtils.mkdir_p(File.join(dir, name, "config"))
        File.write(File.join(dir, name, "config", "application.rb"), "")
      end
      windows = File.join(dir, "windows.rb")
      File.write(windows, "def Gem.win_platform?\n  true\nend\n")
      reason = refusal(dir, env: { "RUBYOPT" => "-r#{windows}" })

      expect(reason).to include("holds 2 Rails apps (admin/web, shop/web), and on Windows the plugin serves one app per session")
        .and include("each app's tools run as `rails-ai-context --app-path <app> tool <name>`, with <app> one of: admin/web, shop/web.")
    end
  end

  it "names where to start Claude Code in a folder with no app" do
    Dir.mktmpdir do |dir|
      reason = refusal(dir)

      expect(reason).to include("no Rails app").and include("Start Claude Code in a Rails app's folder")
      expect(reason).not_to include("--app-path")
    end
  end

  # What the gem's own binary refuses, it refuses by the same handshake, whatever it printed on the way.
  def gem_refusal(dir, **options)
    out, err, status = launch(dir, **options)
    replies = out.lines.map { |line| JSON.parse(line) }

    expect(status.exitstatus).to eq(0), err
    expect(replies.map { |reply| reply["id"] }).to eq([ 1, 2 ]), err
    expect(replies.last["result"]).to eq("tools" => [])
    replies.first.dig("result", "instructions")
  end

  it "refuses by handshake a root whose bin/rails boots an engine that has no app source" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p([ File.join(dir, "bin"), File.join(dir, "lib"), File.join(dir, "app", "assets") ])
      File.write(File.join(dir, "bin", "rails"), %(ENGINE_PATH = File.expand_path("../lib/eng/engine", __dir__)\n))
      File.write(File.join(dir, "lib", "eng.rb"), "module Eng; end\n")

      expect(gem_refusal(dir)).to eq("#{File.realpath(dir)} has a bin/rails but no app source: no config/application.rb, " \
                                     "config/environment.rb or app/**/*.rb. Start Claude Code in a Rails app's folder.")
    end
  end

  it "serves the app a monorepo root's bin/rails boots" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p([ File.join(dir, "bin"), File.join(dir, "apps") ])
      FileUtils.cp_r(File.join(repo, "spec", "fixtures", "static_app"), File.join(dir, "apps", "web"))
      File.write(File.join(dir, "bin", "rails"), %(APP_PATH = File.expand_path("../apps/web/config/application", __dir__)\nrequire "rails/commands"\n))
      out, err, status = launch(dir)
      listed = out.lines.map { |line| JSON.parse(line) }.find { |reply| reply["id"] == 2 }

      expect(status.exitstatus).to eq(0), err
      expect(listed.dig("result", "tools").size).to be > 20
      expect(err).to include("using app at apps/web/")
    end
  end

  # The static tier refuses a skip_tools it cannot read without the boot that failed.
  it "refuses by handshake an app the gem cannot serve once it has started" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p([ File.join(dir, "config", "initializers"), File.join(dir, "app", "models") ])
      File.write(File.join(dir, "config", "application.rb"), "")
      File.write(File.join(dir, "config", "environment.rb"), "raise 'the app does not boot here'\n")
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget; end\n")
      File.write(File.join(dir, "config", "initializers", "rails_ai_context.rb"),
                 "RailsAiContext.configure do |config|\n  config.skip_tools = ENV.fetch('SKIPPED', '').split(',')\nend\n")

      expect(gem_refusal(dir)).to include("the app does not boot here").and include("skip_tools")
    end
  end

  it "lists the plugin in the marketplace under its own name" do
    marketplace = JSON.parse(File.read(File.join(repo, ".claude-plugin", "marketplace.json")))
    entry = marketplace["plugins"].find { |p| p["name"] == "rails-ai-context" }
    manifest = JSON.parse(File.read(File.join(repo, entry["source"], ".claude-plugin", "plugin.json")))

    expect(File.expand_path(entry["source"], repo)).to eq(plugin)
    expect(manifest["name"]).to eq(entry["name"])
  end

  # An allowlist admits a plugin's server by its exact command line, which
  # names no versioned folder here, so one entry lasts across updates. `-e`
  # ends rbenv's search of ruby's arguments for a script, whose folder, the
  # plugin's, would otherwise pick the Ruby instead of the session's folder.
  it "starts the server through ruby and the launcher, by a command line no update changes" do
    server = JSON.parse(File.read(File.join(plugin, ".mcp.json")))["mcpServers"]["rails-ai-context"]

    expect(server).to eq("command" => "ruby", "args" => [ "-e", "load File.join(ENV.fetch('CLAUDE_PLUGIN_ROOT'), 'scripts', 'serve.rb')" ])
    Dir.mktmpdir do |dir|
      expect(refusal(dir)).to eq("#{File.realpath(dir)} holds no Rails app. Start Claude Code in a Rails app's folder.")
    end
  end

  # CI installs the release the plugin's requirement names from RubyGems and
  # sets PLUGIN_FLOOR_GEM_HOME: the plugin ships from main to users who may
  # have no newer gem, so its scripts and rules have to hold against that one.
  describe "on the oldest release it accepts", if: ENV["PLUGIN_FLOOR_GEM_HOME"] do
    let(:gems) { ENV.fetch("PLUGIN_FLOOR_GEM_HOME") }
    let(:hook) { File.join(plugin, "scripts", "session_start.rb") }

    def app(dir)
      FileUtils.mkdir_p([ File.join(dir, "config"), File.join(dir, "app", "models") ])
      File.write(File.join(dir, "config", "application.rb"), "")
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget; end\n")
    end

    it "is the release the requirement names" do
      versions = Dir.glob("rails-ai-context-*.gemspec", base: File.join(gems, "specifications"))
                    .map { |name| Gem::Version.new(File.basename(name, ".gemspec").delete_prefix("rails-ai-context-")) }

      expect(versions).to eq([ floor_version ])
    end

    it "prints the rules in an app and from a folder inside it, and above two apps with the --app-path form" do
      Dir.mktmpdir do |dir|
        app(File.join(dir, "shop"))
        hook_in = ->(folder) { Open3.capture2e(gemless(gems), Gem.ruby, hook, chdir: folder).first }

        expect(hook_in.(File.join(dir, "shop"))).to include("Verify before you write")
        expect(hook_in.(File.join(dir, "shop", "app", "models"))).to include("Verify before you write")

        app(File.join(dir, "admin"))
        expect(hook_in.(dir)).to include("Verify before you write").and include("`rails-ai-context --app-path <app> tool <name>`")
      end
    end

    # A release without the gem's settings reader reads the switch and skip_tools the hook's own way.
    it "reads the app's settings without the gem's reader" do
      Dir.mktmpdir do |dir|
        app(dir)
        hook_in = -> { Open3.capture2e(gemless(gems), Gem.ruby, hook, chdir: dir).first }
        File.write(File.join(dir, ".rails-ai-context.yml"), "skip_tools: [rails_get_gems]\n")
        expect(hook_in.()).to include(%(Check `rails_get_config(section:"conventions")` BEFORE))

        File.write(File.join(dir, ".rails-ai-context.yml"), "anti_hallucination_rules: false\n")
        expect(hook_in.()).to eq("")
      end
    end

    it "names where to start Claude Code in a folder of two apps" do
      Dir.mktmpdir do |dir|
        app(File.join(dir, "shop", "web"))
        app(File.join(dir, "admin", "web"))
        expect(refusal(dir, gem_home: gems)).to include("holds 2 Rails apps (admin/web, shop/web)")
      end
    end

    # The binary hands an app to its own bundle; a RUBYGEMS_GEMDEPS the shell set would only refuse the gem.
    it "serves the app with the installed gem whatever RUBYGEMS_GEMDEPS names" do
      Dir.mktmpdir do |own|
        Dir.mktmpdir do |dir|
          install_checkout(own, RailsAiContext::VERSION)
          app(dir)
          File.write(File.join(dir, "Gemfile"), %(source "https://rubygems.org"\n))
          out, err, status = launch(dir, gem_home: own, env: { "GEM_PATH" => [ own, gems ].join(File::PATH_SEPARATOR),
                                                                "RUBYGEMS_GEMDEPS" => File.join(dir, "Gemfile") })
          replies = out.lines.map { |line| JSON.parse(line) }.to_h { |reply| [ reply["id"], reply ] }

          expect(status.exitstatus).to eq(0), err
          expect(replies[1].dig("result", "serverInfo", "version")).to eq(RailsAiContext::VERSION)
          expect(replies[2].dig("result", "tools").map { |tool| tool["name"] }).to include("rails_get_schema")
        end
      end
    end

    # The app's bundle has its own copy, a release older than the refusal, which exits where it cannot serve.
    def bundled_copy_session(body, *more)
      with_bundled_copy(body) do |dir, env|
        out, err, status = launch(dir, gem_home: env["GEM_HOME"], env: env, stdin: handshake(*more))

        expect(status.exitstatus).to eq(0), err
        expect(err).to include("This app's bundle has rails-ai-context 5.0.0")
        return out.lines.map { |line| JSON.parse(line) }.to_h { |reply| [ reply["id"], reply ] }
      end
    end

    def with_bundled_copy(body)
      Dir.mktmpdir do |own|
        Dir.mktmpdir do |dir|
          install_checkout(own, RailsAiContext::VERSION)
          app(dir)
          vendored = File.join(dir, "vendored")
          FileUtils.mkdir_p(File.join(vendored, "exe"))
          File.write(File.join(vendored, "rails-ai-context.gemspec"),
                     %(Gem::Specification.new { |s| s.name = "rails-ai-context"; s.version = "5.0.0"; s.summary = "x"; s.authors = [ "x" ]; ) +
                     %(s.files = []; s.bindir = "exe"; s.executables = [ "rails-ai-context" ] }\n))
          File.write(File.join(vendored, "exe", "rails-ai-context"), body)
          File.write(File.join(dir, "Gemfile"), %(gem "rails-ai-context", path: "vendored"\n))
          File.write(File.join(dir, "Gemfile.lock"), "PATH\n  remote: vendored\n  specs:\n    rails-ai-context (5.0.0)\n\nPLATFORMS\n  ruby\n\n" \
                                                     "DEPENDENCIES\n  rails-ai-context!\n")
          yield dir, { "GEM_HOME" => own, "GEM_PATH" => [ own, gems ].join(File::PATH_SEPARATOR) }
        end
      end
    end

    it "exits 0 where the client left while the app's bundled copy stopped, and serves nothing of its own" do
      with_bundled_copy(%(warn "this copy cannot boot the app"\nexit 1\n)) do |dir, env|
        stdin, stdout, stderr, wait = Open3.popen3(gemless(env["GEM_HOME"]).merge(env, "CLAUDE_PLUGIN_ROOT" => plugin), Gem.ruby, *server_args, chdir: dir)
        stdout.close
        said = []
        log = Thread.new { stderr.each_line { |line| said << line } }
        Timeout.timeout(60) { sleep 0.1 until said.join.include?("this copy cannot boot the app") }
        sleep 1
        stdin.puts handshake
        stdin.close
        status = Timeout.timeout(60) { wait.value }
        log.join

        expect(status.exitstatus).to eq(0), said.join
        expect(said).to eq([ "[rails-ai-context] This app's bundle has rails-ai-context 5.0.0; running that copy, as bundle exec does.\n",
                             "this copy cannot boot the app\n" ])
      end
    end

    it "keeps the session where the app's bundled copy exits before it answers" do
      replies = bundled_copy_session(%(warn "this copy cannot boot the app"\nexit 1\n))

      expect(replies[1].dig("result", "instructions")).to eq("rails-ai-context 5.0.0 from this app's bundle could not start: this copy cannot boot the app")
      expect(replies[2]["result"]).to eq("tools" => [])
    end

    it "answers with the reason where the app's bundled copy stops after it answered" do
      body = <<~RUBY
        require "json"
        $stdout.sync = true
        $stdin.each_line do |line|
          asked = JSON.parse(line)
          next unless asked["id"]
          abort "this copy lost its database" unless asked["method"] == "initialize"

          puts JSON.generate(jsonrpc: "2.0", id: asked["id"], result: { protocolVersion: "2025-06-18", capabilities: { tools: {} },
                                                                        serverInfo: { name: "rails-ai-context", version: "5.0.0" } })
        end
      RUBY
      replies = bundled_copy_session(body, { jsonrpc: "2.0", id: 3, method: "ping" })

      expect(replies[1].dig("result", "serverInfo", "version")).to eq("5.0.0")
      [ 2, 3 ].each do |id|
        expect(replies[id]["error"]).to eq("code" => -32_603, "message" => "rails-ai-context 5.0.0 from this app's bundle stopped: this copy lost its database")
      end
    end

    # What Claude Code sees: the tools the server lists, with the parameters each takes.
    it "serves every tool rules.md names, with the parameters it names" do
      Dir.mktmpdir do |dir|
        app(dir)
        requests = [
          { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "spec", version: "1" } } },
          { jsonrpc: "2.0", method: "notifications/initialized" },
          { jsonrpc: "2.0", id: 2, method: "tools/list" }
        ]
        out, err, = Open3.capture3(gemless(gems).merge("CLAUDE_PLUGIN_ROOT" => plugin), Gem.ruby, *server_args, chdir: dir,
                                   stdin_data: requests.map { |request| "#{JSON.generate(request)}\n" }.join)
        replies = out.lines.filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
        listed = replies.find { |reply| reply["id"] == 2 }
        expect(listed).not_to be_nil, err
        tools = listed.dig("result", "tools").to_h { |tool| [ tool["name"], tool.dig("inputSchema", "properties").to_h.keys ] }

        text = File.read(File.join(plugin, "rules.md"))
        expect(text.scan(/\brails_\w+/).uniq - tools.keys).to eq([])
        text.scan(/\b(rails_\w+)\((\w+):/).uniq.each { |tool, param| expect(tools.fetch(tool)).to include(param) }
      end
    end
  end

  describe "the rules at session start" do
    let(:hook) { File.join(plugin, "scripts", "session_start.rb") }

    def session_start(dir, env: {})
      out, status = Open3.capture2e({ "CLAUDE_PROJECT_DIR" => nil, "CLAUDE_CONFIG_DIR" => nil, "RAILS_ENV" => nil, "RACK_ENV" => nil }.merge(env),
                                    Gem.ruby, hook, chdir: dir)
      [ out, status.exitstatus ]
    end

    def app(dir)
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "")
    end

    def write(path, text)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, text)
    end

    def rendered(skip_tools = [])
      config = RailsAiContext.configuration
      saved = config.skip_tools
      config.skip_tools = skip_tools
      Class.new { include RailsAiContext::Serializers::ToolGuideHelper }.new.tools_anti_hallucination_section.join("\n")
    ensure
      config.skip_tools = saved
    end

    let(:rules) { rendered }

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

    it "names only tools the server has, with parameters they take" do
      text = File.read(File.join(plugin, "rules.md"))
      tools = RailsAiContext::Server.builtin_tools.to_h { |tool| [ tool.tool_name, tool ] }
      named = text.scan(/\brails_\w+/).uniq
      params = text.scan(/\b(rails_\w+)\((\w+):/).uniq

      expect(named).not_to be_empty
      expect(named - tools.keys).to eq([])
      expect(params).not_to be_empty
      params.each do |tool, param|
        expect(tools.fetch(tool).input_schema.to_h[:properties].keys.map(&:to_s)).to include(param)
      end
    end

    # As the generator writes rule 3, it names a rails_get_config section only where skip_tools leaves it on.
    it "leaves out of rule 3 the sections the app turned off" do
      Dir.mktmpdir do |dir|
        app(dir)
        write(File.join(dir, ".rails-ai-context.yml"), "skip_tools:\n  - rails_get_conventions\n")
        expect(session_start(dir).first).to include(rendered(%w[rails_get_conventions]))

        write(File.join(dir, ".rails-ai-context.yml"), "skip_tools:\n  - rails_get_conventions\n  - rails_get_gems\n")
        expect(session_start(dir).first).to include(rendered(%w[rails_get_conventions rails_get_gems]))

        # An initializer's literal joins the file's list, as at boot, in any list form the setter takes.
        write(File.join(dir, ".rails-ai-context.yml"), "skip_tools: []\n")
        { "%w[rails_get_gems]" => %w[rails_get_gems], "%i[rails_get_conventions]" => %w[rails_get_conventions],
          "%w(rails_get_gems)" => %w[rails_get_gems], "[ :rails_get_gems, \"rails_get_conventions\" ]" => %w[rails_get_gems rails_get_conventions] }.each do |list, tools|
          write(File.join(dir, "config", "initializers", "rails_ai_context.rb"),
                "RailsAiContext.configure do |config|\n  config.skip_tools = #{list}\nend\n")
          expect(session_start(dir).first).to include(rendered(tools)), list
        end
      end
    end

    # The gem's own reader answers, so a list built from literals reads as the server reads it.
    it "leaves out of rule 3 the sections a list of literals joined together turns off" do
      Dir.mktmpdir do |dir|
        app(dir)
        write(File.join(dir, "config", "initializers", "rails_ai_context.rb"),
              "RailsAiContext.configure do |config|\n  config.skip_tools = %w[rails_get_gems] + %w[rails_get_conventions]\nend\n")

        expect(session_start(dir).first).to include(rendered(%w[rails_get_gems rails_get_conventions]))
      end
    end

    # A line the reader cannot follow keeps the literals of the lists it does not touch, and rule 3 never names a
    # section skip_tools may turn off.
    it "leaves out of rule 3 every section whose skip_tools it cannot read, and keeps the literals beside another refused list" do
      Dir.mktmpdir do |dir|
        app(dir)
        initializer = File.join(dir, "config", "initializers", "rails_ai_context.rb")
        write(initializer, "RailsAiContext.configure do |config|\n  config.skip_tools = %w[rails_get_gems]\n" \
                           "  config.sensitive_patterns += ENV.fetch(\"KEYS\").split\nend\n")
        expect(session_start(dir).first).to include(rendered(%w[rails_get_gems]))

        write(initializer, "RailsAiContext.configure do |config|\n  config.skip_tools += ENV.fetch(\"SKIP\").split\nend\n")
        expect(session_start(dir).first).to include(rendered(%w[rails_get_conventions rails_get_gems]))
      end
    end

    it "says which line of the app's settings it could not follow, and what answers instead" do
      Dir.mktmpdir do |dir|
        app(dir)
        write(File.join(dir, "config", "initializers", "rails_ai_context.rb"), "RailsAiContext.configure do |config|\n  config.ai_tools = %i[codex]\n  tools = config.ai_tools\n  tools << :copilot\nend\n")
        out, status = session_start(dir)

        expect(status).to eq(0), out
        expect(out).to include(rules).and include("[rails-ai-context] config/initializers/rails_ai_context.rb:3: `ai_tools` is changed in place or written by its name, so the YAML or the default answers here")
      end
    end

    it "keeps what the gem prints as it loads off the session" do
      Dir.mktmpdir do |dir|
        app(dir)
        plant = File.realpath(File.join(dir, "config"))
        write(File.join(plant, "rails_ai_context.rb"), "warn \"planted load-time warning\"\n$LOAD_PATH.delete(__dir__)\nrequire \"rails_ai_context\"\n")
        out, status = session_start(dir, env: { "RUBYOPT" => "#{ENV.fetch('RUBYOPT', '')} -I#{plant}" })

        expect(status).to eq(0), out
        expect(out).to include(rules)
        expect(out).not_to include("planted load-time warning")
      end
    end

    it "leaves out of rule 3 a section the app turns off by appending to skip_tools" do
      Dir.mktmpdir do |dir|
        app(dir)
        write(File.join(dir, ".rails-ai-context.yml"), "skip_tools:\n  - rails_get_conventions\n")
        { %(config.skip_tools << "rails_get_gems") => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools += %w[rails_get_gems]" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools.push(\"rails_get_gems\")" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools.concat(%w(rails_get_gems))" => %w[rails_get_conventions rails_get_gems],
          # Assigning after the file loads keeps the file's entries too.
          "config.skip_tools = []\n  config.skip_tools.append 'rails_get_gems'" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools = []\n  config.skip_tools.push \"rails_get_gems\", 'rails_get_conventions'" => %w[rails_get_gems rails_get_conventions],
          "config.skip_tools = []\n  config.skip_tools.concat %w[rails_get_gems], ['rails_get_conventions']" => %w[rails_get_gems rails_get_conventions],
          "config.skip_tools = []\n  config.skip_tools << \"rails_get_gems\" << 'rails_get_conventions'" => %w[rails_get_gems rails_get_conventions],
          "config.skip_tools += [ :rails_get_gems ]" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools += %i[rails_get_gems]" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools |= %w[rails_get_gems]" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools |= [ :rails_get_gems ]" => %w[rails_get_conventions rails_get_gems],
          # The other forms append a symbol as it is, which a booted server never matches; the
          # static tier turns the tool off, the stricter answer, and so do the rules.
          "config.skip_tools.push(:rails_get_gems)" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools << :rails_get_gems" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools.concat(%i[rails_get_gems])" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools.append :rails_get_gems, \"x\"" => %w[rails_get_conventions rails_get_gems] }.each do |code, tools|
          write(File.join(dir, "config", "initializers", "rails_ai_context.rb"), "RailsAiContext.configure do |config|\n  #{code}\nend\n")
          expect(session_start(dir).first).to include(rendered(tools)), code
        end
      end
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

    it "prints the rules above the one app a folder holds, and above several with a line naming the app argument" do
      Dir.mktmpdir do |dir|
        app(File.join(dir, "work", "shop"))
        expect(session_start(dir).first).to include("Verify before you write")

        app(File.join(dir, "admin"))
        out, status = session_start(dir)
        expect(status).to eq(0)
        expect(out).to start_with(File.read(File.join(plugin, "rules.md")))
        expect(out).to end_with("This session's folder holds several Rails apps: admin, shop. Every rails_* tool takes `app`, " \
                                "one of those names, for the app to answer about.\n")
      end
    end

    it "names the --app-path form above several apps where the installed gem serves one app" do
      Dir.mktmpdir do |gems|
        Dir.mktmpdir do |dir|
          install_checkout(gems, RailsAiContext::VERSION)
          FileUtils.rm(Dir.glob(File.join(gems, "gems", "*", "lib", "rails_ai_context", "{cli/refusal,workspace_server}.rb")))
          app(File.join(dir, "work", "shop"))
          app(File.join(dir, "admin"))
          out, = session_start(dir, env: gemless(gems))

          expect(out).to start_with(File.read(File.join(plugin, "rules.md")))
          expect(out).to end_with("This session's folder holds several Rails apps, and the plugin's server serves none of them here: " \
                                  "run each app's tools as `rails-ai-context --app-path <app> tool <name>` from #{File.realpath(dir)}, " \
                                  "with <app> one of: admin, work/shop.\n")
        end
      end
    end

    it "names the --app-path form above several apps on Windows, where the server serves one app per session" do
      Dir.mktmpdir do |dir|
        app(File.join(dir, "work", "shop"))
        app(File.join(dir, "admin"))
        windows = File.join(dir, "windows.rb")
        File.write(windows, "def Gem.win_platform?\n  true\nend\n")
        out, = session_start(dir, env: { "RUBYOPT" => "-r#{windows}" })

        expect(out).to end_with("This session's folder holds several Rails apps, and the plugin's server serves none of them here: " \
                                "run each app's tools as `rails-ai-context --app-path <app> tool <name>` from #{File.realpath(dir)}, " \
                                "with <app> one of: admin, work/shop.\n")
      end
    end

    it "prints nothing above several apps where a memory on the way up carries the rules" do
      Dir.mktmpdir do |dir|
        app(File.join(dir, "shop"))
        app(File.join(dir, "admin"))
        write(File.join(dir, "CLAUDE.md"), "## Anti-Hallucination Protocol\n")
        expect(session_start(dir).first).to eq("")
      end
    end

    describe "above several apps, each with its own settings" do
      def apps(dir, *settings)
        %w[alpha beta].zip(settings).each do |name, yaml|
          app(File.join(dir, name))
          write(File.join(dir, name, ".rails-ai-context.yml"), yaml) if yaml
        end
      end

      it "prints nothing where every app turns the rules off" do
        Dir.mktmpdir do |dir|
          apps(dir, "anti_hallucination_rules: false\n", "anti_hallucination_rules: false\n")
          expect(session_start(dir)).to eq([ "", 0 ])
        end
      end

      it "prints the rules where one app leaves them on" do
        Dir.mktmpdir do |dir|
          apps(dir, "anti_hallucination_rules: false\n")
          expect(session_start(dir).first).to include(rules)
        end
      end

      # A call for a section an app turned off fails there, so rule 3 names only what every app serves.
      it "leaves out of rule 3 a section an app turned off" do
        Dir.mktmpdir do |dir|
          apps(dir, "skip_tools:\n  - rails_get_gems\n")
          out, status = session_start(dir)

          expect(status).to eq(0), out
          expect(out).to include(rendered(%w[rails_get_gems]))
          expect(out).to end_with("for the app to answer about.\n")
        end
      end

      it "leaves out of rule 3 a section an app skips although its rules switch is off" do
        Dir.mktmpdir do |dir|
          apps(dir, nil, "anti_hallucination_rules: false\nskip_tools:\n  - rails_get_gems\n")
          out, status = session_start(dir)

          expect(status).to eq(0), out
          expect(out).to include(rendered(%w[rails_get_gems]))
        end
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

    # The server refuses that gem, and its tools may lack what the rules name.
    it "prints nothing where the installed gem is older than the plugin needs" do
      Dir.mktmpdir do |gems|
        Dir.mktmpdir do |dir|
          app(dir)
          install_checkout(gems, RailsAiContext::VERSION)
          expect(Open3.capture2e(gemless(gems), Gem.ruby, hook, chdir: dir).first).to include("Verify before you write")

          FileUtils.rm_rf(Dir.glob(File.join(gems, "*")))
          install_checkout(gems, "5.0.0")
          expect(Open3.capture2e(gemless(gems), Gem.ruby, hook, chdir: dir).first).to eq("")
        end
      end
    end

    # The server hands such an app to its bundle's copy, and the rules must name
    # that copy's tools; where the bundle is not installed it serves its own.
    it "prints nothing where the server hands the app to a bundled copy older than the plugin needs" do
      Dir.mktmpdir do |gems|
        Dir.mktmpdir do |dir|
          install_checkout(gems, RailsAiContext::VERSION)
          app(dir)
          bundled = lambda do |version, *extra|
            write(File.join(dir, "vendored", "rails-ai-context.gemspec"),
                  %(Gem::Specification.new { |s| s.name = "rails-ai-context"; s.version = "#{version}"; s.summary = "x"; s.authors = [ "x" ]; s.files = [] }\n))
            write(File.join(dir, "Gemfile"), [ %(gem "rails-ai-context", path: "vendored"), *extra.map { |name| %(gem "#{name}") } ].join("\n") + "\n")
            write(File.join(dir, "Gemfile.lock"), <<~LOCK)
              PATH
                remote: vendored
                specs:
                  rails-ai-context (#{version})

              GEM
                remote: https://rubygems.org/
                specs:
              #{extra.map { |name| "    #{name} (1.0.0)" }.join("\n")}

              PLATFORMS
                ruby

              DEPENDENCIES
                rails-ai-context!
              #{extra.map { |name| "  #{name}" }.join("\n")}
            LOCK
            Open3.capture2e(gemless(gems), Gem.ruby, hook, chdir: dir).first
          end

          expect(bundled.("5.0.0")).to eq("")
          expect(bundled.(RailsAiContext::VERSION)).to include("Verify before you write")
          expect(bundled.("5.0.0", "no-such-gem-installed")).to include("Verify before you write")
        end
      end
    end

    it "prints nothing for an app whose config file or initializer turns the rules off" do
      Dir.mktmpdir do |dir|
        app(dir)
        File.write(File.join(dir, ".rails-ai-context.yml"), "anti_hallucination_rules: false\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        # The gem's own reader takes a symbol key too, and an alias.
        File.write(File.join(dir, ".rails-ai-context.yml"), ":anti_hallucination_rules: false\n")
        expect(session_start(dir)).to eq([ "", 0 ])
        File.write(File.join(dir, ".rails-ai-context.yml"), "off: &off false\nanti_hallucination_rules: *off\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        FileUtils.rm(File.join(dir, ".rails-ai-context.yml"))
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        initializer = File.join(dir, "config", "initializers", "rails_ai_context.rb")
        File.write(initializer, "RailsAiContext.configure do |c|\n  # c.anti_hallucination_rules = false\nend\n")
        expect(session_start(dir).first).to include("Verify before you write")

        File.write(initializer, "RailsAiContext.configure do |c|\n  c.anti_hallucination_rules = false\nend\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        # nil is off to the gem as well.
        File.write(initializer, "RailsAiContext.configure do |c|\n  c.anti_hallucination_rules = nil\nend\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        # The initializer runs after the config file, so its value wins.
        File.write(File.join(dir, ".rails-ai-context.yml"), "anti_hallucination_rules: false\n")
        File.write(initializer, "RailsAiContext.configure do |c|\n  c.anti_hallucination_rules = true\nend\n")
        expect(session_start(dir).first).to include("Verify before you write")
      end
    end

    # A block there claims the key before the config file loads, which then leaves it alone.
    it "reads the switch from config/application.rb and the environment's file, which run before the config file" do
      Dir.mktmpdir do |dir|
        app(dir)
        write(File.join(dir, "config", "application.rb"),
              "module Shop\n  class Application < Rails::Application\n    RailsAiContext.configure { |c| c.anti_hallucination_rules = false }\n  end\nend\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        write(File.join(dir, "config", "application.rb"), "")
        write(File.join(dir, "config", "environments", "production.rb"), "RailsAiContext.configure { |c| c.anti_hallucination_rules = false }\n")
        expect(session_start(dir).first).to include("Verify before you write")
        expect(session_start(dir, env: { "RAILS_ENV" => "production" })).to eq([ "", 0 ])
        expect(session_start(dir, env: { "RACK_ENV" => "production" })).to eq([ "", 0 ])

        write(File.join(dir, "config", "environments", "development.rb"), "RailsAiContext.configure { |c| c.anti_hallucination_rules = false }\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        # A later initializer's literal still wins.
        write(File.join(dir, "config", "initializers", "ai.rb"), "RailsAiContext.configure { |c| c.anti_hallucination_rules = true }\n")
        expect(session_start(dir).first).to include("Verify before you write")
      end
    end

    # Only a literal that ends its statement is the app's value; a condition or a comment block is not.
    it "keeps the rules where the off switch is conditional or commented out" do
      Dir.mktmpdir do |dir|
        app(dir)
        initializer = File.join(dir, "config", "initializers", "rails_ai_context.rb")
        write(initializer, "RailsAiContext.configure do |c|\n  c.anti_hallucination_rules = false if ENV[\"NO_RULES\"]\nend\n")
        expect(session_start(dir).first).to include("Verify before you write")

        write(initializer, "=begin\nRailsAiContext.configure do |c|\n  c.anti_hallucination_rules = false\nend\n=end\n")
        expect(session_start(dir).first).to include("Verify before you write")

        write(initializer, "RailsAiContext.configure do |c|\n  c.anti_hallucination_rules = false # off for now\nend\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        write(initializer, "RailsAiContext.configure do |c| c.anti_hallucination_rules = false; c.skip_tools = [] end\n")
        expect(session_start(dir)).to eq([ "", 0 ])
      end
    end

    # Git on Windows checks files out with CRLF by default.
    it "reads the switch from a file with CRLF line endings" do
      Dir.mktmpdir do |dir|
        app(dir)
        write(File.join(dir, "config", "initializers", "rails_ai_context.rb"),
              "RailsAiContext.configure do |c|\r\n  c.anti_hallucination_rules = false\r\nend\r\n")

        expect(session_start(dir)).to eq([ "", 0 ])
      end
    end

    # Rails runs initializers in the sorted order of their paths.
    it "takes the last literal among initializers in the order Rails runs them" do
      Dir.mktmpdir do |dir|
        app(dir)
        write(File.join(dir, "config", "initializers", "a_rules.rb"), "RailsAiContext.configure { |c| c.anti_hallucination_rules = false }\n")
        write(File.join(dir, "config", "initializers", "b_rules.rb"), "RailsAiContext.configure { |c| c.anti_hallucination_rules = true }\n")
        expect(session_start(dir).first).to include("Verify before you write")

        write(File.join(dir, "config", "initializers", "c_rules.rb"), "RailsAiContext.configure { |c| c.anti_hallucination_rules = false }\n")
        expect(session_start(dir)).to eq([ "", 0 ])
      end
    end

    it "reads the initializers of an app whose folder name holds glob characters" do
      Dir.mktmpdir do |base|
        %w[shop\ [old] shop{1}].each do |name|
          dir = File.join(base, name)
          app(dir)
          write(File.join(dir, "config", "initializers", "rails_ai_context.rb"), "RailsAiContext.configure { |c| c.anti_hallucination_rules = false }\n")

          expect(session_start(dir)).to eq([ "", 0 ])
        end
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

    # Claude Code loads every CLAUDE.md on the way up at launch, as a mountable engine's root above its dummy app.
    it "prints nothing where a CLAUDE.md on the way up carries the rules, unless it is the user's own" do
      Dir.mktmpdir do |home|
        engine = File.join(home, "engine")
        dir = File.join(engine, "test", "dummy")
        app(dir)
        write(File.join(engine, ".claude", "CLAUDE.md"), rules)
        expect(session_start(dir, env: { "HOME" => home })).to eq([ "", 0 ])

        FileUtils.rm(File.join(engine, ".claude", "CLAUDE.md"))
        write(File.join(home, ".claude", "CLAUDE.md"), rules)
        expect(session_start(dir, env: { "HOME" => home, "USERPROFILE" => home }).first).to include(rules)
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

    # Claude Code loads AGENTS.md at launch where CLAUDE.md imports it, or where
    # no CLAUDE.md, .claude/CLAUDE.md or CLAUDE.local.md is on the way up from
    # the folder it started in.
    it "prints nothing where Claude Code loads an AGENTS.md that carries the rules" do
      Dir.mktmpdir do |base|
        dir = File.join(base, "shop")
        app(dir)
        File.write(File.join(dir, "AGENTS.md"), rules)
        expect(session_start(dir)).to eq([ "", 0 ])
        expect(session_start(File.join(dir, "config"))).to eq([ "", 0 ])

        File.write(File.join(dir, "CLAUDE.md"), "# Shop\n")
        expect(session_start(dir).first).to include(rules)

        File.write(File.join(dir, "CLAUDE.md"), "# Shop\n\n@AGENTS.md\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        FileUtils.rm(File.join(dir, "CLAUDE.md"))
        write(File.join(dir, ".claude", "CLAUDE.md"), "# Shop\n")
        expect(session_start(dir).first).to include(rules)

        FileUtils.rm(File.join(dir, ".claude", "CLAUDE.md"))
        File.write(File.join(base, "CLAUDE.local.md"), "# Mine\n")
        expect(session_start(dir).first).to include(rules)
      end
    end

    # Claude Code imports nothing from a code block or a code span.
    it "counts an import of AGENTS.md outside code, and none inside it" do
      Dir.mktmpdir do |dir|
        app(dir)
        File.write(File.join(dir, "AGENTS.md"), rules)
        File.write(File.join(dir, "CLAUDE.md"), "Team notes.\n\n```md\n@AGENTS.md\n```\n")
        expect(session_start(dir).first).to include(rules)

        File.write(File.join(dir, "CLAUDE.md"), "Run `bin/setup`, then read @AGENTS.md\n")
        expect(session_start(dir)).to eq([ "", 0 ])

        File.write(File.join(dir, "CLAUDE.md"), "Use `see @AGENTS.md here` literally\n")
        expect(session_start(dir).first).to include(rules)
      end
    end

    # The user's own memory file is not a project's, so it does not stop AGENTS.md loading.
    it "loads AGENTS.md where the only CLAUDE.md on the way up is the user's own" do
      Dir.mktmpdir do |home|
        dir = File.join(home, "shop")
        app(dir)
        File.write(File.join(dir, "AGENTS.md"), rules)
        write(File.join(home, ".claude", "CLAUDE.md"), "# Mine\n")

        expect(session_start(dir, env: { "HOME" => home, "USERPROFILE" => home })).to eq([ "", 0 ])
      end
    end

    # Claude Code on Windows keeps the user's memory under %USERPROFILE%, whatever HOME Git Bash sets.
    it "takes the user's memory from USERPROFILE on Windows, where HOME may name another folder" do
      Dir.mktmpdir do |base|
        install_checkout(File.join(base, "gems"), RailsAiContext::VERSION)
        profile = File.join(base, "profile")
        dir = File.join(profile, "shop")
        app(dir)
        File.write(File.join(dir, "AGENTS.md"), rules)
        write(File.join(profile, ".claude", "CLAUDE.md"), "# Mine\n")
        FileUtils.mkdir_p(File.join(base, "home"))
        windows = File.join(base, "windows.rb")
        File.write(windows, "def Gem.win_platform?\n  true\nend\n")
        env = gemless(File.join(base, "gems")).merge("HOME" => File.join(base, "home"), "USERPROFILE" => profile)

        # Elsewhere the memory is under HOME, so this one is a project's CLAUDE.md, which keeps AGENTS.md from loading.
        expect(session_start(dir, env: env).first).to include(rules) unless Gem.win_platform?
        expect(session_start(dir, env: env.merge("RUBYOPT" => "-r#{windows}"))).to eq([ "", 0 ])
      end
    end

    # Activated as the server activates it, the gem gives no rules where the server cannot start.
    it "gives no rules where the gem cannot be activated the way the server activates it" do
      Dir.mktmpdir do |gems|
        Dir.mktmpdir do |dir|
          install_checkout(gems, RailsAiContext::VERSION, executables: [])
          app(dir)

          expect(refusal(dir, gem_home: gems)).to include("cannot start under")
          expect(session_start(dir, env: gemless(gems))).to eq([ "", 0 ])
        end
      end
    end

    # Claude Code keeps the user's memory under a CLAUDE_CONFIG_DIR, where ~/.claude/CLAUDE.md is one a session walks past.
    it "takes ~/.claude/CLAUDE.md for a project's own where CLAUDE_CONFIG_DIR moves the user's memory" do
      Dir.mktmpdir do |home|
        dir = File.join(home, "shop")
        app(dir)
        File.write(File.join(dir, "AGENTS.md"), rules)
        write(File.join(home, ".claude", "CLAUDE.md"), "# Mine\n")

        expect(session_start(dir, env: { "HOME" => home, "USERPROFILE" => home, "CLAUDE_CONFIG_DIR" => File.join(home, ".claude-work") }).first)
          .to include("Anti-Hallucination Protocol")
      end
    end

    # Claude Code reads CLAUDE_CONFIG_DIR from the env block of the user's settings too, not from the shell alone.
    it "leaves out the user's own memory where the user's settings move CLAUDE_CONFIG_DIR" do
      Dir.mktmpdir do |base|
        home = File.realpath(base)
        dir = File.join(home, "work", "shop")
        app(dir)
        moved = File.join(home, "work")
        write(File.join(home, ".claude", "settings.json"), JSON.generate("env" => { "CLAUDE_CONFIG_DIR" => moved }))
        write(File.join(moved, "CLAUDE.md"), rules)

        expect(session_start(dir, env: { "HOME" => home, "USERPROFILE" => home }).first).to include("Anti-Hallucination Protocol")
      end
    end

    # A Gemfile no repository holds may sit beside the app's boot.rb, a bundle GemLock leaves unread.
    it "gives the rules for an app whose bundle it cannot read, as the server serves it" do
      Dir.mktmpdir do |gems|
        Dir.mktmpdir do |root|
          install_checkout(gems, RailsAiContext::VERSION)
          dir = File.join(root, "web")
          app(dir)
          File.write(File.join(root, "Gemfile"), %(gem "rails"\n))
          File.write(File.join(root, "Gemfile.lock"), "GEM\n  specs:\n    rails-ai-context (5.0.0)\n")
          File.write(File.join(dir, "config", "boot.rb"), %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../Gemfile", __dir__)\n))

          expect(session_start(dir, env: gemless(gems)).first).to include("Anti-Hallucination Protocol")
        end
      end
    end

    # The server hands the app to the bundle BUNDLE_GEMFILE names, as bundle exec does: a dual boot's Gemfile.next, or a gems.rb.
    it "prints nothing where BUNDLE_GEMFILE names a bundle whose copy is older than the plugin needs" do
      Dir.mktmpdir do |gems|
        Dir.mktmpdir do |dir|
          install_checkout(gems, RailsAiContext::VERSION)
          app(dir)
          write(File.join(dir, "vendored", "rails-ai-context.gemspec"),
                %(Gem::Specification.new { |s| s.name = "rails-ai-context"; s.version = "5.0.0"; s.summary = "x"; s.authors = [ "x" ]; s.files = [] }\n))
          expect(session_start(dir, env: gemless(gems)).first).to include("Verify before you write")

          { File.join(dir, "Gemfile.next") => "#{File.join(dir, "Gemfile.next")}.lock",
            File.join(dir, "boot", "gems.rb") => File.join(dir, "boot", "gems.locked") }.each do |gemfile, lockfile|
            vendored = File.join(dir, "vendored")
            write(gemfile, %(gem "rails-ai-context", path: #{vendored.inspect}\n))
            write(lockfile, "PATH\n  remote: #{vendored}\n  specs:\n    rails-ai-context (5.0.0)\n\nPLATFORMS\n  ruby\n\n" \
                            "DEPENDENCIES\n  rails-ai-context!\n")

            expect(session_start(dir, env: gemless(gems).merge("BUNDLE_GEMFILE" => gemfile))).to eq([ "", 0 ]), gemfile
          end
        end
      end
    end

    # The server reads such a lock as naming no gem, and serves the app.
    it "gives the rules for an app whose lockfile it cannot read" do
      skip "root reads every file" if Process.uid.zero?
      skip "no file modes on Windows" if Gem.win_platform?

      Dir.mktmpdir do |gems|
        Dir.mktmpdir do |dir|
          install_checkout(gems, RailsAiContext::VERSION)
          app(dir)
          write(File.join(dir, "Gemfile"), %(gem "rails-ai-context"\n))
          write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    rails-ai-context (5.0.0)\n")
          File.chmod(0o000, File.join(dir, "Gemfile.lock"))

          expect(session_start(dir, env: gemless(gems)).first).to include("Verify before you write")
        ensure
          File.chmod(0o644, File.join(dir, "Gemfile.lock"))
        end
      end
    end

    # A Ruby too old for the installed gem's code fails to parse it.
    it "prints nothing, and fails nothing, where the gem's code does not parse" do
      Dir.mktmpdir do |dir|
        app(dir)
        broken = File.join(dir, "broken.rb")
        File.write(broken, "def Gem.activate_bin_path(*)\n  raise SyntaxError, \"unexpected token\"\nend\n")

        expect(session_start(dir, env: { "RUBYOPT" => "-r#{broken}" })).to eq([ "", 0 ])
      end
    end

    # Ten aliases a level, eight levels deep: a short file whose list of lists spells out a hundred million names.
    it "reads skip_tools from a config file whose aliases nest deep, at the speed of any other" do
      Dir.mktmpdir do |dir|
        app(dir)
        levels = (1..8).map { |n| "l#{n}: &l#{n} [#{([ "*l#{n - 1}" ] * 10).join(", ")}]\n" }.join
        File.write(File.join(dir, ".rails-ai-context.yml"), %(l0: &l0 "rails_get_gems"\n#{levels}skip_tools: [rails_get_conventions, *l8]\n))
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # A list of lists is refused, as the server refuses it, which keeps every tool on.
        expect(session_start(dir).first).to include(rendered([]))
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 8
      end
    end

    it "is the plugin's SessionStart hook" do
      hooks = JSON.parse(File.read(File.join(plugin, "hooks", "hooks.json")))["hooks"]["SessionStart"]
      commands = hooks.flat_map { |group| group["hooks"] }.map { |h| [ h["command"], *h["args"] ] }

      # Shell form, which a Claude Code too old for exec form runs too; the
      # path is substituted before any shell, and quoted for the spaces in it.
      # `--` keeps rbenv from picking the Ruby by the plugin's folder.
      # `exit 0` after it, so a folder where `ruby` cannot start shows no hook error.
      expect(commands).to eq([ [ %(ruby -- "${CLAUDE_PLUGIN_ROOT}/scripts/session_start.rb"; exit 0) ] ])
      # A resumed session holds the rules from its start already.
      expect(hooks.map { |group| group["matcher"] }).to eq([ "startup|clear|compact" ])
    end
  end
end
