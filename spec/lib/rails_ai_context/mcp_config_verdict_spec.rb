# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"

# What the install does with each MCP config, as one table: the write path
# carries the verdict out and doctor prints it, so each row also checks that
# the write did what the verdict said.
RSpec.describe "McpConfigGenerator#verdict" do
  around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

  def generator(tool)
    RailsAiContext::McpConfigGenerator.new(tools: [ tool ], output_dir: @dir, standalone: true)
  end

  def path_for(tool)
    File.join(@dir, RailsAiContext::McpConfigGenerator::TOOL_CONFIGS.fetch(tool)[:path])
  end

  def put(tool, text)
    return if text.nil?

    FileUtils.mkdir_p(File.dirname(path_for(tool)))
    File.binwrite(path_for(tool), text)
  end

  rows = McpConfigRows.rows

  rows.each do |shape, (tool, text, expected)|
    it "#{expected[:action]}s #{shape}, and the write does so" do
      put(tool, text)
      before = File.exist?(path_for(tool)) ? File.binread(path_for(tool)) : nil

      verdict = generator(tool).verdict(tool, path_for(tool))

      expect(verdict).to have_attributes(expected.except(:by_hand, :note))
      expect(verdict.by_hand).to match(expected[:by_hand])
      expect(verdict.note).to match(expected[:note])

      result = generator(tool).call
      case expected[:action]
      when :refuse
        expect(result[:failed]).to eq([ path_for(tool) ])
        expect(result[:reasons][path_for(tool)]).to eq("#{verdict.reason}, so it is left as it is. #{verdict.by_hand}")
        expect(File.binread(path_for(tool))).to eq(before)
      when :keep
        expect(result[:skipped]).to eq([ path_for(tool) ])
        expect(File.binread(path_for(tool))).to eq(before)
      else
        expect(result[:written]).to eq([ path_for(tool) ])
      end
      expect(result[:notes][path_for(tool)]).to eq(verdict.note)
    end
  end

  it "names the file in the edit when asked, and can leave the next run out" do
    put(:claude, "[1, 2]")

    verdict = generator(:claude).verdict(:claude, path_for(:claude))

    expect(verdict.by_hand(".mcp.json", next_run: false)).to eq("Make .mcp.json a JSON object")
  end

  # Doctor judges the entries the install read, from the same read.
  it "names the gem's entries the file holds and the app each one serves" do
    web = { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", "apps/web" ], "env" => { "PATH" => "/bin" } }
    put(:claude, JSON.generate("mcpServers" => { "rails-ai-context-web" => web, "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] },
                                                 "other" => { "command" => "x" } }) + "\n")
    put(:codex, %([mcp_servers.rails-ai-context]\ncommand = "rails-ai-context"\nargs = ["serve"]\n[mcp_servers.rails-ai-context.env]\nGEM_HOME = "/g"\n))

    entries = generator(:claude).verdict(:claude, path_for(:claude)).existing
    expect(entries.map { |entry| entry.slice(:name, :own, :app, :env) }).to eq([
      { name: "rails-ai-context-web", own: true, app: File.join(@dir, "apps/web"), env: { "PATH" => "/bin" } },
      { name: "rails-ai-context", own: true, app: @dir, env: {} }
    ])
    codex = generator(:codex).verdict(:codex, path_for(:codex)).existing
    expect(codex.map { |entry| entry.slice(:name, :argv, :env, :app) })
      .to eq([ { name: "rails-ai-context", argv: %w[rails-ai-context serve], env: { "GEM_HOME" => "/g" }, app: @dir } ])

    put(:claude, "{ nope")
    expect(generator(:claude).verdict(:claude, path_for(:claude)).existing).to be_nil
  end

  it "names the entries of a file it read and refused, and none read for an earlier file" do
    put(:copilot, %({\n  // mine\n  "servers": { "rails-ai-context-web": { "command": "rails-ai-context", "args": ["serve", "--app-path", "apps/web"] } }\n}\n))
    put(:codex, %(mcp_servers = { rails-ai-context = { command = "rails-ai-context", args = ["serve"] } }\n))
    one = generator(:copilot)

    refused = one.verdict(:copilot, path_for(:copilot))
    expect(refused.action).to eq(:refuse)
    expect(refused.existing.map { |entry| entry.slice(:name, :app) }).to eq([ { name: "rails-ai-context-web", app: File.join(@dir, "apps/web") } ])
    codex = generator(:codex).verdict(:codex, path_for(:codex))
    expect(codex.action).to eq(:refuse)
    expect(codex.existing.map { |entry| entry.slice(:name, :argv) }).to eq([ { name: "rails-ai-context", argv: %w[rails-ai-context serve] } ])

    put(:copilot, "{ nope")
    expect(one.verdict(:copilot, path_for(:copilot)).existing).to be_nil
    expect(one.instance_variables).not_to include(:@existing)
  end

  it "keeps how it names a file's entries to itself" do
    expect(RailsAiContext::McpConfigGenerator).not_to respond_to(:json_named)
    expect(RailsAiContext::McpConfigGenerator).not_to respond_to(:toml_named)
    expect { RailsAiContext::McpConfigGenerator::Named }.to raise_error(NameError, /private constant/)
  end
end
