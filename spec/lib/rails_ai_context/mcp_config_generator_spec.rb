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

      # The bytes each tool's file gets, pinned whole. Every writer branch
      # produces one of these five, so a shape change that moves a key, an
      # indent or the TOML args rendering fails here first.
      it "writes the same bytes for all five tools" do
        Dir.mktmpdir do |dir|
          described_class.new(tools: tools, output_dir: dir, tool_mode: :mcp).call

          json_entry = <<~JSON.chomp
            {
              "command": "bundle",
              "args": [
                "exec",
                "rails-ai-context",
                "serve"
              ]
            }
          JSON
          json_entry = json_entry.gsub("\n", "\n    ")

          expect(File.read(File.join(dir, ".mcp.json"))).to eq(<<~JSON)
            {
              "mcpServers": {
                "rails-ai-context": #{json_entry}
              }
            }
          JSON

          expect(File.read(File.join(dir, ".cursor", "mcp.json"))).to eq(<<~JSON)
            {
              "mcpServers": {
                "rails-ai-context": #{json_entry}
              }
            }
          JSON

          expect(File.read(File.join(dir, ".vscode", "mcp.json"))).to eq(<<~JSON)
            {
              "servers": {
                "rails-ai-context": #{json_entry}
              }
            }
          JSON

          expect(File.read(File.join(dir, "opencode.json"))).to eq(<<~JSON)
            {
              "mcp": {
                "rails-ai-context": {
                  "type": "local",
                  "command": [
                    "bundle",
                    "exec",
                    "rails-ai-context",
                    "serve"
                  ]
                }
              }
            }
          JSON

          toml = File.read(File.join(dir, ".codex", "config.toml"))
          expect(toml.split("\n\n").first).to eq(<<~TOML.chomp)
            [mcp_servers.rails-ai-context]
            command = "bundle"
            args = ["exec", "rails-ai-context", "serve"]
          TOML
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

      # VS Code's and OpenCode's configs take trailing commas: a fresh file
      # in its place would drop every server somebody wrote there.
      it "leaves an app's own config that does not parse as JSON as it is, and names the entry to add" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, ".vscode"))
          jsonc = %({\n  "servers": { "github": { "url": "https://api.example/mcp" }, },\n  "inputs": [],\n}\n)
          path = File.join(dir, ".vscode/mcp.json")
          File.write(path, jsonc)

          result = described_class.new(tools: [ :copilot ], output_dir: dir, tool_mode: :mcp, standalone: true).call

          expect(result[:failed]).to eq([ path ])
          expect(File.read(path)).to eq(jsonc)
          expect(result[:reasons][path]).to include(
            "does not parse as JSON", "so it is left as it is",
            %(Add {"servers":{"rails-ai-context":{"command":"rails-ai-context","args":["serve"]}}} to it by hand)
          )
        end
      end

      # JSON.parse passes over comments; the file written back would have none.
      it "does not write back a config that holds comments, and skips it when it is current" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, ".vscode"))
          path = File.join(dir, ".vscode/mcp.json")
          commented = %({\n  // GitHub's server\n  "servers": { "github": { "url": "https://api.example/mcp" } }\n}\n)
          File.write(path, commented)

          result = described_class.new(tools: [ :copilot ], output_dir: dir, tool_mode: :mcp, standalone: true).call

          expect(result[:failed]).to eq([ path ])
          expect(File.read(path)).to eq(commented)
          expect(result[:reasons][path]).to include("holds comments")

          current = %({\n  /* ours */\n  "servers": { "rails-ai-context": { "command": "rails-ai-context", "args": ["serve"] } }\n}\n)
          File.write(path, current)
          result = described_class.new(tools: [ :copilot ], output_dir: dir, tool_mode: :mcp, standalone: true).call

          expect(result[:skipped]).to eq([ path ])
          expect(File.read(path)).to eq(current)
        end
      end

      # An empty file holds nothing to lose; an editor's byte order mark is
      # the file's.
      it "fills an empty config, and keeps a byte order mark" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, ".mcp.json"), "\n")
          FileUtils.mkdir_p(File.join(dir, ".vscode"))
          File.write(File.join(dir, ".vscode/mcp.json"), %(\uFEFF{"servers": {"github": {"url": "https://api.example/mcp"}}}\n))

          result = described_class.new(tools: %i[claude copilot], output_dir: dir, tool_mode: :mcp, standalone: true).call

          expect(result[:written].size).to eq(2)
          expect(JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"].keys).to eq(%w[rails-ai-context])
          vscode = File.read(File.join(dir, ".vscode/mcp.json"))
          expect(vscode).to start_with("\uFEFF{")
          expect(JSON.parse(vscode.delete_prefix("\uFEFF"))["servers"].keys).to eq(%w[github rails-ai-context])
        end
      end

      # JSON is UTF-8; bytes that are not would make a rewrite fail midway.
      it "leaves a config that is not UTF-8 as it is" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, ".mcp.json")
          File.binwrite(path, %({"mcpServers": {"x": {"command": "caf\xE9"}}}\n).b)

          result = described_class.new(tools: %i[claude], output_dir: dir, tool_mode: :mcp, standalone: true).call

          expect(result[:failed]).to eq([ path ])
          expect(result[:reasons][path]).to include("not UTF-8")
          expect(File.binread(path)).to eq(%({"mcpServers": {"x": {"command": "caf\xE9"}}}\n).b)
        end
      end

      # SETUP.md tells a user to point the bare name at the HTTP endpoint.
      it "keeps an HTTP entry under the bare name in place of the gem's, and says so" do
        Dir.mktmpdir do |dir|
          http = %({"mcpServers": {"rails-ai-context": {"url": "http://localhost:3000/mcp"}}}\n)
          File.write(File.join(dir, ".mcp.json"), http)
          FileUtils.mkdir_p(File.join(dir, ".codex"))
          toml = %([mcp_servers.rails-ai-context]\nurl = "http://localhost:3000/mcp"\n)
          File.write(File.join(dir, ".codex/config.toml"), toml)

          result = described_class.new(tools: %i[claude codex], output_dir: dir, tool_mode: :mcp, standalone: true).call

          expect(result[:skipped].size).to eq(2)
          expect(File.read(File.join(dir, ".mcp.json"))).to eq(http)
          expect(File.read(File.join(dir, ".codex/config.toml"))).to eq(toml)
          expect(result[:notes].values).to all(include("kept rails-ai-context", "in place of the gem's"))
        end
      end

      # A byte order mark hid the header on the first line, and a second
      # table of one name does not parse.
      it "reads a Codex config past a byte order mark, and keeps the mark" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, ".codex"))
          path = File.join(dir, ".codex/config.toml")
          File.write(path, %(\uFEFF[mcp_servers.rails-ai-context]\ncommand = "old"\nargs = ["serve"]\n))

          described_class.new(tools: %i[codex], output_dir: dir, tool_mode: :mcp, standalone: true).call

          toml = File.read(path)
          expect(toml).to start_with("\uFEFF[mcp_servers.rails-ai-context]\n")
          expect(toml.scan("[mcp_servers.rails-ai-context]").size).to eq(1)
          expect(toml).not_to include(%(command = "old"))

          expect(described_class.remove(tools: %i[codex], output_dir: dir)).to eq([ path ])
          expect(File.exist?(path)).to be(false)
        end
      end

      it "says where a config stopped parsing, when the parser says" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, ".mcp.json"), %({"mcpServers": {"a": {},}}\n))

          result = described_class.new(tools: %i[claude], output_dir: dir, tool_mode: :mcp, standalone: true).call

          expect(result[:reasons].values.first).to match(/\Ait does not parse as JSON( at line \d+,? column \d+)? \(a trailing comma\?\)/)
        end
      end

      it "reads a // inside a string as no comment" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, ".mcp.json"), %({"mcpServers": {"api": {"url": "https://x.example/mcp", "note": "a \\" // b"}}}\n))

          result = described_class.new(tools: [ :claude ], output_dir: dir, tool_mode: :mcp, standalone: true).call

          expect(result[:written]).to eq([ File.join(dir, ".mcp.json") ])
          expect(JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"].keys).to eq(%w[api rails-ai-context])
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

    # merge_json used to rescue JSON::ParserError only, so an existing but
    # unreadable config raised Errno::EACCES out of the whole install.
    context "when a config file cannot be read or written" do
      before { skip "root can read anything" if Process.uid.zero? }

      it "reports the unreadable file as failed and keeps going" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, ".mcp.json"), "{}")
          File.chmod(0o000, File.join(dir, ".mcp.json"))

          result = described_class.new(tools: %i[claude cursor], output_dir: dir, tool_mode: :mcp).call

          expect(result[:failed]).to eq([ File.join(dir, ".mcp.json") ])
          expect(result[:written]).to eq([ File.join(dir, ".cursor/mcp.json") ])
        ensure
          File.chmod(0o600, File.join(dir, ".mcp.json"))
        end
      end

      it "reports an unwritable TOML config as failed" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, ".codex"))
          File.write(File.join(dir, ".codex/config.toml"), "[other]\n")
          File.chmod(0o500, File.join(dir, ".codex"))

          result = described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp).call

          expect(result[:failed]).to eq([ File.join(dir, ".codex/config.toml") ])
        ensure
          File.chmod(0o700, File.join(dir, ".codex"))
        end
      end

      it "does not raise out of .remove when the config cannot be read" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, ".mcp.json"), "{}")
          File.chmod(0o000, File.join(dir, ".mcp.json"))

          expect(described_class.remove(tools: [ :claude ], output_dir: dir)).to eq([])
        ensure
          File.chmod(0o600, File.join(dir, ".mcp.json"))
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

  # A folder of apps: one server per app in the folder's own configs, since
  # a client reads them from the folder it opened and from nowhere below.
  describe "workspace servers" do
    let(:servers) do
      [
        described_class::Server.new(name: "rails-ai-context-a", standalone: true, app_path: "a"),
        described_class::Server.new(name: "rails-ai-context-b", standalone: false, app_path: "group/b",
                                    gemfile: "group/b/Gemfile")
      ]
    end

    def generate(dir, tools: self.tools)
      described_class.new(tools: tools, output_dir: dir, tool_mode: :mcp, servers: servers).call
    end

    it "writes one entry per app, each naming its app and an in-Gemfile app's Gemfile" do
      Dir.mktmpdir do |dir|
        generate(dir)

        # Claude Code starts a server in the folder it was launched in.
        claude = JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"]
        expect(claude.keys).to eq(%w[rails-ai-context-a rails-ai-context-b])
        expect(claude["rails-ai-context-a"]).to eq("command" => "rails-ai-context", "args" => %w[serve --app-path a])
        expect(claude["rails-ai-context-b"]).to eq(
          "command" => "bundle", "args" => %w[exec rails-ai-context serve --app-path group/b],
          "env" => { "BUNDLE_GEMFILE" => "group/b/Gemfile" }
        )

        # Cursor does not promise a working directory; it and VS Code name
        # the folder their config sits in.
        cursor = JSON.parse(File.read(File.join(dir, ".cursor/mcp.json")))["mcpServers"]
        vscode = JSON.parse(File.read(File.join(dir, ".vscode/mcp.json")))["servers"]
        [ cursor, vscode ].each do |entries|
          expect(entries["rails-ai-context-a"]).to eq(
            "command" => "rails-ai-context", "args" => [ "serve", "--app-path", "${workspaceFolder}/a" ]
          )
          expect(entries["rails-ai-context-b"]).to eq(
            "command" => "bundle", "args" => [ "exec", "rails-ai-context", "serve", "--app-path", "${workspaceFolder}/group/b" ],
            "env" => { "BUNDLE_GEMFILE" => "${workspaceFolder}/group/b/Gemfile" }
          )
        end

        opencode = JSON.parse(File.read(File.join(dir, "opencode.json")))["mcp"]
        expect(opencode["rails-ai-context-b"]).to eq(
          "type" => "local", "command" => %w[bundle exec rails-ai-context serve --app-path group/b],
          "environment" => { "BUNDLE_GEMFILE" => "group/b/Gemfile" }
        )
        expect(opencode["rails-ai-context-a"]).not_to have_key("environment")

        toml = File.read(File.join(dir, ".codex/config.toml"))
        expect(toml).to include(%([mcp_servers.rails-ai-context-a]\ncommand = "rails-ai-context"\nargs = ["serve", "--app-path", "a"]\n))
        expect(toml).to include(%(args = ["exec", "rails-ai-context", "serve", "--app-path", "group/b"]))
        b_env = toml[/^\[mcp_servers\.rails-ai-context-b\.env\]\n(.*?)(?=\n\[|\z)/m, 1]
        expect(b_env).to include(%(BUNDLE_GEMFILE = "group/b/Gemfile"))
        a_env = toml[/^\[mcp_servers\.rails-ai-context-a\.env\]\n(.*?)(?=\n\[|\z)/m, 1].to_s
        expect(a_env).not_to include("BUNDLE_GEMFILE")
      end
    end

    it "skips every file on a second identical run" do
      Dir.mktmpdir do |dir|
        generate(dir)
        result = generate(dir)
        expect(result[:written]).to be_empty
        expect(result[:skipped].size).to eq(5)
      end
    end

    # The bare entry serves the folder it starts in, and a workspace is no
    # app, so it can only fail.
    it "drops the bare entry and keeps everyone else's" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".mcp.json"), JSON.pretty_generate(
          "mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] },
                            "other" => { "command" => "node" } }
        ))
        FileUtils.mkdir_p(File.join(dir, ".codex"))
        File.write(File.join(dir, ".codex/config.toml"), <<~TOML)
          model = "o3"

          [mcp_servers.rails-ai-context]
          command = "rails-ai-context"
          args = ["serve"]

          [mcp_servers.rails-ai-context.env]
          PATH = "/old"

          [mcp_servers.other]
          command = "node"
        TOML

        generate(dir, tools: %i[claude codex])

        expect(JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"].keys)
          .to eq(%w[other rails-ai-context-a rails-ai-context-b])
        toml = File.read(File.join(dir, ".codex/config.toml"))
        expect(toml).not_to match(/^\[mcp_servers\.rails-ai-context(\.env)?\]$/)
        expect(toml).not_to include("/old")
        expect(toml).to start_with(%(model = "o3"\n\n[mcp_servers.other]\ncommand = "node"\n\n[mcp_servers.rails-ai-context-a]))
        expect(toml).not_to include("\n\n\n")
      end
    end

    # The gem writes no entry without a command: an HTTP one under the bare
    # name is somebody's own.
    it "keeps a bare entry that runs no command" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".mcp.json"), JSON.generate("mcpServers" => {
          "rails-ai-context" => { "type" => "http", "url" => "http://localhost:6029/mcp" }
        }))

        generate(dir, tools: %i[claude])
        described_class.remove(tools: %i[cursor], output_dir: dir)

        expect(JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"].keys)
          .to eq(%w[rails-ai-context rails-ai-context-a rails-ai-context-b])
        expect(described_class.remove(tools: %i[claude], output_dir: dir).size).to eq(1)
        expect(JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"].keys).to eq(%w[rails-ai-context])
      end
    end

    it "keeps an app's own bare entry when it writes one" do
      Dir.mktmpdir do |dir|
        described_class.new(tools: [ :claude ], output_dir: dir, tool_mode: :mcp, standalone: true).call
        described_class.new(tools: [ :claude ], output_dir: dir, tool_mode: :mcp, standalone: true).call
        expect(JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"].keys).to eq(%w[rails-ai-context])
      end
    end

    # Re-running init after an app went away, or after an app with the same
    # folder name arrived and renamed this one, leaves no entry behind that
    # can only fail or doubles another.
    context "with entries of ours from an earlier run" do
      around do |example|
        Dir.mktmpdir do |dir|
          @dir = dir
          FileUtils.mkdir_p(File.join(dir, "a"))
          FileUtils.mkdir_p(File.join(dir, "group/b"))
          FileUtils.mkdir_p(File.join(dir, "elsewhere"))
          example.run
        end
      end

      def entry(path, folder: nil)
        { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", folder ? "#{folder}/#{path}" : path ] }
      end

      it "drops an entry whose app is gone and one that names a current app by an old name" do
        File.write(File.join(@dir, ".mcp.json"), JSON.generate("mcpServers" => {
          "rails-ai-context-gone" => entry("gone"),
          "rails-ai-context-b" => entry("group/b"),
          "rails-ai-context-elsewhere" => entry("elsewhere"),
          "rails-ai-context-http" => { "url" => "http://localhost:6029/mcp" },
          "mine" => { "command" => "node" }
        }))
        servers_without_b_name = [ servers.first,
                                   described_class::Server.new(name: "rails-ai-context-group-b", standalone: true, app_path: "group/b") ]

        described_class.new(tools: [ :claude ], output_dir: @dir, tool_mode: :mcp, servers: servers_without_b_name).call

        expect(JSON.parse(File.read(File.join(@dir, ".mcp.json")))["mcpServers"].keys)
          .to eq(%w[rails-ai-context-elsewhere rails-ai-context-http mine rails-ai-context-a rails-ai-context-group-b])
      end

      # A second entry for the same app, made by hand, is somebody's choice.
      it "keeps a hand-named entry for a current app" do
        File.write(File.join(@dir, ".mcp.json"), JSON.generate("mcpServers" => { "rails-ai-context-readonly" => entry("a") }))

        described_class.new(tools: [ :claude ], output_dir: @dir, tool_mode: :mcp, servers: servers).call

        expect(JSON.parse(File.read(File.join(@dir, ".mcp.json")))["mcpServers"].keys)
          .to eq(%w[rails-ai-context-readonly rails-ai-context-a rails-ai-context-b])
      end

      it "reads a stale entry's app through the tool's name for its folder" do
        FileUtils.mkdir_p(File.join(@dir, ".cursor"))
        File.write(File.join(@dir, ".cursor/mcp.json"), JSON.generate("mcpServers" => {
          "rails-ai-context-gone" => entry("gone", folder: "${workspaceFolder}"),
          "rails-ai-context-elsewhere" => entry("elsewhere", folder: "${workspaceFolder}")
        }))

        described_class.new(tools: [ :cursor ], output_dir: @dir, tool_mode: :mcp, servers: servers).call

        expect(JSON.parse(File.read(File.join(@dir, ".cursor/mcp.json")))["mcpServers"].keys)
          .to eq(%w[rails-ai-context-elsewhere rails-ai-context-a rails-ai-context-b])
      end

      it "drops a stale Codex section and keeps the rest of the file" do
        FileUtils.mkdir_p(File.join(@dir, ".codex"))
        File.write(File.join(@dir, ".codex/config.toml"), <<~TOML)
          [mcp_servers.rails-ai-context-gone]
          command = "rails-ai-context"
          args = ["serve", "--app-path", "gone"]

          [mcp_servers.rails-ai-context-gone.env]
          PATH = "/x"

          [mcp_servers.other]
          command = "node"
        TOML

        described_class.new(tools: [ :codex ], output_dir: @dir, tool_mode: :mcp, servers: servers).call

        toml = File.read(File.join(@dir, ".codex/config.toml"))
        expect(toml).not_to include("rails-ai-context-gone")
        expect(toml).to start_with(%([mcp_servers.other]\ncommand = "node"\n\n[mcp_servers.rails-ai-context-a]))
      end

      # An app that only a teammate's machine has, or one named through a
      # variable the tool expands, is no app this run can judge gone. A
      # numbered name the gem gave an app that has its own name now is its
      # own leftover: kept, the app had two servers.
      it "keeps entries it cannot judge, and drops a numbered one of its own" do
        FileUtils.mkdir_p(File.join(@dir, ".cursor"))
        File.write(File.join(@dir, ".cursor/mcp.json"), JSON.generate("mcpServers" => {
          "rails-ai-context-prod" => { "command" => "rails-ai-context", "args" => %w[serve --app-path ${userHome}/apps/prod] },
          "rails-ai-context-shared" => { "command" => "rails-ai-context", "args" => %w[serve --app-path /mnt/teammate-only/app] },
          "rails-ai-context-a-2" => entry("a", folder: "${workspaceFolder}")
        }))

        described_class.new(tools: [ :cursor ], output_dir: @dir, tool_mode: :mcp, servers: servers).call

        expect(JSON.parse(File.read(File.join(@dir, ".cursor/mcp.json")))["mcpServers"].keys)
          .to eq(%w[rails-ai-context-prod rails-ai-context-shared rails-ai-context-a rails-ai-context-b])
      end

      # taplo and Even Better TOML wrap a long array, one element a line.
      it "reads a Codex section a formatter wrapped as the gem's" do
        FileUtils.mkdir_p(File.join(@dir, ".codex"))
        File.write(File.join(@dir, ".codex/config.toml"), <<~TOML)
          [mcp_servers.rails-ai-context-gone]
          command = "bundle" # the app's bundle
          args = [
            "exec",
            'rails-ai-context',
            "serve", # the server
            "--app-path",
            "gone",
          ]

          [mcp_servers.other]
          command = "node"
        TOML

        described_class.new(tools: [ :codex ], output_dir: @dir, tool_mode: :mcp, servers: servers).call

        toml = File.read(File.join(@dir, ".codex/config.toml"))
        expect(toml).not_to include("rails-ai-context-gone")
        expect(toml).to start_with(%([mcp_servers.other]\ncommand = "node"\n\n[mcp_servers.rails-ai-context-a]))
      end

      # A comment over a header may be a key of the table before it, set
      # aside by hand, so it stays.
      it "keeps the comment over a stale section's header, and leaves no blank line at the end" do
        FileUtils.mkdir_p(File.join(@dir, ".codex"))
        current = described_class.new(tools: [ :codex ], output_dir: @dir, tool_mode: :mcp, servers: servers)
        current.call
        written = File.read(File.join(@dir, ".codex/config.toml"))
        File.write(File.join(@dir, ".codex/config.toml"), <<~TOML + written + <<~GONE)
          # about other
          [mcp_servers.other]
          command = "node"

        TOML

          # my old app
          [mcp_servers.rails-ai-context-gone]
          command = "rails-ai-context"
          args = ["serve", "--app-path", "gone"]
        GONE

        current.call

        expect(File.read(File.join(@dir, ".codex/config.toml")))
          .to eq(%(# about other\n[mcp_servers.other]\ncommand = "node"\n\n) + written + "\n# my old app\n")
      end
    end

    it "carries the announced name in each entry's environment" do
      Dir.mktmpdir do |dir|
        announced = [ described_class::Server.new(name: "rails-ai-context-a", standalone: true, app_path: "a",
                                                  announce: "a-rails-ai-context") ]

        described_class.new(tools: %i[claude opencode codex], output_dir: dir, tool_mode: :mcp, servers: announced).call

        expect(JSON.parse(File.read(File.join(dir, ".mcp.json"))).dig("mcpServers", "rails-ai-context-a", "env"))
          .to eq("RAILS_AI_CONTEXT_SERVER_NAME" => "a-rails-ai-context")
        expect(JSON.parse(File.read(File.join(dir, "opencode.json"))).dig("mcp", "rails-ai-context-a", "environment"))
          .to eq("RAILS_AI_CONTEXT_SERVER_NAME" => "a-rails-ai-context")
        expect(File.read(File.join(dir, ".codex/config.toml"))).to include(%(RAILS_AI_CONTEXT_SERVER_NAME = "a-rails-ai-context"))
      end
    end

    # VS Code's mcp.json reads comments and trailing commas; a folder's is
    # the likelier to be kept by hand, so a workspace write leaves it be.
    it "leaves a config that does not parse as JSON alone" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".vscode"))
        jsonc = %({\n  // mine\n  "servers": { "github": { "url": "https://api.example/mcp" }, },\n}\n)
        File.write(File.join(dir, ".vscode/mcp.json"), jsonc)

        result = generate(dir, tools: [ :copilot ])

        expect(result[:failed]).to eq([ File.join(dir, ".vscode/mcp.json") ])
        expect(File.read(File.join(dir, ".vscode/mcp.json"))).to eq(jsonc)
        # json 3 refuses the comment json 2 passed over: named for it either way.
        expect(result[:reasons][File.join(dir, ".vscode/mcp.json")]).to include("it holds comments")

        File.write(File.join(dir, ".vscode/mcp.json"), jsonc.sub("  // mine\n", ""))
        result = generate(dir, tools: [ :copilot ])
        expect(result[:reasons][File.join(dir, ".vscode/mcp.json")]).to include("does not parse as JSON")
      end
    end

    it "reports a config that is JSON but no object as failed and leaves it alone" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".mcp.json"), %([{"command": "x"}]\n))
        allow(RailsAiContext).to receive(:log_warn)

        result = generate(dir, tools: [ :claude ])

        expect(result[:failed]).to eq([ File.join(dir, ".mcp.json") ])
        expect(File.read(File.join(dir, ".mcp.json"))).to eq(%([{"command": "x"}]\n))
      end
    end

    it "reports a servers key that is not an object as failed and leaves the file alone" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".mcp.json"), %({"mcpServers": ["x"]}\n))
        allow(RailsAiContext).to receive(:log_warn)

        result = generate(dir, tools: [ :claude ])

        expect(result[:failed]).to eq([ File.join(dir, ".mcp.json") ])
        expect(File.read(File.join(dir, ".mcp.json"))).to eq(%({"mcpServers": ["x"]}\n))
      end
    end
  end

  # Codex's config is read by lines, with no TOML parser: what the gem needs
  # of a section is its command line and its env table.
  describe RailsAiContext::McpConfigGenerator::Toml do
    it "reads the strings at the start of a value, however a formatter wrapped them" do
      expect(described_class.strings(%("rails-ai-context" # the binary\n))).to eq([ "rails-ai-context" ])
      expect(described_class.strings(%('C:\\Ruby\\bin'\n))).to eq([ "C:\\Ruby\\bin" ])
      expect(described_class.strings(%(["serve", 'x'] # c\nnext = "no"\n))).to eq(%w[serve x])
      expect(described_class.strings(%([\n  "a", # one\n  "b",\n]\n))).to eq(%w[a b])
      expect(described_class.strings(%("say \\"hi\\" caf\\u00e9"\n))).to eq([ %(say "hi" caf\u00e9) ])
      expect(described_class.strings("3\n")).to eq([])
    end

    it "reads a section's command line from its own table, not its sub-tables" do
      lines = <<~TOML.lines
        [mcp_servers.rails-ai-context-a]
        command = "bundle"
        args = [
          "exec", "rails-ai-context", "serve",
        ]

        [mcp_servers.rails-ai-context-a.env]
        command = "not this"
        GEM_HOME = "/gems"
      TOML
      range, name = described_class.sections(lines) { |found| found == "rails-ai-context-a" }.first

      expect(described_class.argv(lines, range)).to eq(%w[bundle exec rails-ai-context serve])
      expect(described_class.sub_table(lines, range, name, "env")).to eq("command" => "not this", "GEM_HOME" => "/gems")
      expect(described_class.sub_table(lines, range, name, "other")).to eq({})
    end
  end

  # The sections are found by lines, so what sits around them must come
  # through byte for byte.
  describe "Codex TOML sections" do
    it "writes its section in a Windows-line-ended file's own line ending, and skips it the next time" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".codex"))
        File.write(File.join(dir, ".codex/config.toml"), %(model = "o3"\r\n))

        first = described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp, standalone: true).call
        second = described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp, standalone: true).call

        toml = File.read(File.join(dir, ".codex/config.toml"))
        expect(toml.scan("\n").size).to eq(toml.scan("\r\n").size)
        expect([ first[:written].size, second[:skipped].size ]).to eq([ 1, 1 ])
      end
    end

    def write_codex(dir, content)
      FileUtils.mkdir_p(File.join(dir, ".codex"))
      File.write(File.join(dir, ".codex/config.toml"), content)
    end

    def codex(dir)
      File.read(File.join(dir, ".codex/config.toml"))
    end

    it "ends a section at the next table even with no blank line before it" do
      Dir.mktmpdir do |dir|
        write_codex(dir, %([mcp_servers.rails-ai-context]\ncommand = "old"\n[profiles.fast]\nmodel = "o4"\n))

        described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp).call

        expect(codex(dir)).to include(%([profiles.fast]\nmodel = "o4"\n))
        expect(codex(dir)).not_to include(%(command = "old"))
      end
    end

    it "leaves a comment over the next table with that table" do
      Dir.mktmpdir do |dir|
        write_codex(dir, %([mcp_servers.rails-ai-context]\ncommand = "old"\n\n# my server\n[mcp_servers.other]\ncommand = "node"\n))

        described_class.remove(tools: [ :codex ], output_dir: dir)

        expect(codex(dir)).to eq(%(# my server\n[mcp_servers.other]\ncommand = "node"\n))
      end
    end

    it "does not take another server whose name starts with ours for one of our sub-tables" do
      Dir.mktmpdir do |dir|
        write_codex(dir, %([mcp_servers.rails-ai-context]\ncommand = "old"\n\n[mcp_servers.rails-ai-context-a]\ncommand = "a"\n))

        described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp, standalone: true).call

        expect(codex(dir)).to include(%([mcp_servers.rails-ai-context-a]\ncommand = "a"\n))
        expect(codex(dir).scan("[mcp_servers.rails-ai-context]").size).to eq(1)
      end
    end

    # Ruby's inspect writes `\#{` and `\e`, neither of which TOML accepts.
    it "writes values as TOML basic strings" do
      Dir.mktmpdir do |dir|
        stub_const("ENV", ENV.to_h.merge("GEM_HOME" => %(/x/\#{y}/"q"/\e)))

        described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp).call

        expect(codex(dir)).to include(%(GEM_HOME = "/x/\#{y}/\\"q\\"/\\u001b"))
      end
    end

    def codex_path(dir) = File.join(dir, ".codex/config.toml")

    def write_server(dir)
      described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp, standalone: true).call
    end

    # TOML lets a key be quoted, and [mcp_servers."rails-ai-context"] is
    # [mcp_servers.rails-ai-context] to Codex: the table written beside it
    # declared the server twice, which Codex refuses to read.
    it "replaces a table whose name is quoted where it stands" do
      Dir.mktmpdir do |dir|
        write_codex(dir, %(model = "o3"\n\n[mcp_servers."rails-ai-context"]\ncommand = "old"\n\n) +
                         %([ mcp_servers . 'rails-ai-context' . env ]\nX = "1"\n\n[profiles.fast]\nmodel = "o4"\n))

        expect(write_server(dir)[:written]).to eq([ codex_path(dir) ])

        expect(codex(dir)).to start_with(%(model = "o3"\n\n[mcp_servers.rails-ai-context]\ncommand = "rails-ai-context"\n))
        expect(codex(dir)).to end_with(%(\n\n[profiles.fast]\nmodel = "o4"\n))
        expect(codex(dir)).not_to include(%("rails-ai-context"]), "'rails-ai-context'", %(command = "old"), %(X = "1"))
        expect(write_server(dir)[:skipped]).to eq([ codex_path(dir) ])
      end
    end

    it "merges two tables of the gem's server, one name quoted, into one" do
      Dir.mktmpdir do |dir|
        write_codex(dir, %([mcp_servers."rails-ai-context"]\ncommand = "old"\n\n[mcp_servers.rails-ai-context]\ncommand = "older"\n))

        write_server(dir)

        expect(codex(dir).scan("[mcp_servers.").size).to eq(2) # the server and its env
        expect(codex(dir)).to start_with(%([mcp_servers.rails-ai-context]\ncommand = "rails-ai-context"\n))
      end
    end

    # A table added beside an entry spelled any other way declares the
    # server twice; the entry cannot be rewritten in its own form either.
    it "leaves the gem's entry set as an inline table or with dotted keys as it is, and says why" do
      {
        "inline" => %([mcp_servers]\nrails-ai-context = { command = "rails-ai-context", args = ["serve"] }\n),
        "dotted" => %([mcp_servers]\nrails-ai-context.command = "rails-ai-context"\nrails-ai-context.args = ["serve"]\n),
        "root dotted" => %(model = "o3"\nmcp_servers.rails-ai-context.command = "rails-ai-context"\n),
        "inline mcp_servers" => %(mcp_servers = { rails-ai-context = { command = "rails-ai-context" } }\n),
        "a detached env table" => %([mcp_servers.rails-ai-context.env]\nX = "1"\n\n[mcp_servers]\nrails-ai-context.command = "x"\n)
      }.each do |form, content|
        Dir.mktmpdir do |dir|
          write_codex(dir, content)

          result = write_server(dir)

          expect(codex(dir)).to eq(content), form
          expect(result[:failed]).to eq([ codex_path(dir) ]), form
          expect(result[:reasons][codex_path(dir)]).to match(/inline table|dotted keys/), form
        end
      end
    end

    it "keeps someone else's inline entry under the gem's name in place of the gem's" do
      Dir.mktmpdir do |dir|
        content = %([mcp_servers]\nrails-ai-context = { url = "http://localhost:6029/mcp" }\n)
        write_codex(dir, content)

        result = write_server(dir)

        expect(codex(dir)).to eq(content)
        expect(result[:skipped]).to eq([ codex_path(dir) ])
        expect(result[:notes][codex_path(dir)]).to start_with("kept rails-ai-context")
      end
    end

    it "leaves a config that declares the gem's server twice as it is, and says so" do
      Dir.mktmpdir do |dir|
        content = %([mcp_servers]\nrails-ai-context = { command = "rails-ai-context" }\n\n[mcp_servers.rails-ai-context]\ncommand = "x"\n)
        write_codex(dir, content)

        result = write_server(dir)

        expect(codex(dir)).to eq(content)
        expect(result[:reasons][codex_path(dir)]).to start_with("it declares rails-ai-context twice, which Codex refuses to read")
      end
    end

    it "adds no table to a config whose mcp_servers is one inline table" do
      Dir.mktmpdir do |dir|
        content = %(mcp_servers = { github = { command = "gh-mcp" } }\n)
        write_codex(dir, content)

        result = write_server(dir)

        expect(codex(dir)).to eq(content)
        expect(result[:reasons][codex_path(dir)]).to start_with("its mcp_servers is an inline table")
      end
    end

    it "reads a header inside a multi-line string as the string's text" do
      Dir.mktmpdir do |dir|
        write_codex(dir, %(notes = """\n[mcp_servers.rails-ai-context]\ncommand = "old"\n"""\n))

        write_server(dir)

        expect(codex(dir)).to start_with(%(notes = """\n[mcp_servers.rails-ai-context]\ncommand = "old"\n"""\n\n[mcp_servers.rails-ai-context]\n))
      end
    end

    it "leaves the gem's inline entry in place on removal, and says why" do
      Dir.mktmpdir do |dir|
        content = %([mcp_servers]\nrails-ai-context = { command = "rails-ai-context", args = ["serve"] }\n)
        write_codex(dir, content)
        reasons = []

        cleaned = described_class.remove(tools: [ :codex ], output_dir: dir, warn: ->(_path, reason) { reasons << reason })

        expect(cleaned).to eq([])
        expect(codex(dir)).to eq(content)
        expect(reasons).to eq([ "it sets rails-ai-context as an inline table or with dotted keys, which the install does not " \
                                "rewrite, so it is left as it is. Remove it by hand" ])
      end
    end
  end

  describe "a config that is not ASCII" do
    def codex(dir) = File.join(dir, ".codex/config.toml")

    it "reads a UTF-8 file whatever the locale says" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".codex"))
        File.write(codex(dir), %(# café\n[mcp_servers.rails-ai-context]\ncommand = "old"\n), encoding: "UTF-8")
        previous = Encoding.default_external
        begin
          silence_warnings { Encoding.default_external = Encoding::US_ASCII }
          described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp, standalone: true).call
        ensure
          silence_warnings { Encoding.default_external = previous }
        end

        content = File.binread(codex(dir)).force_encoding("UTF-8")
        expect(content).to start_with("# café\n[mcp_servers.rails-ai-context]\ncommand = \"rails-ai-context\"")
      end
    end

    it "writes every byte of a file that is not UTF-8 back as it came" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".codex"))
        latin1 = "# caf\xE9\n[profiles.fast]\nmodel = \"o4\"\n".b
        File.binwrite(codex(dir), latin1)

        described_class.new(tools: [ :codex ], output_dir: dir, tool_mode: :mcp, standalone: true).call
        described_class.remove(tools: [ :codex ], output_dir: dir)

        expect(File.binread(codex(dir))).to eq(latin1)
      end
    end
  end

  describe ".serving_config" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(File.join(@dir, path)))
      File.write(File.join(@dir, path), content)
    end

    def entry(app_path)
      { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", app_path ] }
    end

    it "is the app's own config first" do
      write("work/a/.mcp.json", "{}")
      write("work/.mcp.json", JSON.generate("mcpServers" => { "rails-ai-context-a" => entry("a") }))
      expect(described_class.serving_config(File.join(@dir, "work/a"), :claude)).to eq(File.join(@dir, "work/a/.mcp.json"))
    end

    it "is a workspace's one or two levels up whose entry names the app" do
      write("work/.mcp.json", JSON.generate("mcpServers" => { "rails-ai-context-b" => entry("group/b") }))
      write("work/.codex/config.toml", %([mcp_servers.rails-ai-context-a]\ncommand = "rails-ai-context"\nargs = ["serve", "--app-path", "a"]\n))
      write("work/opencode.json", JSON.generate("mcp" => { "rails-ai-context-a" => { "type" => "local", "command" => [ "rails-ai-context", "serve", "--app-path=a" ] } }))

      expect(described_class.serving_config(File.join(@dir, "work/group/b"), :claude)).to eq(File.join(@dir, "work/.mcp.json"))
      expect(described_class.serving_config(File.join(@dir, "work/a"), :codex)).to eq(File.join(@dir, "work/.codex/config.toml"))
      expect(described_class.serving_config(File.join(@dir, "work/a"), :opencode)).to eq(File.join(@dir, "work/opencode.json"))
    end

    it "reads the tool's name for its folder as that folder" do
      write("work/.cursor/mcp.json", JSON.generate("mcpServers" => {
        "rails-ai-context-b" => { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", "${workspaceFolder}/group/b" ] }
      }))
      expect(described_class.serving_config(File.join(@dir, "work/group/b"), :cursor)).to eq(File.join(@dir, "work/.cursor/mcp.json"))
    end

    it "is nothing when the config above serves other apps, or is no object" do
      write("work/.mcp.json", JSON.generate("mcpServers" => { "rails-ai-context-a" => entry("a") }))
      write("work/.vscode/mcp.json", "[1, 2]")
      expect(described_class.serving_config(File.join(@dir, "work/b"), :claude)).to be_nil
      expect(described_class.serving_config(File.join(@dir, "work/a"), :copilot)).to be_nil
    end

    it "ignores a server the gem did not write" do
      write("work/.mcp.json", JSON.generate("mcpServers" => { "mine" => entry("a") }))
      expect(described_class.serving_config(File.join(@dir, "work/a"), :claude)).to be_nil
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

    # The write goes through SafeFile.atomic_write; a spy is the only way to
    # see the helper itself, so this pins the end state it guarantees.
    it "leaves no temp file behind and writes the trimmed config" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".mcp.json")
        content = {
          "mcpServers" => {
            "rails-ai-context" => { "command" => "bundle" },
            "other-server" => { "command" => "node" }
          }
        }
        File.write(path, JSON.pretty_generate(content))

        described_class.remove(tools: [ :claude ], output_dir: dir)

        expect(Dir.glob(File.join(dir, "*.tmp"), File::FNM_DOTMATCH)).to be_empty
        expect(JSON.parse(File.read(path))["mcpServers"].keys).to eq([ "other-server" ])
      end
    end

    # A workspace entry is one of ours too, and a dropped tool leaves none.
    # One that only shares the name - a hand-made HTTP entry - is its
    # maker's, and stays.
    it "removes every entry the gem wrote, workspace ones included" do
      Dir.mktmpdir do |dir|
        own = ->(app) { { "command" => "bundle", "args" => [ "exec", "rails-ai-context", "serve", "--app-path", app ] } }
        File.write(File.join(dir, ".mcp.json"), JSON.generate(
          "mcpServers" => { "rails-ai-context-a" => own.("a"), "rails-ai-context-b" => own.("b"),
                            "rails-ai-context-prod" => { "url" => "https://prod.example/mcp" },
                            "rails-ai-contextual" => {}, "other" => {} }
        ))
        FileUtils.mkdir_p(File.join(dir, ".codex"))
        File.write(File.join(dir, ".codex/config.toml"), <<~TOML)
          [mcp_servers.rails-ai-context-a]
          command = "rails-ai-context"
          args = ["serve", "--app-path", "a"]

          [mcp_servers.rails-ai-context-a.env]
          PATH = "/x"

          [mcp_servers.other]
          command = "node"

          [mcp_servers.rails-ai-context-b]
          command = "rails-ai-context"
          args = ["serve", "--app-path", "b"]
        TOML

        cleaned = described_class.remove(tools: %i[claude codex], output_dir: dir)

        expect(cleaned.size).to eq(2)
        expect(JSON.parse(File.read(File.join(dir, ".mcp.json")))["mcpServers"].keys)
          .to eq(%w[rails-ai-context-prod rails-ai-contextual other])
        expect(File.read(File.join(dir, ".codex/config.toml"))).to eq(%([mcp_servers.other]\ncommand = "node"\n))
      end
    end

    it "leaves a config that holds comments as it is, and names the entries to remove" do
      Dir.mktmpdir do |dir|
        commented = %({\n  // ours\n  "mcpServers": { "rails-ai-context": { "command": "rails-ai-context", "args": ["serve"] } }\n}\n)
        File.write(File.join(dir, ".mcp.json"), commented)
        said = []

        cleaned = described_class.remove(tools: [ :claude ], output_dir: dir, warn: ->(path, reason) { said << [ path, reason ] })

        expect(cleaned).to be_empty
        expect(File.read(File.join(dir, ".mcp.json"))).to eq(commented)
        expect(said).to contain_exactly([ File.join(dir, ".mcp.json"), a_string_including("so it is left as it is", "Remove rails-ai-context from it by hand") ])
      end
    end

    # Dropping a tool leaves a file it cannot read as it is, and says so
    # when the file names the gem.
    it "says why it leaves a config that does not parse, and only when it names the gem" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".vscode"))
        File.write(File.join(dir, ".vscode/mcp.json"), %({"servers": {"rails-ai-context": {"command": "rails-ai-context"},}}))
        File.write(File.join(dir, ".mcp.json"), %({"mcpServers": {"other": {},}}))
        said = []

        cleaned = described_class.remove(tools: %i[copilot claude], output_dir: dir, warn: ->(path, reason) { said << [ path, reason ] })

        expect(cleaned).to be_empty
        expect(said).to contain_exactly(
          [ File.join(dir, ".vscode/mcp.json"), a_string_including("does not parse as JSON", "Remove its rails-ai-context entries by hand") ]
        )
      end
    end

    it "keeps a Codex config's Windows line endings" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".codex"))
        crlf =%(model = "o3"\r\n\r\n[mcp_servers.rails-ai-context]\r\ncommand = "rails-ai-context"\r\nargs = ["serve"]\r\n\r\n\r\n[mcp_servers.other]\r\ncommand = "node"\r\n)
        File.write(File.join(dir, ".codex/config.toml"), crlf)

        described_class.remove(tools: [ :codex ], output_dir: dir)

        expect(File.read(File.join(dir, ".codex/config.toml"))).to eq(%(model = "o3"\r\n\r\n[mcp_servers.other]\r\ncommand = "node"\r\n))
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
