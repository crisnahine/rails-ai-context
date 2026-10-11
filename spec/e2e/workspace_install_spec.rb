# frozen_string_literal: true

require_relative "e2e_helper"

# Install path D: a folder of apps, with the editor opened at the folder.
# `rails-ai-context init` run there writes one MCP server per app into the
# folder's own configs, and each app's config and context files into the app.
# Each entry is then started the way its AI tool starts it - the command, the
# args and the env from the config, in the directory the tool uses - and
# spoken to over MCP. One app is standalone and one in-Gemfile, the two
# command forms an entry can take.
RSpec.describe "E2E: workspace of apps", type: :e2e do
  before(:all) do
    @workspace = File.join(E2E.root, "workspace")
    # The gem in its own GEM_HOME and not in the Gemfile, and no init yet.
    @shop = E2E::TestAppBuilder.new(parent_dir: @workspace, name: "shop", install_path: :zero_config).build!
    # The gem in the Gemfile, left for the workspace's init to set up.
    @admin = E2E::TestAppBuilder.new(parent_dir: @workspace, name: "admin", install_path: :in_gemfile)
    @admin.define_singleton_method(:run_install_generator!) { }
    @admin.build!
    # A custom tool, which only a boot of the app can list (#426).
    File.write(File.join(@admin.app_path, "config/initializers/rails_ai_context.rb"), <<~RUBY)
      if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
        require "mcp"

        class LabProbeTool < MCP::Tool
          tool_name "lab_probe"
          description "Lab probe custom tool"

          def self.call(server_context: nil)
            MCP::Tool::Response.new([ { type: "text", text: "probe" } ])
          end
        end

        RailsAiContext.configure do |config|
          config.custom_tools = [ LabProbeTool ]
        end
      end
    RUBY

    @init_out, @init_err, @init_status = Open3.capture3(
      shell_env, *@shop.cli_command, "init",
      chdir: @workspace, stdin_data: "a\n1\n"
    )
  end

  # What a terminal or an AI tool has: the standalone binary on PATH, the
  # apps' environment, and no Bundler context of its own.
  def shell_env
    @shop.env.merge("BUNDLE_GEMFILE" => nil)
  end

  def workspace_file(relative) = File.join(@workspace, relative)

  def json_servers(relative, key)
    JSON.parse(File.read(workspace_file(relative)))[key]
  end

  # The command, args and env of one server in Codex's TOML, read the way
  # the gem writes them: JSON-compatible strings and arrays.
  def codex_entry(name)
    lines = File.read(workspace_file(".codex/config.toml")).lines.map(&:chomp)
    section = ->(header) { lines.drop_while { |l| l != header }.drop(1).take_while { |l| !l.start_with?("[") } }
    values = ->(header) { section.(header).filter_map { |l| l.split(" = ", 2) if l.include?(" = ") }.to_h { |k, v| [ k, JSON.parse(v) ] } }
    main = values.("[mcp_servers.#{name}]")
    { command: [ main["command"], *main["args"] ], env: values.("[mcp_servers.#{name}.env]") }
  end

  def with_server(env:, command:, chdir:)
    client = E2E::McpStdioClient.new(nil, timeout: 90, launch: { env: env, command: command, chdir: chdir })
    client.start!
    yield client
  ensure
    client&.stop!
  end

  def schema_text(client)
    client.call_tool("rails_get_schema").dig("result", "content", 0, "text").to_s
  end

  describe "init in the folder" do
    it "finishes" do
      expect(@init_status.success?).to be(true), "#{@init_out}\n#{@init_err}"
    end

    it "writes one server per app into every AI tool's config in the folder" do
      expect(json_servers(".mcp.json", "mcpServers").keys).to eq(%w[rails-ai-context-admin rails-ai-context-shop])
      expect(json_servers(".cursor/mcp.json", "mcpServers").keys).to eq(%w[rails-ai-context-admin rails-ai-context-shop])
      expect(json_servers(".vscode/mcp.json", "servers").keys).to eq(%w[rails-ai-context-admin rails-ai-context-shop])
      expect(json_servers("opencode.json", "mcp").keys).to eq(%w[rails-ai-context-admin rails-ai-context-shop])
      expect(File.read(workspace_file(".codex/config.toml"))).to include("[mcp_servers.rails-ai-context-shop]")
    end

    it "gives each app the command form of its own install" do
      servers = json_servers(".mcp.json", "mcpServers")
      expect(servers["rails-ai-context-shop"]["command"]).to eq("rails-ai-context")
      expect(servers["rails-ai-context-admin"]).to include(
        "command" => "bundle",
        "env" => { "BUNDLE_GEMFILE" => "admin/Gemfile", "RAILS_AI_CONTEXT_SERVER_NAME" => "admin-rails-ai-context" }
      )
    end

    it "writes each app's config and context files in the app, and none in the folder" do
      [ @shop, @admin ].each do |app|
        expect(File.exist?(File.join(app.app_path, ".rails-ai-context.yml"))).to be(true), app.app_path
        expect(File.read(File.join(app.app_path, "CLAUDE.md"))).to include("Post")
        expect(File.exist?(File.join(app.app_path, ".mcp.json"))).to be(false)
      end
      expect(File.exist?(workspace_file("CLAUDE.md"))).to be(false)
      expect(File.exist?(workspace_file(".rails-ai-context.yml"))).to be(false)
    end
  end

  describe "each entry, started the way its AI tool starts it" do
    # Claude Code, Codex and OpenCode start a server in the folder they were
    # launched in, which here is the workspace.
    %w[shop admin].each do |app|
      it "serves #{app} from Claude Code's .mcp.json" do
        entry = json_servers(".mcp.json", "mcpServers")["rails-ai-context-#{app}"]
        launch = { env: shell_env.merge(entry["env"] || {}), command: [ entry["command"], *entry["args"] ], chdir: @workspace }

        with_server(**launch) do |client|
          init = client.request("initialize", { protocolVersion: "2024-11-05", capabilities: {},
                                                clientInfo: { name: "e2e-harness", version: "0.0.0" } })
          client.notify("notifications/initialized")
          expect(init.dig("result", "serverInfo", "name")).to eq("#{app}-rails-ai-context")
          expect(schema_text(client)).to include("posts")
        end
      end
    end

    it "serves the in-Gemfile app from Codex's TOML" do
      entry = codex_entry("rails-ai-context-admin")

      with_server(env: shell_env.merge(entry[:env]), command: entry[:command], chdir: @workspace) do |client|
        client.initialize!
        expect(schema_text(client)).to include("posts")
      end
    end

    # Cursor expands ${workspaceFolder} and does not promise a working
    # directory; users report the filesystem root.
    it "serves both apps from Cursor's config whatever the working directory" do
      json_servers(".cursor/mcp.json", "mcpServers").each_value do |entry|
        expand = ->(value) { value.gsub("${workspaceFolder}", @workspace) }
        env = shell_env.merge((entry["env"] || {}).transform_values(&expand))

        with_server(env: env, command: [ entry["command"], *entry["args"].map(&expand) ], chdir: "/") do |client|
          client.initialize!
          expect(schema_text(client)).to include("posts")
        end
      end
    end
  end

  # A tool launched inside one app still reads the workspace's config above
  # it, and starts the workspace's servers there.
  it "names the folder an entry was written for when started inside an app" do
    entry = json_servers(".mcp.json", "mcpServers")["rails-ai-context-shop"]

    _out, err, status = Open3.capture3(shell_env, entry["command"], *entry["args"], chdir: @admin.app_path, stdin_data: "")

    expect(status.success?).to be(false)
    expect(err).to include("it names an app from #{@workspace}")
  end

  # tool --list read the current directory before --app-path, so from
  # outside the app it never booted it and left its custom tools out.
  it "lists an app's custom tools with --app-path from outside it" do
    env = shell_env.merge("BUNDLE_GEMFILE" => File.join(@admin.app_path, "Gemfile"))
    out, err, status = Open3.capture3(env, "bundle", "exec", "rails-ai-context", "tool", "--list", "--app-path", "admin",
                                      chdir: @workspace)

    expect(status.success?).to be(true), err
    expect(out).to match(/^\s+lab_probe\s+Lab probe custom tool$/)
    expect(out).not_to include("Run inside a Rails app to execute tools")
  end

  it "finds the workspace's MCP configs from doctor inside an app" do
    out, err, = Open3.capture3(@admin.env, "bundle", "exec", "rails-ai-context", "doctor", chdir: @admin.app_path)

    expect("#{out}\n#{err}").not_to include("No .mcp.json for MCP auto-discovery")
    expect(out).to match(/MCP configs.*5 of 5 MCP configs valid/), "#{out}\n#{err}"
  end
end
