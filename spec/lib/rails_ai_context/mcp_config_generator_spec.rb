# frozen_string_literal: true

require "spec_helper"
require "json"
require "yaml"

RSpec.describe RailsAiContext::McpConfigGenerator do
  let(:tools) { %i[claude cursor copilot opencode codex] }

  # Examples that omit standalone: exercise the in-Gemfile command shape.
  # Pin detection so the assertions do not depend on this repo's own
  # Gemfile.lock; explicit standalone: arguments bypass detection entirely.
  before do
    allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)
  end

  describe "#call" do
    context "install mode detection" do
      it "auto-detects standalone mode when standalone: is not given" do
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)

        Dir.mktmpdir do |dir|
          described_class.new(tools: [ :claude ], output_dir: dir, tool_mode: :mcp).call

          entry = JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"]["rails-ai-context"]
          expect(entry["command"]).to eq("rails-ai-context")
          expect(entry["args"]).to eq([ "serve" ])
        end
      end

      it "prefers an explicit standalone: value over detection" do
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)

        Dir.mktmpdir do |dir|
          described_class.new(tools: [ :claude ], output_dir: dir, standalone: false, tool_mode: :mcp).call

          entry = JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"]["rails-ai-context"]
          expect(entry["command"]).to eq("bundle")
          expect(entry["args"]).to eq([ "exec", "rails-ai-context", "serve" ])
        end
      end
    end

    context "with :mcp tool_mode" do
      it "generates .mcp.json for :claude with mcpServers key" do
        Dir.mktmpdir do |dir|
          result = described_class.new(tools: [ :claude ], output_dir: dir, tool_mode: :mcp).call
          expect(result[:written].size).to eq(1)

          content = JSON.parse(File.read(File.join(dir, ".mcp.json")))
          expect(content).to have_key("mcpServers")
          expect(content["mcpServers"]).to have_key("rails-ai-context")

          entry = content["mcpServers"]["rails-ai-context"]
          expect(entry["command"]).to eq("bundle")
          expect(entry["args"]).to eq([ "exec", "rails-ai-context", "serve" ])
        end
      end

      it "generates .cursor/mcp.json for :cursor with mcpServers key" do
        Dir.mktmpdir do |dir|
          result = described_class.new(tools: [ :cursor ], output_dir: dir, tool_mode: :mcp).call
          expect(result[:written].size).to eq(1)

          path = File.join(dir, ".cursor", "mcp.json")
          expect(File.exist?(path)).to be true
          content = JSON.parse(File.read(path))
          expect(content).to have_key("mcpServers")
          expect(content["mcpServers"]["rails-ai-context"]["command"]).to eq("bundle")
        end
      end

      it "generates .vscode/mcp.json for :copilot with servers key" do
        Dir.mktmpdir do |dir|
          result = described_class.new(tools: [ :copilot ], output_dir: dir, tool_mode: :mcp).call
          expect(result[:written].size).to eq(1)

          path = File.join(dir, ".vscode", "mcp.json")
          expect(File.exist?(path)).to be true
          content = JSON.parse(File.read(path))
          expect(content).to have_key("servers")
          expect(content).not_to have_key("mcpServers")

          entry = content["servers"]["rails-ai-context"]
          expect(entry["command"]).to eq("bundle")
          expect(entry["args"]).to eq([ "exec", "rails-ai-context", "serve" ])
        end
      end

      it "generates opencode.json for :opencode with mcp key and type local" do
        Dir.mktmpdir do |dir|
          result = described_class.new(tools: [ :opencode ], output_dir: dir, tool_mode: :mcp).call
          expect(result[:written].size).to eq(1)

          content = JSON.parse(File.read(File.join(dir, "opencode.json")))
          expect(content).to have_key("mcp")

          entry = content["mcp"]["rails-ai-context"]
          expect(entry["type"]).to eq("local")
          expect(entry["command"]).to eq([ "bundle", "exec", "rails-ai-context", "serve" ])
          expect(entry).not_to have_key("args")
        end
      end

      it "generates .codex/config.toml for :codex as TOML with env snapshot" do
        Dir.mktmpdir do |dir|
          result = described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp).call
          expect(result[:written].size).to eq(1)

          path = File.join(dir, ".codex", "config.toml")
          expect(File.exist?(path)).to be true
          content = File.read(path)
          expect(content).to include("[mcp_servers.rails-ai-context]")
          expect(content).to include('command = "bundle"')
          expect(content).to include('args = ["exec", "rails-ai-context", "serve"]')
          # Env section captures PATH for Codex sandbox compatibility
          expect(content).to include("[mcp_servers.rails-ai-context.env]")
          expect(content).to include("PATH = ")
        end
      end

      it "generates all 5 configs when all tools selected" do
        Dir.mktmpdir do |dir|
          result = described_class.new(tools: tools, output_dir: dir, tool_mode: :mcp).call
          expect(result[:written].size).to eq(5)

          expect(File.exist?(File.join(dir, ".mcp.json"))).to be true
          expect(File.exist?(File.join(dir, ".cursor", "mcp.json"))).to be true
          expect(File.exist?(File.join(dir, ".vscode", "mcp.json"))).to be true
          expect(File.exist?(File.join(dir, "opencode.json"))).to be true
          expect(File.exist?(File.join(dir, ".codex", "config.toml"))).to be true
        end
      end
    end

    context "merge logic" do
      it "merges into existing .mcp.json without overwriting other servers" do
        Dir.mktmpdir do |dir|
          existing = { "mcpServers" => { "other-server" => { "command" => "node" } } }
          File.write(File.join(dir, ".mcp.json"), JSON.pretty_generate(existing))

          described_class.new(tools: [ :claude ], output_dir: dir, tool_mode: :mcp).call

          content = JSON.parse(File.read(File.join(dir, ".mcp.json")))
          expect(content["mcpServers"]).to have_key("other-server")
          expect(content["mcpServers"]).to have_key("rails-ai-context")
        end
      end

      it "merges into existing .vscode/mcp.json without overwriting other servers" do
        Dir.mktmpdir do |dir|
          vscode_dir = File.join(dir, ".vscode")
          FileUtils.mkdir_p(vscode_dir)
          existing = { "servers" => { "other-mcp" => { "command" => "npx" } } }
          File.write(File.join(vscode_dir, "mcp.json"), JSON.pretty_generate(existing))

          described_class.new(tools: [ :copilot ], output_dir: dir, tool_mode: :mcp).call

          content = JSON.parse(File.read(File.join(vscode_dir, "mcp.json")))
          expect(content["servers"]).to have_key("other-mcp")
          expect(content["servers"]).to have_key("rails-ai-context")
        end
      end

      it "merges into existing opencode.json without overwriting other MCP entries" do
        Dir.mktmpdir do |dir|
          existing = { "mcp" => { "other-tool" => { "type" => "local", "command" => [ "node" ] } }, "model" => "gpt-4" }
          File.write(File.join(dir, "opencode.json"), JSON.pretty_generate(existing))

          described_class.new(tools: [ :opencode ], output_dir: dir, tool_mode: :mcp).call

          content = JSON.parse(File.read(File.join(dir, "opencode.json")))
          expect(content["mcp"]).to have_key("other-tool")
          expect(content["mcp"]).to have_key("rails-ai-context")
          expect(content["model"]).to eq("gpt-4")
        end
      end

      it "merges into existing .codex/config.toml without overwriting other sections" do
        Dir.mktmpdir do |dir|
          codex_dir = File.join(dir, ".codex")
          FileUtils.mkdir_p(codex_dir)
          existing = <<~TOML
            model = "o3"

            [mcp_servers.other-tool]
            command = "node"
            args = ["server.js"]
          TOML
          File.write(File.join(codex_dir, "config.toml"), existing)

          described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp).call

          content = File.read(File.join(codex_dir, "config.toml"))
          expect(content).to include("[mcp_servers.other-tool]")
          expect(content).to include("[mcp_servers.rails-ai-context]")
          expect(content).to include('model = "o3"')
        end
      end

      it "replaces existing rails-ai-context section in .codex/config.toml" do
        Dir.mktmpdir do |dir|
          codex_dir = File.join(dir, ".codex")
          FileUtils.mkdir_p(codex_dir)
          existing = <<~TOML
            [mcp_servers.rails-ai-context]
            command = "old-command"
            args = ["old"]
          TOML
          File.write(File.join(codex_dir, "config.toml"), existing)

          described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp).call

          content = File.read(File.join(codex_dir, "config.toml"))
          expect(content).not_to include("old-command")
          expect(content).to include('command = "bundle"')
        end
      end

      it "replaces existing rails-ai-context section including env sub-section" do
        Dir.mktmpdir do |dir|
          codex_dir = File.join(dir, ".codex")
          FileUtils.mkdir_p(codex_dir)
          existing = <<~TOML
            [mcp_servers.rails-ai-context]
            command = "old-command"
            args = ["old"]

            [mcp_servers.rails-ai-context.env]
            PATH = "/old/path"
            GEM_HOME = "/old/gem"

            [mcp_servers.other-tool]
            command = "node"
          TOML
          File.write(File.join(codex_dir, "config.toml"), existing)

          described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp).call

          content = File.read(File.join(codex_dir, "config.toml"))
          expect(content).not_to include("old-command")
          expect(content).not_to include("/old/path")
          expect(content).to include('command = "bundle"')
          expect(content).to include("[mcp_servers.other-tool]")
        end
      end
    end

    context "idempotency" do
      it "skips unchanged files on re-run" do
        Dir.mktmpdir do |dir|
          first = described_class.new(tools: tools, output_dir: dir, tool_mode: :mcp).call
          second = described_class.new(tools: tools, output_dir: dir, tool_mode: :mcp).call
          expect(second[:written]).to be_empty
          expect(second[:skipped].size).to eq(first[:written].size)
        end
      end
    end

    context "standalone mode" do
      it "uses rails-ai-context serve command for JSON configs" do
        Dir.mktmpdir do |dir|
          described_class.new(tools: [ :claude ], output_dir: dir, standalone: true, tool_mode: :mcp).call

          content = JSON.parse(File.read(File.join(dir, ".mcp.json")))
          entry = content["mcpServers"]["rails-ai-context"]
          expect(entry["command"]).to eq("rails-ai-context")
          expect(entry["args"]).to eq([ "serve" ])
        end
      end

      it "uses rails-ai-context serve command for OpenCode" do
        Dir.mktmpdir do |dir|
          described_class.new(tools: [ :opencode ], output_dir: dir, standalone: true, tool_mode: :mcp).call

          content = JSON.parse(File.read(File.join(dir, "opencode.json")))
          entry = content["mcp"]["rails-ai-context"]
          expect(entry["command"]).to eq([ "rails-ai-context", "serve" ])
        end
      end

      it "uses rails-ai-context serve command for Codex TOML" do
        Dir.mktmpdir do |dir|
          described_class.new(tools: [ :codex ], output_dir: dir, standalone: true, tool_mode: :mcp).call

          content = File.read(File.join(dir, ".codex", "config.toml"))
          expect(content).to include('command = "rails-ai-context"')
          expect(content).to include('args = ["serve"]')
        end
      end
    end

    context "with :cli tool_mode" do
      it "skips all MCP config generation" do
        Dir.mktmpdir do |dir|
          result = described_class.new(tools: tools, output_dir: dir, tool_mode: :cli).call
          expect(result[:written]).to be_empty
          expect(result[:skipped]).to be_empty
        end
      end
    end
  end

  describe ".remove" do
    it "removes only rails-ai-context entry from JSON config, preserving others" do
      Dir.mktmpdir do |dir|
        content = {
          "mcpServers" => {
            "rails-ai-context" => { "command" => "bundle", "args" => [ "exec", "rails", "ai:serve" ] },
            "other-server" => { "command" => "node", "args" => [ "server.js" ] }
          }
        }
        File.write(File.join(dir, ".mcp.json"), JSON.pretty_generate(content))

        cleaned = described_class.remove(tools: [ :claude ], output_dir: dir)
        expect(cleaned.size).to eq(1)

        result = JSON.parse(File.read(File.join(dir, ".mcp.json")))
        expect(result["mcpServers"]).not_to have_key("rails-ai-context")
        expect(result["mcpServers"]).to have_key("other-server")
      end
    end

    it "deletes JSON file entirely when rails-ai-context is the only entry" do
      Dir.mktmpdir do |dir|
        described_class.new(tools: [ :claude ], output_dir: dir, tool_mode: :mcp).call

        described_class.remove(tools: [ :claude ], output_dir: dir)
        expect(File.exist?(File.join(dir, ".mcp.json"))).to be false
      end
    end

    it "removes rails-ai-context section from TOML, preserving others" do
      Dir.mktmpdir do |dir|
        codex_dir = File.join(dir, ".codex")
        FileUtils.mkdir_p(codex_dir)
        toml = <<~TOML
          [mcp_servers.rails-ai-context]
          command = "bundle"
          args = ["exec", "rails", "ai:serve"]

          [mcp_servers.other-tool]
          command = "node"
        TOML
        File.write(File.join(codex_dir, "config.toml"), toml)

        cleaned = described_class.remove(tools: [ :codex ], output_dir: dir)
        expect(cleaned.size).to eq(1)

        result = File.read(File.join(codex_dir, "config.toml"))
        expect(result).not_to include("rails-ai-context")
        expect(result).to include("[mcp_servers.other-tool]")
      end
    end

    it "returns empty array when file does not exist" do
      Dir.mktmpdir do |dir|
        cleaned = described_class.remove(tools: [ :claude ], output_dir: dir)
        expect(cleaned).to be_empty
      end
    end
  end
end
