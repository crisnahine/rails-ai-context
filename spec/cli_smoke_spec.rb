# frozen_string_literal: true

require "spec_helper"
require "timeout"

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
      [ "inspect", "facts", "context", "preset architecture", "init", "tool", "doctor" ].each do |command|
        out = `cd #{dir} && ruby -I #{lib} #{exe} #{command} 2>&1`
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

  it "documents the static-tier flags" do
    help = `ruby #{File.expand_path('../exe/rails-ai-context', __dir__)} help serve 2>&1`
    expect(help).to include("--no-boot")
    expect(help).to include("--app-path")
    expect(help).to include("--environment")
  end
end
