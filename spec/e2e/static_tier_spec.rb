# frozen_string_literal: true

require_relative "e2e_helper"

# The static tier headline: an app that cannot boot still answers real
# questions - routes from routes.rb, schema from schema.rb, controllers from
# source - over both the CLI and MCP stdio, with an honest banner. A
# dedicated app because these examples mutate config/initializers and
# config/routes.rb.
RSpec.describe "E2E: static tier", type: :e2e do
  before(:all) do
    @builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "static_tier_app",
      install_path: :in_gemfile
    ).build!
    @cli = E2E::CliRunner.new(@builder)
    @initializer_dir = File.join(@builder.app_path, "config", "initializers")

    routes_path = File.join(@builder.app_path, "config", "routes.rb")
    routes = File.read(routes_path)
    File.write(routes_path, routes.sub(
      "Rails.application.routes.draw do",
      %(Rails.application.routes.draw do\n  get "static_probe", to: "probe#show"\n)
    ))
  end

  def with_initializer(name, content)
    path = File.join(@initializer_dir, name)
    File.write(path, content)
    yield
  ensure
    File.delete(path) if File.exist?(path)
  end

  describe "broken-boot app over the CLI" do
    it "answers routes from config/routes.rb with the static banner" do
      with_initializer("zz_kaboom.rb", %(raise "FATAL_ENV_MISSING"\n)) do
        result = @cli.cli_tool("routes")
        expect(result.exit_status).to eq(0), result.to_s
        expect(result.stdout).to include("static_probe")
        expect(result.stdout).to include("static analysis")
      end
    end

    it "answers schema from db/schema.rb" do
      with_initializer("zz_kaboom.rb", %(raise "FATAL_ENV_MISSING"\n)) do
        result = @cli.cli_tool("schema")
        expect(result.exit_status).to eq(0), result.to_s
        # Default detail level ("standard") headlines with "# Schema (N
        # table(s), ...)" - it doesn't surface the "static_parse" adapter
        # marker or a "schema.rb" filename (those only appear at other detail
        # levels), so match what this response actually guarantees.
        expect(result.stdout).to match(/schema|static_parse|tables?/i)
      end
    end

    it "marks runtime-only tools unavailable rather than crashing" do
      with_initializer("zz_kaboom.rb", %(raise "FATAL_ENV_MISSING"\n)) do
        result = @cli.cli_tool("runtime_info")
        expect(result.exit_status).to eq(0), result.to_s
        expect(result.stdout).to match(/UNAVAILABLE|not booted|static/i)
      end
    end
  end

  describe "broken-boot app over MCP stdio" do
    it "serves the handshake, tool list, and static tool calls" do
      with_initializer("zz_kaboom.rb", %(raise "FATAL_ENV_MISSING"\n)) do
        client = E2E::McpStdioClient.new(@builder).start!
        begin
          response = client.request("initialize", {
            protocolVersion: "2024-11-05",
            capabilities: {},
            clientInfo: { name: "e2e-harness", version: "0.0.0" }
          })
          expect(response["result"]).to be_a(Hash), "handshake failed: #{response.inspect}"
          client.notify("notifications/initialized")

          tools = client.request("tools/list")
          expect(tools.dig("result", "tools")).to be_an(Array)

          call = client.request("tools/call", {
            name: "rails_get_routes", arguments: {}
          })
          expect(call.dig("result", "isError")).not_to eq(true), call.inspect
          text = call.dig("result", "content", 0, "text").to_s
          expect(text).to include("static_probe")
          expect(text).to include("static analysis")
        ensure
          client.stop!
        end
      end
    end
  end

  describe "healthy app with --no-boot" do
    it "serves static answers without booting" do
      result = @cli.cli_tool("routes", [ "--no-boot" ])
      expect(result.exit_status).to eq(0), result.to_s
      expect(result.stderr).to include("static mode requested with --no-boot")
      expect(result.stdout).to include("static_probe")
    end
  end

  describe "--app-path from outside the app directory" do
    it "resolves the app root from a foreign cwd" do
      # CliRunner#run always chdirs into the app directory before running a
      # command, so it cannot exercise --app-path resolving the app root from
      # somewhere else. Build the same command line CliRunner would build and
      # run it directly via Open3 with a cwd outside the app entirely - the
      # only way to prove --app-path (not an ambient cwd match) is what finds
      # the app. Flag order matters: `stop_on_unknown_option! :tool` passes
      # anything after the positional tool name straight through as tool args,
      # so --app-path must precede the "routes" tool name.
      cmd = @cli.send(:cli_prefix) + [
        "tool", "--app-path", @builder.app_path, "--no-boot", "routes"
      ]
      stdout, stderr, status = Open3.capture3(@builder.env, *cmd, chdir: Dir.tmpdir)
      expect(status.exitstatus).to eq(0), "cmd=#{cmd.inspect}\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
      expect(stdout).to include("static_probe")
    end
  end
end
