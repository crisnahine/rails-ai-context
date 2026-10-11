# frozen_string_literal: true

require_relative "e2e_helper"

module E2E
  # The MCP client that mcp_client_launch_spec runs with node. The launch
  # comes in E2E_MCP_LAUNCH as JSON rather than on the command line, which
  # Windows would have to quote.
  NODE_MCP_CLIENT = <<~'JS'
    const { spawn } = require("child_process");
    const launch = JSON.parse(process.env.E2E_MCP_LAUNCH);
    const env = Object.assign({}, process.env, launch.env);
    delete env.E2E_MCP_LAUNCH;
    const report = { response: null, error: null, exit: null, stderr: "" };
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      process.stdout.write(JSON.stringify(report) + "\n");
    };
    const child = spawn(launch.command, launch.args, { cwd: launch.cwd, env: env });
    const timer = setTimeout(() => {
      report.error = report.response ? "still running after its stdin closed" : "no answer to initialize";
      child.kill();
      finish();
    }, launch.timeout * 1000);
    child.on("error", (error) => { report.error = `${error.code}: ${error.message}`; finish(); });
    child.stderr.on("data", (chunk) => { report.stderr += chunk; });
    let buffered = "";
    child.stdout.on("data", (chunk) => {
      buffered += chunk;
      let newline;
      while ((newline = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, newline);
        buffered = buffered.slice(newline + 1);
        let message;
        try { message = JSON.parse(line); } catch (_) { continue; }
        // Answers are matched by id: a server may send notifications first.
        if (message.id === 1 && !report.response) {
          report.response = message;
          child.stdin.end();
        }
      }
    });
    child.on("close", (code, signal) => { report.exit = { code: code, signal: signal }; finish(); });
    child.stdin.write(JSON.stringify({
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "e2e-node-spawn", version: "0.0.0" } }
    }) + "\n");
  JS
end

# Claude Code, a Node program, starts the stdio server an entry of .mcp.json
# names with child_process.spawn(command, args, { cwd, env }) and no shell:
# the command has to be one the OS starts by itself. On Windows a binstub is
# a .bat file, which needs a shell, so the configs start the server through
# `cmd /c` there. This starts each install's server exactly that way, says
# `initialize`, reads the answer to it, and ends the session as a client
# does, by closing the server's stdin.
RSpec.describe "E2E: the server an app's .mcp.json names, started as Claude Code starts it", type: :e2e do
  before(:all) do
    @node = E2E::Platform.executable("node")
    skip "node is not on PATH: this starts the server the way Claude Code, a Node program, does" unless @node

    @client_script = File.join(E2E.root, "mcp_client_launch.js")
    File.write(@client_script, E2E::NODE_MCP_CLIENT)
  end

  # The Claude Code entry, as the install wrote it, and what node's spawn made
  # of it: { "response", "error", "exit", "stderr" }.
  def launch_from_mcp_json(app)
    entry = JSON.parse(File.read(File.join(app.app_path, ".mcp.json"))).dig("mcpServers", "rails-ai-context")
    launch = { command: entry["command"], args: entry["args"] || [], env: entry["env"] || {}, cwd: app.app_path, timeout: 90 }
    # The client's own environment: no BUNDLE_GEMFILE, which bundle exec
    # finds from the working directory.
    env = app.env.merge("BUNDLE_GEMFILE" => nil, "E2E_MCP_LAUNCH" => JSON.generate(launch))
    out, err, status = Open3.capture3(env, @node, @client_script)
    expect(status.success?).to be(true), "node failed:\n#{out}\n#{err}"

    [ entry, JSON.parse(out.lines.last) ]
  end

  # The form the entry must have where it runs, from the platform itself:
  # the gem's own switch is stubbed in this process by spec_helper.
  def expected_argv(argv) = Gem.win_platform? ? [ "cmd", "/c", *argv ] : argv

  {
    in_gemfile: %w[bundle exec rails-ai-context serve],
    standalone: %w[rails-ai-context serve]
  }.each do |install_path, argv|
    it "starts the #{install_path} install's server with no shell, answers initialize, and stops when its stdin closes" do
      entry, report = launch_from_mcp_json(E2E.shared_app(install_path: install_path))

      expect([ entry["command"], *entry["args"] ]).to eq(expected_argv(argv))
      expect(report["error"]).to be_nil, "#{report['error']}\nstderr:\n#{report['stderr']}"
      expect(report.dig("response", "result", "serverInfo", "name")).to eq("rails-ai-context"), report.inspect
      expect(report.dig("response", "result", "protocolVersion")).to be_a(String)
      expect(report["exit"]).to eq("code" => 0, "signal" => nil), report["stderr"]
    end
  end
end
