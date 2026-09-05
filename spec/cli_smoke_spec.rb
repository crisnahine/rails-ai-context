# frozen_string_literal: true

require "spec_helper"

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

  it "documents the static-tier flags" do
    help = `ruby #{File.expand_path('../exe/rails-ai-context', __dir__)} help serve 2>&1`
    expect(help).to include("--no-boot")
    expect(help).to include("--app-path")
    expect(help).to include("--environment")
  end
end
