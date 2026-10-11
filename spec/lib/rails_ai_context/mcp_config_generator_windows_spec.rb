# frozen_string_literal: true

require "spec_helper"
require "json"

# On Windows a gem's executables are .bat files (bundle.bat,
# rails-ai-context.bat), which Claude Code, Codex and the other clients that
# start a server without a shell do not run, so every config starts the
# server through `cmd /c`. spec_helper turns that form off for the rest of
# the suite; these examples run it on every platform.
RSpec.describe RailsAiContext::McpConfigGenerator, "on Windows" do
  let(:tools) { %i[claude cursor copilot opencode codex] }
  let(:bundled) { %w[cmd /c bundle exec rails-ai-context serve] }

  before do
    allow(described_class).to receive(:windows_shell?).and_return(true)
    allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)
  end

  def json(dir, path)
    JSON.parse(File.read(File.join(dir, path)))
  end

  it "starts every client's server through cmd /c" do
    Dir.mktmpdir do |dir|
      described_class.new(tools: tools, output_dir: dir, tool_mode: :mcp).call

      [ [ ".mcp.json", "mcpServers" ], [ ".cursor/mcp.json", "mcpServers" ], [ ".vscode/mcp.json", "servers" ] ].each do |path, key|
        entry = json(dir, path)[key]["rails-ai-context"]
        expect([ entry["command"], *entry["args"] ]).to eq(bundled), path
      end
      expect(json(dir, "opencode.json")["mcp"]["rails-ai-context"]["command"]).to eq(bundled)
      toml = File.read(File.join(dir, ".codex/config.toml"))
      expect(toml).to include(%(command = "cmd"\nargs = ["/c", "bundle", "exec", "rails-ai-context", "serve"]\n))
    end
  end

  it "wraps the standalone binary the same way" do
    Dir.mktmpdir do |dir|
      described_class.new(tools: %i[claude], output_dir: dir, tool_mode: :mcp, standalone: true).call

      entry = json(dir, ".mcp.json")["mcpServers"]["rails-ai-context"]
      expect(entry).to eq("command" => "cmd", "args" => %w[/c rails-ai-context serve])
    end
  end

  it "keeps a workspace entry's --app-path behind the command it wraps" do
    Dir.mktmpdir do |dir|
      servers = [ described_class::Server.new(name: "rails-ai-context-web", standalone: false, app_path: "apps/web", gemfile: "apps/web/Gemfile") ]
      described_class.new(tools: %i[claude cursor], output_dir: dir, tool_mode: :mcp, servers: servers).call

      claude = json(dir, ".mcp.json")["mcpServers"]["rails-ai-context-web"]
      cursor = json(dir, ".cursor/mcp.json")["mcpServers"]["rails-ai-context-web"]
      expect(claude["args"]).to eq(%w[/c bundle exec rails-ai-context serve --app-path apps/web])
      expect(cursor["args"]).to eq(%w[/c bundle exec rails-ai-context serve --app-path ${workspaceFolder}/apps/web])
      expect(described_class.entry_app_root(described_class.json_argv(claude), nil, dir)).to eq(File.join(dir, "apps/web"))
      expect(described_class.named_entries(File.join(dir, ".mcp.json"), :claude).map { |entry| entry[:own] }).to eq([ true ])
    end
  end

  it "leaves its own configs alone on the next run" do
    Dir.mktmpdir do |dir|
      described_class.new(tools: tools, output_dir: dir, tool_mode: :mcp).call
      before = tools.to_h { |tool| [ tool, File.read(File.join(dir, described_class::TOOL_CONFIGS[tool][:path])) ] }

      result = described_class.new(tools: tools, output_dir: dir, tool_mode: :mcp).call

      expect(result[:written]).to be_empty
      tools.each { |tool| expect(File.read(File.join(dir, described_class::TOOL_CONFIGS[tool][:path]))).to eq(before[tool]) }
    end
  end

  # A config committed from macOS or Linux, or written before the gem
  # wrapped its command, is the gem's still, and is brought up to date.
  it "wraps an entry written without cmd /c" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".mcp.json"), JSON.generate("mcpServers" => {
        "rails-ai-context" => { "command" => "bundle", "args" => %w[exec rails-ai-context serve] },
        "other" => { "command" => "node", "args" => [ "server.js" ] }
      }))

      result = described_class.new(tools: %i[claude], output_dir: dir, tool_mode: :mcp).call

      servers = json(dir, ".mcp.json")["mcpServers"]
      expect(result[:written]).to eq([ File.join(dir, ".mcp.json") ])
      expect([ servers["rails-ai-context"]["command"], *servers["rails-ai-context"]["args"] ]).to eq(bundled)
      expect(servers["other"]).to eq("command" => "node", "args" => [ "server.js" ])
    end
  end

  # And the other way: a config committed from Windows, read where clients
  # start the command itself.
  it "unwraps an entry written on Windows, on any other platform" do
    allow(described_class).to receive(:windows_shell?).and_return(false)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".mcp.json"), JSON.generate("mcpServers" => {
        "rails-ai-context-web" => { "command" => "cmd", "args" => %w[/c bundle exec rails-ai-context serve --app-path apps/web] }
      }))
      servers = [ described_class::Server.new(name: "rails-ai-context-web", standalone: false, app_path: "apps/web") ]

      described_class.new(tools: %i[claude], output_dir: dir, tool_mode: :mcp, servers: servers).call

      expect(json(dir, ".mcp.json")["mcpServers"]["rails-ai-context-web"]).to eq(
        "command" => "bundle", "args" => %w[exec rails-ai-context serve --app-path apps/web]
      )
    end
  end

  it "removes a wrapped entry with the rest of the gem's" do
    Dir.mktmpdir do |dir|
      described_class.new(tools: %i[claude codex], output_dir: dir, tool_mode: :mcp).call

      removed = described_class.remove(tools: %i[claude codex], output_dir: dir)

      expect(removed).to contain_exactly(File.join(dir, ".mcp.json"), File.join(dir, ".codex/config.toml"))
    end
  end

  describe ".unwrapped_argv" do
    it "reads the command a cmd /c runs, however cmd is named" do
      expect(described_class.unwrapped_argv(%w[cmd /c bundle exec rails-ai-context serve])).to eq(%w[bundle exec rails-ai-context serve])
      expect(described_class.unwrapped_argv(%w[CMD.EXE /C rails-ai-context serve])).to eq(%w[rails-ai-context serve])
      expect(described_class.unwrapped_argv([ "C:\\Windows\\System32\\cmd.exe", "/c", "rails-ai-context", "serve" ])).to eq(%w[rails-ai-context serve])
    end

    it "leaves any other command line as it is" do
      expect(described_class.unwrapped_argv(%w[bundle exec rails-ai-context serve])).to eq(%w[bundle exec rails-ai-context serve])
      expect(described_class.unwrapped_argv(%w[cmd /k rails-ai-context serve])).to eq(%w[cmd /k rails-ai-context serve])
      expect(described_class.unwrapped_argv(%w[cmd /c])).to eq(%w[cmd /c])
      expect(described_class.unwrapped_argv(nil)).to eq([])
    end
  end

  it "counts a wrapped workspace entry as the gem's by the server it runs" do
    expect(described_class.own_entry?("rails-ai-context-web", %w[cmd /c bundle exec rails-ai-context serve --app-path web])).to be(true)
    expect(described_class.own_entry?("rails-ai-context-web", %w[cmd /c node server.js])).to be(false)
  end
end
