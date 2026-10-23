# frozen_string_literal: true

require "spec_helper"

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
    Open3.capture3((gem_home ? gemless(gem_home) : {}).merge("CLAUDE_PLUGIN_ROOT" => plugin).merge(env), Gem.ruby, *server_args,
                   chdir: dir, stdin_data: stdin)
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
      reason = "#{File.realpath(dir)} holds no Rails app: start Claude Code in a Rails app's folder."

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

  # The binary hands an app to its own bundle; a RUBYGEMS_GEMDEPS the shell set would only refuse the gem.
  it "starts the installed gem whatever RUBYGEMS_GEMDEPS names" do
    Dir.mktmpdir do |gems|
      Dir.mktmpdir do |dir|
        install_checkout(gems, RailsAiContext::VERSION)
        File.write(File.join(dir, "Gemfile"), %(source "https://rubygems.org"\n))

        expect(refusal(dir, gem_home: gems, env: { "RUBYGEMS_GEMDEPS" => File.join(dir, "Gemfile") })).to include("holds no Rails app")
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

  # Bundler's activate_bin_path takes no requirement, so the bundle's older copy would start, or crash on a file it lacks.
  it "names the bundle Claude Code inherited when it locks an older copy, and the hook gives no rules" do
    Dir.mktmpdir do |dir|
      old = File.join(dir, "old")
      FileUtils.mkdir_p(old)
      FileUtils.cp_r([ File.join(repo, "lib"), File.join(repo, "exe") ], old)
      File.write(File.join(old, "rails-ai-context.gemspec"),
                 %(Gem::Specification.new { |s| s.name = "rails-ai-context"; s.version = "5.0.0"; s.summary = "x"; s.authors = [ "x" ]; ) +
                 %(s.files = []; s.bindir = "exe"; s.executables = [ "rails-ai-context" ] }\n))
      FileUtils.mkdir_p(File.join(dir, "bundle"))
      gemfile = File.join(dir, "bundle", "Gemfile")
      File.write(gemfile, %(gem "rails-ai-context", path: #{old.inspect}\n))
      File.write("#{gemfile}.lock", "PATH\n  remote: #{old}\n  specs:\n    rails-ai-context (5.0.0)\n\nPLATFORMS\n  ruby\n\n" \
                                    "DEPENDENCIES\n  rails-ai-context!\n")
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

  # The binary's own advice there is --app-path, which the plugin's entry has no way to pass.
  it "names where to start Claude Code in a folder of apps, by their paths from there" do
    Dir.mktmpdir do |dir|
      %w[shop/web admin/web].each do |name|
        FileUtils.mkdir_p(File.join(dir, name, "config"))
        File.write(File.join(dir, name, "config", "application.rb"), "")
      end
      reason = refusal(dir)

      expect(reason).to include("holds 2 Rails apps (admin/web, shop/web)").and include("start Claude Code in one of them")
      # Project scope is read from the start folder alone, and a local install's setting only where the apps share its repository.
      expect(reason).to include("`claude plugin disable rails-ai-context@rails-ai-context --scope project` run here, or with `--scope local` " \
                                "where a --scope local install turns it on. On macOS and Linux, a local setting at the root of a git " \
                                "repository the apps share reaches them too.")
    end
  end

  it "names where to start Claude Code in a folder with no app" do
    Dir.mktmpdir do |dir|
      reason = refusal(dir)

      expect(reason).to include("no Rails app").and include("start Claude Code in a Rails app's folder")
      expect(reason).not_to include("--app-path")
    end
  end

  # An app root with no app source: the gem's own binary is what refuses it.
  it "runs the installed gem's serve" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin", "rails"), %(ENGINE_PATH = "x"\n))
      out, err, status = launch(dir)

      expect(status.exitstatus).to eq(1), out + err
      expect(out + err).to include("No Rails app found in")
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
      expect(refusal(dir)).to eq("#{File.realpath(dir)} holds no Rails app: start Claude Code in a Rails app's folder.")
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

    it "prints the rules in an app and from a folder inside it, and nothing above two apps" do
      Dir.mktmpdir do |dir|
        app(File.join(dir, "shop"))
        hook_in = ->(folder) { Open3.capture2e(gemless(gems), Gem.ruby, hook, chdir: folder).first }

        expect(hook_in.(File.join(dir, "shop"))).to include("Verify before you write")
        expect(hook_in.(File.join(dir, "shop", "app", "models"))).to include("Verify before you write")

        app(File.join(dir, "admin"))
        expect(hook_in.(dir)).to eq("")
      end
    end

    it "names where to start Claude Code in a folder of two apps" do
      Dir.mktmpdir do |dir|
        app(File.join(dir, "shop", "web"))
        app(File.join(dir, "admin", "web"))
        expect(refusal(dir, gem_home: gems)).to include("holds 2 Rails apps (admin/web, shop/web)")
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
      File.write(path, text)
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

        # An initializer's literal replaces the file's list, as at boot, in any list form the setter takes.
        { "%w[rails_get_gems]" => %w[rails_get_gems], "%i[rails_get_conventions]" => %w[rails_get_conventions],
          "%w(rails_get_gems)" => %w[rails_get_gems], "[ :rails_get_gems, \"rails_get_conventions\" ]" => %w[rails_get_gems rails_get_conventions] }.each do |list, tools|
          write(File.join(dir, "config", "initializers", "rails_ai_context.rb"),
                "RailsAiContext.configure do |config|\n  config.skip_tools = #{list}\nend\n")
          expect(session_start(dir).first).to include(rendered(tools)), list
        end
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
          "config.skip_tools = []\n  config.skip_tools.append 'rails_get_gems'" => %w[rails_get_gems],
          "config.skip_tools = []\n  config.skip_tools.push \"rails_get_gems\", 'rails_get_conventions'" => %w[rails_get_gems rails_get_conventions],
          "config.skip_tools = []\n  config.skip_tools.concat %w[rails_get_gems], ['rails_get_conventions']" => %w[rails_get_gems rails_get_conventions],
          "config.skip_tools = []\n  config.skip_tools << \"rails_get_gems\" << 'rails_get_conventions'" => %w[rails_get_gems rails_get_conventions],
          "config.skip_tools += [ :rails_get_gems ]" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools += %i[rails_get_gems]" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools |= %w[rails_get_gems]" => %w[rails_get_conventions rails_get_gems],
          "config.skip_tools |= [ :rails_get_gems ]" => %w[rails_get_conventions rails_get_gems],
          # The other forms append a symbol as it is, which the server never matches.
          "config.skip_tools.push(:rails_get_gems)" => %w[rails_get_conventions],
          "config.skip_tools << :rails_get_gems" => %w[rails_get_conventions],
          "config.skip_tools.concat(%i[rails_get_gems])" => %w[rails_get_conventions],
          "config.skip_tools.append :rails_get_gems, \"x\"" => %w[rails_get_conventions] }.each do |code, tools|
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

        expect(session_start(dir).first).to include(rendered(%w[rails_get_conventions]))
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
