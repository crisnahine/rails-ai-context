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

  it "documents the static-tier flags" do
    help = `ruby #{File.expand_path('../exe/rails-ai-context', __dir__)} help serve 2>&1`
    expect(help).to include("--no-boot")
    expect(help).to include("--app-path")
    expect(help).to include("--environment")
  end
end
