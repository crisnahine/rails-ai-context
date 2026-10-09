# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "open3"
require "json"

# Runtime smoke test: every registered tool must execute via ToolRunner
# against the combustion fixture without raising. Tools are allowed to
# return error-shaped responses (that's a normal outcome for e.g. missing
# params) - but they must not crash.
RSpec.describe "CLI smoke: every tool executes", type: :smoke do
  RailsAiContext::Server.builtin_tools.each do |tool_class|
    short = RailsAiContext::CLI::ToolRunner.short_name(tool_class.tool_name)

    it "#{tool_class.tool_name} runs via ToolRunner without raising" do
      runner = RailsAiContext::CLI::ToolRunner.new(short, [])
      expect { runner.run }.not_to raise_error
    end
  end

  # --no-boot returned before the "is this a Rails app" guard, so in an empty
  # directory the gem wrote a CLAUDE.md describing an app that is not there -
  # "Migrations: 0 total", "This project has 45 MCP tools" - and exited 0.
  it "refuses --no-boot outside a Rails app" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      out = `cd #{dir} && ruby -I #{lib} #{exe} context --no-boot 2>&1`
      status = $?.exitstatus

      expect(status).to eq(1), out
      expect(out).to include("No Rails app found")
      expect(Dir.children(dir)).to be_empty
    end
  end

  # `--environment` is the binary's own RAILS_ENV flag, so it ate the value
  # before env_config saw its `environment` parameter: the answer named prod as
  # the current environment and then listed all three, at exit 0.
  it "gives --environment to a tool that declares the parameter" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config", "environments"))
      File.write(File.join(dir, "config", "application.rb"),
                 "module EnvApp\n  class Application < Rails::Application\n  end\nend\n")
      %w[development test prod].each do |env|
        File.write(File.join(dir, "config", "environments", "#{env}.rb"),
                   "Rails.application.configure do\n  config.log_level = :debug\nend\n")
      end

      out = `cd #{dir} && ruby -I #{lib} #{exe} tool env_config --environment prod --no-boot 2>&1`

      expect(out).to include("## prod"), out
      expect(out).not_to include("## development")
      expect(out).not_to include("## test")
    end
  end

  # Booted, `--environment prod` also became RAILS_ENV and the app failed to
  # boot in an environment it has no database for. For a tool that declares
  # the parameter the flag is the tool's alone; the env var still sets
  # RAILS_ENV.
  describe "--environment after a tool that declares it" do
    def env_app(dir)
      FileUtils.mkdir_p(File.join(dir, "config", "environments"))
      File.write(File.join(dir, "config", "application.rb"),
                 "module EnvApp\n  class Application < Rails::Application\n  end\nend\n")
      %w[development prod].each do |env|
        File.write(File.join(dir, "config", "environments", "#{env}.rb"), "Rails.application.configure do\nend\n")
      end
    end

    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    it "does not set RAILS_ENV from the flag" do
      Dir.mktmpdir do |dir|
        env_app(dir)
        out = `cd #{dir} && env -u RAILS_ENV -u RACK_ENV ruby -I #{lib} #{exe} tool env_config --environment prod --no-boot 2>&1`

        expect(out).to include("_Current: **development**"), out
        expect(out).to include("## prod")
      end
    end

    it "still reads RAILS_ENV from the environment variable" do
      Dir.mktmpdir do |dir|
        env_app(dir)
        out = `cd #{dir} && RAILS_ENV=prod ruby -I #{lib} #{exe} tool env_config --no-boot 2>&1`

        expect(out).to include("_Current: **prod**"), out
      end
    end
  end

  # The binary decides before boot, without the gem loaded, which tools own
  # `--environment`; the list is a constant, so it has to match the schemas.
  it "names exactly the built-in tools that declare an environment parameter" do
    source = File.read(File.expand_path("../exe/rails-ai-context", __dir__))
    listed = source[/ENVIRONMENT_PARAM_TOOLS = %w\[([^\]]*)\]/, 1].to_s.split
    declared = RailsAiContext::Server.builtin_tools
      .select { |tool| (tool.input_schema_value&.to_h || {}).fetch(:properties, {}).key?(:environment) }
      .map { |tool| RailsAiContext::CLI::ToolRunner.short_name(tool.tool_name) }

    expect(listed.sort).to eq(declared.sort)
  end

  # An engine keeps its dummy app under spec/dummy, so its root has app/ and
  # no config/. There is real source to read there, and the guard against an
  # empty directory must not take the whole repo shape with it.
  it "still reads an engine repo with --no-boot" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

      out = `cd #{dir} && ruby -I #{lib} #{exe} tool model_details --no-boot 2>&1`

      expect($?.exitstatus).to eq(0), out
      expect(out).to include("Widget")
    end
  end

  # The static tier is exactly what a source-only tree gets with --no-boot,
  # so a command that can serve it must not refuse the same tree without it.
  it "serves a source-only tree without --no-boot" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

      out = `cd #{dir} && ruby -I #{lib} #{exe} tool model_details 2>&1`

      expect($?.exitstatus).to eq(0), out
      expect(out).to include("Widget")
    end
  end

  # Every command names itself when it enters the gem, so the refusal quotes
  # back the word the user typed and no command reaches the boot path without
  # one.
  it "enters the gem with a command name from every command" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "")
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

      # Bare `preset` lists and returns before the boot path, so the loop
      # runs a real one. Only serve and watch are left out: both run until
      # interrupted.
      # No command may wait on the runner's own stdin: init prompts.
      [ "inspect", "facts", "context", "preset architecture", "init", "tool", "doctor" ].each do |command|
        out = `cd #{dir} && ruby -I #{lib} #{exe} #{command} < /dev/null 2>&1`
        expect(out).not_to include("ArgumentError"), "#{command}: #{out}"
        # preset rescues StandardError, so only the message reaches stderr.
        expect(out).not_to include("missing keyword"), "#{command}: #{out}"
      end

      doctor = `cd #{dir} && ruby -I #{lib} #{exe} doctor 2>&1`
      expect($?.exitstatus).to eq(1), doctor
      expect(doctor).to include("doctor needs a bootable app: no config/environment.rb")
    end
  end

  # A listing the user asked for belongs on stdout; only the error framing and
  # the listing that follows a rejected name go to stderr.
  it "puts the bare preset listing on stdout and a rejected name on stderr" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      listing = `cd #{dir} && ruby -I #{lib} #{exe} preset 2>/dev/null`
      expect($?.exitstatus).to eq(0), listing
      expect(listing).to include("Available presets:")

      rejected = `cd #{dir} && ruby -I #{lib} #{exe} preset bogus 2>&1 1>/dev/null`
      expect($?.exitstatus).to eq(1), rejected
      expect(rejected).to include("Unknown preset: bogus")
      expect(rejected).to include("Available presets:")
    end
  end

  # Thor reads a leading switch as "no command given" and falls back to
  # `help`, so a CI job wrapping `rails-ai-context --app-path <dir> doctor`
  # went green having checked nothing.
  describe "a global option typed before the command" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    it "runs the command instead of printing usage" do
      Dir.mktmpdir do |dir|
        out = `ruby -I #{lib} #{exe} --app-path #{dir} doctor 2>&1`

        expect($?.exitstatus).to eq(1), out
        expect(out).to include("No Rails app found in ")
        expect(out).to include(File.basename(dir))
        expect(out).not_to include("Usage:\n  rails-ai-context doctor")
      end
    end

    it "carries the value through to the command" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

        out = `ruby -I #{lib} #{exe} --app-path #{dir} tool model_details --no-boot 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(out).to include("Widget")
      end
    end

    it "accepts the equals spelling" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

        out = `ruby -I #{lib} #{exe} --app-path=#{dir} tool model_details --no-boot 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(out).to include("Widget")
      end
    end

    # `--no-boot` is declared per command rather than globally, and typing it
    # first is the same mistake with the same silent answer.
    it "moves a command's own switch behind the command too" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

        out = `ruby -I #{lib} #{exe} --app-path #{dir} --no-boot tool model_details 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(out).to include("Widget")
      end
    end

    it "still answers --version and --help" do
      version = `ruby -I #{lib} #{exe} --version 2>&1`
      expect($?.exitstatus).to eq(0), version
      expect(version).to include("rails-ai-context v")

      help = `ruby -I #{lib} #{exe} --help 2>&1`
      expect($?.exitstatus).to eq(0), help
      expect(help).to include("rails-ai-context doctor")
    end

    it "still refuses a leading unknown switch" do
      out = `ruby -I #{lib} #{exe} --bogus doctor 2>&1`
      expect($?.exitstatus).to eq(1), out
    end
  end

  # Nine frames of backtrace where a one-line refusal belongs. `tool` already
  # gave one; doctor, inspect and watch did not.
  describe "an --app-path that does not exist" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    [ "doctor", "inspect", "watch", "tool schema" ].each do |command|
      it "refuses in one line from #{command}" do
        out = `ruby -I #{lib} #{exe} #{command} --app-path /nonexistent-app-path 2>&1`

        expect($?.exitstatus).to eq(1), out
        expect(out).to include("/nonexistent-app-path")
        expect(out).not_to include("(NameError)")
        expect(out).not_to match(/^\s+from /)
      end
    end
  end

  # bin/rails and Bundler both walk up to the app; the binary refused from
  # anywhere but the root, and refused a folder of apps without naming them.
  describe "a command run outside the app root" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    def rails_app(dir)
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "config", "application.rb"), "module X\n  class Application < Rails::Application\n  end\nend\n")
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
    end

    it "walks up from a subdirectory and says so on stderr only" do
      Dir.mktmpdir do |dir|
        dir = File.realpath(dir)
        rails_app(dir)

        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "model_details", "--no-boot",
                                          chdir: File.join(dir, "app", "models"))

        expect(status.exitstatus).to eq(0), err
        expect(out).to include("Widget")
        expect(out).not_to include("using app at")
        expect(err).to include("[rails-ai-context] using app at #{dir}")
      end
    end

    it "uses the one app in a folder below" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))

        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "model_details", "--no-boot", chdir: dir)

        expect(status.exitstatus).to eq(0), err
        expect(out).to include("Widget")
        expect(err).to include("[rails-ai-context] using app at a/")
      end
    end

    it "names every app in a folder of several, with the command for each" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))

        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "serve", chdir: dir, stdin_data: "")

        expect(status.exitstatus).to eq(1)
        expect(out).to eq("")
        expect(err).to include("rails-ai-context --app-path a serve\n")
        expect(err).to include("rails-ai-context --app-path b serve\n")
      end
    end

    it "still lists tools in a folder of several apps" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))

        out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "--list", chdir: dir)

        expect(status.exitstatus).to eq(0), err
        expect(out).to include("schema")
      end
    end

    it "names the app above a wrong --app-path" do
      Dir.mktmpdir do |dir|
        rails_app(dir)

        _out, err, status = Open3.capture3("ruby", "-I", lib, exe, "tool", "schema", "--no-boot",
                                           "--app-path", File.join(dir, "app", "models"))

        expect(status.exitstatus).to eq(1)
        expect(err).to include("No Rails app found in #{File.join(dir, "app", "models")}")
        expect(err).to include("is inside the app at")
      end
    end
  end

  # An editor opened at a folder of apps reads the MCP config there and
  # nowhere below, so init sets the folder up: one server per app in its
  # configs, and each app's own config and context files in the app.
  describe "init in a folder of apps" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    # A lockfile without the gem makes a standalone install, served by this
    # binary; one with it, an in-Gemfile install, served by bundle exec.
    def rails_app(dir, bundled: false)
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "config", "application.rb"), "module X\n  class Application < Rails::Application\n  end\nend\n")
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
      File.write(File.join(dir, "Gemfile"), "")
      specs = bundled ? "    rails (8.0.0)\n    rails-ai-context (5.32.2)\n" : "    rails (8.0.0)\n"
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\n")
    end

    def init(dir, answers, *flags)
      Open3.capture3("ruby", "-I", lib, exe, "init", "--no-boot", *flags, chdir: dir, stdin_data: answers)
    end

    def servers(dir)
      JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"]
    end

    it "writes one server per app here and each app's own files in the app" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "group", "b"))

        _out, err, status = init(dir, "1\n1\n")

        expect(status.exitstatus).to eq(0), err
        expect(servers(dir)).to eq(
          "rails-ai-context-a" => { "command" => "rails-ai-context", "args" => %w[serve --app-path a],
                                    "env" => { "RAILS_AI_CONTEXT_SERVER_NAME" => "a-rails-ai-context" } },
          "rails-ai-context-b" => { "command" => "rails-ai-context", "args" => %w[serve --app-path group/b],
                                    "env" => { "RAILS_AI_CONTEXT_SERVER_NAME" => "b-rails-ai-context" } }
        )
        %w[a group/b].each do |app|
          expect(File.exist?(File.join(dir, app, ".rails-ai-context.yml"))).to be(true), app
          expect(File.read(File.join(dir, app, "CLAUDE.md"))).to include("Widget")
          expect(File.exist?(File.join(dir, app, ".mcp.json"))).to be(false)
        end
        expect(Dir.children(dir).sort).to eq(%w[.mcp.json a group])
        expect(err).to include("rails-ai-context-b -> group/b/")
      end
    end

    it "sets up the one app below the same way" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))

        _out, err, status = init(dir, "1\n3\n")

        expect(status.exitstatus).to eq(0), err
        expect(servers(dir).keys).to eq(%w[rails-ai-context-a])
        expect(File.exist?(File.join(dir, "a", ".rails-ai-context.yml"))).to be(true)
        expect(File.exist?(File.join(dir, "a", "CLAUDE.md"))).to be(false)
        expect(err).to include("MCP-only setup")
      end
    end

    # The bare entry serves the folder it starts in, which is no app.
    it "replaces a bare entry left in the folder, and changes nothing on a second run" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        File.write(File.join(dir, ".mcp.json"), JSON.generate("mcpServers" => {
          "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] }, "mine" => { "command" => "x" }
        }))

        init(dir, "1\n3\n")
        first = File.read(File.join(dir, ".mcp.json"))
        _out, err, = init(dir, "1\n3\n")

        expect(servers(dir).keys).to eq(%w[mine rails-ai-context-a rails-ai-context-b])
        expect(File.read(File.join(dir, ".mcp.json"))).to eq(first)
        expect(err).to include(".mcp.json unchanged - skipped")
      end
    end

    it "names an in-Gemfile app's Gemfile, and fails when its bundle cannot write the context" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"), bundled: true)

        _out, err, status = init(dir, "1\n1\n")

        expect(servers(dir)["rails-ai-context-b"]).to eq(
          "command" => "bundle", "args" => %w[exec rails-ai-context serve --app-path b],
          "env" => { "BUNDLE_GEMFILE" => "b/Gemfile", "RAILS_AI_CONTEXT_SERVER_NAME" => "b-rails-ai-context" }
        )
        expect(File.exist?(File.join(dir, "a", "CLAUDE.md"))).to be(true)
        expect(status.exitstatus).to eq(1)
        expect(err).to include("Error: no context files for b/")
      end
    end

    # What a client sees: the entry it was given starts a server, from the
    # folder the client was opened at, for the app the entry names.
    it "writes entries that serve their app from the folder" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        File.write(File.join(dir, "b", "app", "models", "gadget.rb"), "class Gadget < ApplicationRecord\nend\n")
        init(dir, "1\n3\n")
        entry = servers(dir)["rails-ai-context-b"]
        requests = [
          { jsonrpc: "2.0", id: 1, method: "initialize",
            params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } } },
          { jsonrpc: "2.0", method: "notifications/initialized" },
          { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rails_get_model_details", arguments: {} } }
        ].map { |message| "#{JSON.generate(message)}\n" }.join

        out, err, = Open3.capture3(entry["env"], "ruby", "-I", lib, exe, *entry["args"], "--no-boot", chdir: dir, stdin_data: requests)
        responses = out.lines.filter_map { |line| JSON.parse(line) rescue nil }.to_h { |msg| [ msg["id"], msg ] }

        expect(responses.dig(1, "result", "serverInfo", "name")).to eq("b-rails-ai-context"), err
        expect(responses.dig(2, "result", "content", 0, "text")).to include("Gadget")
      end
    end

    it "warns when an app declares a Ruby other than the one the folder runs" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        File.write(File.join(dir, "b", ".ruby-version"), "2.7.8\n")
        File.write(File.join(dir, "a", ".ruby-version"), "#{RUBY_VERSION}\n")

        _out, err, = init(dir, "1\n3\n")

        expect(err).to include("Warning: b/ declares Ruby 2.7.8; this folder runs #{RUBY_VERSION}.")
        expect(err).not_to include("Warning: a/")
      end
    end

    it "sets up the folder of apps --app-path names" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "work", "a"))
        rails_app(File.join(dir, "work", "b"))

        _out, err, status = init(dir, "1\n3\n", "--app-path", "work")

        expect(status.exitstatus).to eq(0), err
        expect(servers(File.join(dir, "work")).keys).to eq(%w[rails-ai-context-a rails-ai-context-b])
        expect(Dir.children(dir)).to eq(%w[work])
        # From where it was run, not from the folder it set up.
        expect(err).to include("rails-ai-context --app-path work/a tool NAME")
      end
    end

    it "lists the apps below a folder --app-path names to any other command" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "work", "a"))
        rails_app(File.join(dir, "work", "b"))

        _out, err, status = Open3.capture3("ruby", "-I", lib, exe, "--app-path", "work", "tool", "schema", "--no-boot", chdir: dir)

        expect(status.exitstatus).to eq(1)
        expect(err).to include("No Rails app found in #{File.join(File.realpath(dir), 'work')}, and 2 below it")
        expect(err).to include("rails-ai-context --app-path work/a tool schema --no-boot\n")
      end
    end

    it "drops the entry of an app that is gone when it runs again" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        init(dir, "1\n3\n")
        FileUtils.rm_rf(File.join(dir, "b"))

        _out, err, status = init(dir, "1\n3\n")

        expect(status.exitstatus).to eq(0), err
        expect(servers(dir).keys).to eq(%w[rails-ai-context-a])
      end
    end

    it "serves an app with a Gemfile and no lockfile from this binary" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))
        File.delete(File.join(dir, "b", "Gemfile.lock"))
        File.write(File.join(dir, "b", "Gemfile"), %(source "https://rubygems.org"\ngem "rails"\n))

        _out, err, status = init(dir, "1\n1\n")

        expect(status.exitstatus).to eq(0), err
        expect(servers(dir)["rails-ai-context-b"]["command"]).to eq("rails-ai-context")
        expect(File.exist?(File.join(dir, "b", "CLAUDE.md"))).to be(true)
      end
    end

    it "still sets up only the app --app-path names" do
      Dir.mktmpdir do |dir|
        rails_app(File.join(dir, "a"))
        rails_app(File.join(dir, "b"))

        _out, err, status = init(dir, "1\n3\n", "--app-path", "a")

        expect(status.exitstatus).to eq(0), err
        expect(Dir.children(dir).sort).to eq(%w[a b])
        expect(JSON.parse(File.read(File.join(dir, "a", ".mcp.json")))["mcpServers"].keys).to eq(%w[rails-ai-context])
      end
    end
  end

  # docs/CLI.md lists watch among the commands that take --no-boot, and it
  # died with an uninitialized-constant backtrace.
  it "watches a source-only tree with --no-boot" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)
    # The child inherits this environment, so it reaches the same `listen`
    # this does. Which of the two outcomes to demand follows from that,
    # rather than from a pattern both of them match.
    listen_reachable = system(RbConfig.ruby, "-e", "require 'listen'", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

      # With `listen` reachable the watcher runs until it is killed, so the
      # child is bounded rather than read to EOF.
      io = IO.popen([ "ruby", "-I", lib, exe, "watch", "--no-boot", "--app-path", dir ], err: %i[child out])
      out = +""
      timed_out = false
      begin
        Timeout.timeout(30) do
          while (line = io.gets)
            out << line
            break if out.include?("Watching for changes")
          end
        end
      rescue Timeout::Error
        timed_out = true
      ensure
        begin
          Process.kill("KILL", io.pid)
        rescue Errno::ESRCH
          nil
        end
        io.close
      end

      expect(timed_out).to be(false), "watch printed nothing for 30s. Output so far:\n#{out}"
      expect(out).not_to include("uninitialized constant")
      if listen_reachable
        # Printed only once the listener is running, so it names a watch that
        # actually started.
        expect(out).to include("Watching for changes")
      else
        expect(out).to include("Error: The `listen` gem is required for watch mode.")
      end
    end
  end

  # `--help` promises "the ambient RAILS_ENV or development", and apps read
  # RAILS_ENV in config/boot.rb before anything else runs. Only the flag set
  # it, so an app that insists on the variable never saw the documented
  # default.
  describe "an app that needs RAILS_ENV set" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    def build_app(dir, environment_rb)
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "environment.rb"), environment_rb)
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
    end

    it "applies the documented default when the caller set nothing" do
      Dir.mktmpdir do |dir|
        build_app(dir, <<~RUBY)
          File.write(File.join(__dir__, "..", "seen_env.txt"), ENV["RAILS_ENV"].to_s)
          raise "boot needs a database"
        RUBY

        out = `cd #{dir} && env -u RAILS_ENV -u RACK_ENV ruby -I #{lib} #{exe} tool model_details 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(File.read(File.join(dir, "seen_env.txt"))).to eq("development")
        expect(out).to include("Widget")
      end
    end

    it "still honours an explicit --environment" do
      Dir.mktmpdir do |dir|
        build_app(dir, <<~RUBY)
          File.write(File.join(__dir__, "..", "seen_env.txt"), ENV["RAILS_ENV"].to_s)
          raise "boot needs a database"
        RUBY

        `cd #{dir} && env -u RAILS_ENV -u RACK_ENV ruby -I #{lib} #{exe} tool model_details --environment test 2>&1`

        expect(File.read(File.join(dir, "seen_env.txt"))).to eq("test")
      end
    end

    # Rails resolves its own environment as RAILS_ENV, then RACK_ENV, then
    # development, and treats an empty value as unset. "The ambient RAILS_ENV"
    # the help text promises is that whole answer, not the first term of it.
    it "takes an ambient RACK_ENV before falling back to development" do
      Dir.mktmpdir do |dir|
        build_app(dir, <<~RUBY)
          File.write(File.join(__dir__, "..", "seen_env.txt"), ENV["RAILS_ENV"].to_s)
          raise "boot needs a database"
        RUBY

        `cd #{dir} && env -u RAILS_ENV RACK_ENV=staging ruby -I #{lib} #{exe} tool model_details 2>&1`

        expect(File.read(File.join(dir, "seen_env.txt"))).to eq("staging")
      end
    end

    it "reads an empty RAILS_ENV as unset, the way Rails does" do
      Dir.mktmpdir do |dir|
        build_app(dir, <<~RUBY)
          File.write(File.join(__dir__, "..", "seen_env.txt"), ENV["RAILS_ENV"].to_s)
          raise "boot needs a database"
        RUBY

        `cd #{dir} && env -u RACK_ENV RAILS_ENV= ruby -I #{lib} #{exe} tool model_details 2>&1`

        expect(File.read(File.join(dir, "seen_env.txt"))).to eq("development")
      end
    end

    # An app that calls exit/abort in an initializer is a fifth boot-failure
    # mode. The binary owns this process, and it has a static tier to answer
    # from, so the exit is a boot failure here rather than a process decision.
    it "serves the static tier when the app aborts during boot" do
      Dir.mktmpdir do |dir|
        build_app(dir, %(abort "The RAILS_ENV environment variable is not set."\n))

        out = `cd #{dir} && ruby -I #{lib} #{exe} tool model_details 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(out).to include("The RAILS_ENV environment variable is not set.")
        expect(out).to include("static tier active")
        expect(out).to include("Widget")
      end
    end
  end

  # The serializer refuses an unknown format, but only after a full
  # introspection has run and written nothing.
  it "refuses an unknown context format before introspecting" do
    exe = File.expand_path("../exe/rails-ai-context", __dir__)
    lib = File.expand_path("../lib", __dir__)

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

      out = `cd #{dir} && ruby -I #{lib} #{exe} context --format bogus --no-boot 2>&1`

      expect($?.exitstatus).to eq(1), out
      expect(out).to include("Unknown format: bogus")
      expect(out).not_to include("Introspecting Rails app")
    end
  end

  # One rescue on dispatch answers every command, so what the commands that
  # never had one do, and what Thor's own refusals say, is pinned here.
  describe "commands that carry no rescue of their own" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    it "prints the version and exits 0" do
      out = `ruby -I #{lib} #{exe} version 2>&1`
      expect($?.exitstatus).to eq(0), out
      expect(out).to include("rails-ai-context v")
    end

    it "refuses init outside a Rails app in its own words" do
      Dir.mktmpdir do |dir|
        out = `cd #{dir} && ruby -I #{lib} #{exe} init < /dev/null 2>&1`
        expect($?.exitstatus).to eq(1), out
        expect(out).to include("No Rails app found in")
        expect(out).to include("Run this command from your Rails app root directory (or pass --app-path).")
      end
    end

    # init read Dir.pwd before --app-path was applied: the config, every MCP
    # config and the .gitignore entries went where it was run, the context
    # files into the named app.
    it "sets up only the app --app-path names" do
      Dir.mktmpdir do |dir|
        %w[a b].each do |name|
          FileUtils.mkdir_p(File.join(dir, name, "app", "models"))
          File.write(File.join(dir, name, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
          File.write(File.join(dir, name, ".gitignore"), "*.log\n")
        end

        out = `cd #{dir}/a && printf '1\n3\n' | ruby -I #{lib} #{exe} init --app-path ../b --no-boot 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(Dir.children(File.join(dir, "a")).sort).to eq(%w[.gitignore app])
        expect(File.read(File.join(dir, "a", ".gitignore"))).to eq("*.log\n")
        expect(Dir.children(File.join(dir, "b"))).to include(".rails-ai-context.yml", ".mcp.json")
      end
    end

    it "sets up the app --app-path names from a directory that is no app" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "empty"))
        FileUtils.mkdir_p(File.join(dir, "b", "app", "models"))
        File.write(File.join(dir, "b", "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")

        out = `cd #{dir}/empty && printf '1\n3\n' | ruby -I #{lib} #{exe} init --app-path ../b --no-boot 2>&1`

        expect($?.exitstatus).to eq(0), out
        expect(Dir.children(File.join(dir, "empty"))).to be_empty
        expect(File.exist?(File.join(dir, "b", ".rails-ai-context.yml"))).to be(true)
      end
    end

    # The initializer wins on read, so a mode init left only in the YAML
    # changed nothing in an app that still had a generator-written one.
    it "records the mode init was given in an initializer that already sets one" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        initializer = File.join(dir, "config", "initializers", "rails_ai_context.rb")
        File.write(initializer, "RailsAiContext.configure do |config|\n  config.tool_mode = :mcp\nend\n")

        `cd #{dir} && printf '1\\n2\\n' | ruby -I #{lib} #{exe} init --no-boot 2>&1`

        expect(File.read(initializer)).to include("config.tool_mode = :cli")
      end
    end

    it "warns when the initializer sets the mode in a form init cannot rewrite" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "rails_ai_context.rb"),
                   "RailsAiContext.configure do |config|\n  config.tool_mode = ENV.fetch(\"MODE\", \"mcp\").to_sym\nend\n")

        out = `cd #{dir} && printf '1\\n2\\n' | ruby -I #{lib} #{exe} init --no-boot 2>&1`

        expect(out).to include("sets config.tool_mode in a form this installer does not rewrite")
      end
    end

    it "says nothing about legacy rule files on an MCP-only init" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, ".claude", "rules"))
        File.write(File.join(dir, ".claude", "rules", "rails-ui-patterns.md"), "old\n")

        out = `cd #{dir} && printf '1\\n' | ruby -I #{lib} #{exe} init --mcp-only --no-boot 2>&1`

        expect(out).to include("MCP-only setup")
        expect(out).not_to include("Legacy files detected")
      end
    end

    # init wrote its config files and then died in a Ruby backtrace when
    # generating context hit a path it could not write.
    it "answers an unexpected init failure in one line on stderr" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, "CLAUDE.md"))

        err = `cd #{dir} && ruby -I #{lib} #{exe} init < /dev/null 2>&1 >/dev/null`

        expect($?.exitstatus).to eq(1), err
        expect(err.lines.last).to start_with("Error: Is a directory")
        expect(err).not_to match(/^\s+from /)
        expect(err).not_to include("(Errno::EISDIR)")
      end
    end

    # The one line is the answer; the frames behind it are one env var away,
    # the same way a boot failure spells it.
    it "prints the frames behind that failure under DEBUG" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, "CLAUDE.md"))

        err = `cd #{dir} && DEBUG=1 ruby -I #{lib} #{exe} init < /dev/null 2>&1 >/dev/null`

        expect($?.exitstatus).to eq(1), err
        expect(err).to include("Error: Is a directory")
        expect(err).to match(%r{^\s+\S+/lib/rails_ai_context/\S+\.rb:\d+}), err
      end
    end

    it "leaves an unknown command to Thor" do
      out = `ruby -I #{lib} #{exe} bogus 2>&1`
      expect($?.exitstatus).to eq(1), out
      expect(out).to eq(%(Could not find command "bogus".\n))
    end

    it "prints the command list and exits 0" do
      out = `ruby -I #{lib} #{exe} help 2>&1`
      expect($?.exitstatus).to eq(0), out
      expect(out).to include("rails-ai-context version")
    end
  end

  it "documents the static-tier flags" do
    help = `ruby #{File.expand_path('../exe/rails-ai-context', __dir__)} help serve 2>&1`
    expect(help).to include("--no-boot")
    expect(help).to include("--app-path")
    expect(help).to include("--environment")
  end

  # The port the HTTP server announces, read off stderr before it binds.
  describe "serve port" do
    let(:exe) { File.expand_path("../exe/rails-ai-context", __dir__) }
    let(:lib) { File.expand_path("../lib", __dir__) }

    def announced_port(dir, *args)
      Open3.popen3("ruby", "-I", lib, exe, "serve", *args, "--no-boot", chdir: dir) do |stdin, _out, err, wait|
        stdin.close
        Timeout.timeout(60) do
          while (line = err.gets)
            return line[/starting on [^:]+:(\d+)/, 1] if line.include?("starting on")
          end
        end
      ensure
        Process.kill("KILL", wait.pid) rescue nil
      end
    end

    def app_dir(dir, yaml = nil)
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "widget.rb"), "class Widget\nend\n")
      File.write(File.join(dir, ".rails-ai-context.yml"), yaml) if yaml
    end

    it "honours --port under the streamable_http alias" do
      Dir.mktmpdir do |dir|
        app_dir(dir)
        expect(announced_port(dir, "--transport", "streamable_http", "--port", "6123")).to eq("6123")
      end
    end

    it "reads http_port from the config file when --port is left out" do
      Dir.mktmpdir do |dir|
        app_dir(dir, "http_port: 6124\n")
        expect(announced_port(dir, "--transport", "http")).to eq("6124")
      end
    end

    it "lets an explicit --port beat the config file" do
      Dir.mktmpdir do |dir|
        app_dir(dir, "http_port: 6124\n")
        expect(announced_port(dir, "--transport", "http", "--port", "6125")).to eq("6125")
      end
    end

    it "falls back to 6029" do
      Dir.mktmpdir do |dir|
        app_dir(dir)
        expect(announced_port(dir, "--transport", "http")).to eq("6029")
      end
    end
  end
end
