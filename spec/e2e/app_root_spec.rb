# frozen_string_literal: true

require_relative "e2e_helper"

# Which app a command reads, decided before anything boots. Typed in a
# subdirectory of an app it reads that app, the way bin/rails and Bundler
# find theirs (#427); typed in the folder above one app it reads that app
# (#428); and `init --app-path` typed in that folder sets up the app it
# names, not the folder (#424). A folder of several apps, and `tool --list
# --app-path` (#426), are in workspace_install_spec, which has two.
#
# The app is a zero-config one: the gem is in its own GEM_HOME and not in
# the Gemfile, so no `bundle exec` walks up to the app first - the binary's
# own lookup is all that finds it.
RSpec.describe "E2E: the app a command reads", type: :e2e do
  before(:all) do
    @parent = File.join(E2E.root, "app_root")
    @app = E2E::TestAppBuilder.new(parent_dir: @parent, name: "blog", install_path: :zero_config).build!
    @cli = E2E::CliRunner.new(@app)
    # A folder that is no app, with a .gitignore of its own, which nothing
    # the app's setup writes may touch.
    File.write(File.join(@parent, ".gitignore"), "node_modules/\n")
  end

  # The gem prints the directory it stands in, which is the real path
  # (macOS's temp dir sits behind /var -> /private/var).
  def real(path) = File.realpath(path)

  def app_file(relative) = File.join(@app.app_path, relative)

  # What a terminal has: the binary on PATH and no Bundler context, so no
  # BUNDLE_GEMFILE pointing at the app either.
  def terminal = { "BUNDLE_GEMFILE" => nil }

  describe "typed in a subdirectory of the app (#427)" do
    it "reads the app above, and names it on stderr" do
      result = @cli.cli_tool("schema", chdir: app_file("app/models"), extra_env: terminal)

      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to include("posts")
      expect(result.stderr).to include("[rails-ai-context] using app at #{real(@app.app_path)}/")
    end

    # stdout is the protocol channel: the notice naming the app goes to
    # stderr, or the client reads it as a broken message.
    it "serves MCP over stdio from a views directory, with stdout left to the protocol" do
      client = E2E::McpStdioClient.new(nil, timeout: 90, launch: {
        env: @app.env.merge(terminal),
        command: [ *@app.cli_command, "serve" ],
        chdir: app_file("app/views/posts")
      })
      client.start!
      response = client.request("initialize", { protocolVersion: "2024-11-05", capabilities: {},
                                                 clientInfo: { name: "e2e-harness", version: "0.0.0" } })
      client.notify("notifications/initialized")

      expect(response.dig("result", "serverInfo", "name")).to eq("rails-ai-context")
      expect(client.call_tool("rails_get_schema").dig("result", "content", 0, "text")).to include("posts")
    ensure
      client&.stop!
    end

    # The bundled copy finds its app the same way: the in-Gemfile install's
    # `bundle exec`, typed in a controllers directory.
    it "reads the app above under bundle exec too" do
      shared = E2E.shared_app(install_path: :in_gemfile)
      result = E2E::CliRunner.new(shared).cli_tool("routes", chdir: File.join(shared.app_path, "app", "controllers"))

      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to include("/posts")
      expect(result.stderr).to include("[rails-ai-context] using app at #{real(shared.app_path)}/")
    end
  end

  # One app below is the one the folder means; several are refused
  # (workspace_install_spec).
  it "reads the one app in the folder it is typed in (#428)" do
    result = @cli.cli_tool("schema", chdir: @parent, extra_env: terminal)

    expect(result.success?).to be(true), result.to_s
    expect(result.stdout).to include("posts")
    expect(result.stderr).to include("[rails-ai-context] using app at blog/")
  end

  # The config, every MCP config and the .gitignore lines went to the
  # directory init was typed in, and the context files to the named app.
  describe "init --app-path typed in the folder above the app (#424)" do
    before(:all) do
      @init = @cli.cli("init", "--app-path", "blog", chdir: @parent, stdin_input: "a\n1\n", extra_env: terminal)
    end

    it "finishes" do
      expect(@init.success?).to be(true), @init.to_s
    end

    it "writes the app's config, MCP configs and context files into the app" do
      %w[.rails-ai-context.yml .mcp.json .cursor/mcp.json .vscode/mcp.json opencode.json .codex/config.toml
         CLAUDE.md].each do |relative|
        expect(File.exist?(app_file(relative))).to be(true), "#{relative} missing from the app\n#{@init}"
      end
      expect(JSON.parse(File.read(app_file(".mcp.json"))).dig("mcpServers", "rails-ai-context")).to be_a(Hash)
    end

    it "adds the gem's lines to the app's .gitignore" do
      gitignore = File.read(app_file(".gitignore"))

      expect(gitignore).to include(".codex/config.toml").and include(".ai-context.json")
    end

    it "writes nothing into the folder it was typed in" do
      %w[.rails-ai-context.yml .mcp.json .cursor .vscode opencode.json .codex CLAUDE.md AGENTS.md].each do |relative|
        expect(File.exist?(File.join(@parent, relative))).to be(false), "#{relative} written into the folder\n#{@init}"
      end
      expect(File.read(File.join(@parent, ".gitignore"))).to eq("node_modules/\n")
    end

    it "names the files and the next commands from where it was typed" do
      expect(@init.output).to include("blog/.mcp.json")
      expect(@init.output).to include("rails-ai-context --app-path blog doctor")
    end
  end
end
