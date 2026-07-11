# frozen_string_literal: true

require_relative "e2e_helper"

# Apps that boot noisily or not at all are a mainstream shape (missing ENV,
# unreachable services, syntax errors). The gem must respond with a friendly
# diagnostic - never a raw Thor backtrace - and boot output must never
# corrupt the stdio JSON-RPC channel. A dedicated app (not the shared
# fixture) because these examples mutate config/initializers.
RSpec.describe "E2E: boot resilience", type: :e2e do
  before(:all) do
    @builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "boot_resilience_app",
      install_path: :in_gemfile
    ).build!
    @cli = E2E::CliRunner.new(@builder)
    @initializer_dir = File.join(@builder.app_path, "config", "initializers")
  end

  def with_initializer(name, content)
    path = File.join(@initializer_dir, name)
    File.write(path, content)
    yield
  ensure
    File.delete(path) if File.exist?(path)
  end

  describe "app that raises during boot" do
    it "tool command falls back to static analysis instead of dying" do
      with_initializer("zz_kaboom.rb", %(raise "FATAL_ENV_MISSING: REDIS_URL is not set"\n)) do
        result = @cli.cli_tool("schema")
        expect(result.exit_status).to eq(0), result.to_s
        expect(result.stderr).to include("App boot failed")
        expect(result.stderr).to include("FATAL_ENV_MISSING")
        expect(result.stderr).to include("static tier active")
        expect(result.stderr).not_to include("thor")
        expect(result.stdout).not_to be_empty
      end
    end

    it "doctor fails with the same friendly diagnostic" do
      with_initializer("zz_kaboom.rb", %(raise "FATAL_ENV_MISSING"\n)) do
        result = @cli.cli("doctor")
        expect(result.exit_status).to eq(1), result.to_s
        expect(result.stderr).to include("failed to boot")
      end
    end

    it "falls back to static analysis on a syntax error in an initializer" do
      with_initializer("zz_broken_syntax.rb", "def broken(\n") do
        result = @cli.cli_tool("schema")
        expect(result.exit_status).to eq(0), result.to_s
        expect(result.stderr).to match(/SyntaxError|broken_syntax/)
        expect(result.stderr).to include("static tier active")
      end
    end
  end

  describe "app that prints to stdout during boot" do
    it "keeps the stdio MCP handshake parseable" do
      with_initializer("zz_chatty.rb", %(puts "BOOT NOISE that must not reach stdout"\n)) do
        client = E2E::McpStdioClient.new(@builder).start!
        begin
          response = client.request("initialize", {
            protocolVersion: "2024-11-05",
            capabilities: {},
            clientInfo: { name: "e2e-harness", version: "0.0.0" }
          })
          expect(response["result"]).to be_a(Hash), "handshake corrupted: #{response.inspect}"

          client.notify("notifications/initialized")
          tools = client.request("tools/list")
          expect(tools.dig("result", "tools")).to be_an(Array)
        ensure
          client.stop!
        end
      end
    end

    it "keeps CLI tool stdout parseable in json mode" do
      with_initializer("zz_chatty.rb", %(puts "BOOT NOISE that must not reach stdout"\n)) do
        result = @cli.cli_tool("schema", [ "--json" ])
        expect(result.success?).to be(true), result.to_s
        expect(result.stdout).not_to include("BOOT NOISE")
        expect { JSON.parse(result.stdout) }.not_to raise_error
      end
    end
  end

  describe "app that writes via the STDOUT constant during boot" do
    # $stdout.puts is the common case, but some initializers, gem banners, or
    # subprocess output bypass the $stdout global and write straight to fd 1
    # via the STDOUT constant. Both must be caught for the stdio transport to
    # stay clean.
    let(:noisy_initializer) do
      <<~RUBY
        puts "BOOT NOISE via $stdout global"
        STDOUT.puts "BOOT NOISE via STDOUT constant"
      RUBY
    end

    it "keeps the stdio MCP handshake parseable with zero non-JSON bytes on stdout" do
      with_initializer("zz_constant_write.rb", noisy_initializer) do
        client = E2E::McpStdioClient.new(@builder).start!
        begin
          response = client.request("initialize", {
            protocolVersion: "2024-11-05",
            capabilities: {},
            clientInfo: { name: "e2e-harness", version: "0.0.0" }
          })
          expect(response["result"]).to be_a(Hash), "handshake corrupted: #{response.inspect}"

          client.notify("notifications/initialized")
          tools = client.request("tools/list")
          expect(tools.dig("result", "tools")).to be_an(Array)
        ensure
          client.stop!
        end
      end
    end

    it "keeps CLI tool stdout parseable in json mode" do
      with_initializer("zz_constant_write.rb", noisy_initializer) do
        result = @cli.cli_tool("schema", [ "--json" ])
        expect(result.success?).to be(true), result.to_s
        expect(result.stdout).not_to include("BOOT NOISE")
        expect { JSON.parse(result.stdout) }.not_to raise_error
      end
    end
  end

  describe "app that hangs during boot" do
    it "falls back to static analysis on boot timeout, naming the limit" do
      with_initializer("zz_slow.rb", "sleep 5\n") do
        result = @cli.cli_tool("schema", extra_env: { "RAILS_AI_CONTEXT_BOOT_TIMEOUT" => "2" })
        expect(result.exit_status).to eq(0), result.to_s
        expect(result.stderr).to include("did not finish within 2s")
        expect(result.stderr).to include("RAILS_AI_CONTEXT_BOOT_TIMEOUT")
        expect(result.stderr).not_to include("Timeout::Error: execution expired")
      end
    end

    it "adds a doctor-specific hint on top of the timeout message" do
      with_initializer("zz_slow.rb", "sleep 5\n") do
        result = @cli.cli("doctor", extra_env: { "RAILS_AI_CONTEXT_BOOT_TIMEOUT" => "2" })
        expect(result.exit_status).to eq(1), result.to_s
        expect(result.stderr).to include("did not finish within 2s")
        expect(result.stderr).to include("doctor needs a bootable app")
      end
    end
  end
end
