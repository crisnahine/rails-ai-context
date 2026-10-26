# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "timeout"
require "rbconfig"
require "rails_ai_context/child_server"

RSpec.describe RailsAiContext::ChildServer do
  around do |example|
    log, $stderr = $stderr, StringIO.new
    example.run
  ensure
    $stderr = log
  end

  # What the proxy wrote, its input held open until each request has its reply, as a client holds it: input that
  # ended at once gave a copy slower to start than the stop's grace a stop reason of its own.
  def proxied(argv, lines, name: "rails-ai-context 5.0.0 from this app's bundle")
    reader, input = IO.pipe
    output, writer = IO.pipe
    proxying = Thread.new do
      described_class.proxy({}, argv, chdir: Dir.pwd, name: name, io_in: reader, io_out: writer)
    ensure
      writer.close
    end
    HeldInput.exchange(input, output, lines.map { |line| "#{line}\n" })
  ensure
    proxying&.join
  end

  def proxy(script, *lines)
    proxied([ RbConfig.ruby, "-rjson", "-e", script ], lines).lines.map { |line| JSON.parse(line) }.to_h { |reply| [ reply["id"], reply ] }
  end

  let(:initialize_request) { JSON.generate(jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" }) }
  let(:initialized) { JSON.generate(jsonrpc: "2.0", method: "notifications/initialized") }

  it "answers the handshake with the reason where the app's copy stops before it answers initialize" do
    replies = proxy("warn 'this copy cannot boot'; exit 1", initialize_request, initialized, JSON.generate(jsonrpc: "2.0", id: 2, method: "tools/list"))

    expect(replies[1]["result"]).to include("protocolVersion" => "2025-06-18",
                                            "instructions" => "rails-ai-context 5.0.0 from this app's bundle could not start: this copy cannot boot")
    expect(replies[2]["result"]).to eq("tools" => [])
  end

  it "passes each line on as it came, and answers what is left with the reason once the copy stops" do
    script = <<~RUBY
      $stdout.sync = true
      $stdin.gets
      puts '{"jsonrpc": "2.0",  "id": 1, "result": {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "x", "version": "5.0.0"}}}'
      $stdin.gets
      puts '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}'
      $stdin.gets
      warn "the copy died"
      exit 1
    RUBY
    lines = [ initialize_request, initialized, JSON.generate(jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rails_get_schema" }) ]
    sent = proxied([ RbConfig.ruby, "-e", script ], lines).lines

    expect(sent.first).to eq(%({"jsonrpc": "2.0",  "id": 1, "result": {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "x", "version": "5.0.0"}}}\n))
    expect(sent).to include(%({"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}\n))
    expect(JSON.parse(sent.last)).to eq("jsonrpc" => "2.0", "id" => 2,
                                        "error" => { "code" => -32_603, "message" => "rails-ai-context 5.0.0 from this app's bundle stopped: the copy died" })
  end

  it "answers a request that comes after the copy stopped with the reason" do
    script = "$stdout.sync = true; $stdin.gets; puts JSON.generate(jsonrpc: '2.0', id: 1, result: {}); warn 'gone now'; exit 1"
    out = StringIO.new
    reader, writer = IO.pipe
    proxying = Thread.new do
      described_class.proxy({}, [ RbConfig.ruby, "-rjson", "-e", script ], chdir: Dir.pwd, name: "the copy", io_in: reader, io_out: out)
    end
    writer.puts initialize_request
    Timeout.timeout(10) { sleep 0.1 until $stderr.string.include?("gone now") || !proxying.alive? }
    writer.puts JSON.generate(jsonrpc: "2.0", id: 2, method: "ping")
    Timeout.timeout(10) { sleep 0.1 until out.string.include?('"id":2') || !proxying.alive? }
    writer.close
    proxying.join

    expect(JSON.parse(out.string.lines.last)).to include("id" => 2, "error" => { "code" => -32_603, "message" => "the copy stopped: gone now" })
  end

  it "treats a copy that answered initialize with an error as one that never started" do
    script = "$stdout.sync = true; $stdin.gets; puts JSON.generate(jsonrpc: '2.0', id: 1, error: { code: -32_000, message: 'no' }); " \
             "$stdin.gets; $stdin.gets; warn 'cannot serve'; exit 1"
    replies = proxy(script, initialize_request, initialized, JSON.generate(jsonrpc: "2.0", id: 2, method: "tools/list"))

    expect(replies[1]["error"]).to include("message" => "no")
    expect(replies[2]["result"]).to eq("tools" => [])
  end

  it "stops reading quietly where passing a line on finds the client gone" do
    child = described_class.new({}, [ RbConfig.ruby, "-e", "$stdout.sync = true; puts '{\"jsonrpc\":\"2.0\",\"method\":\"x\"}'; sleep 1" ],
                                chdir: Dir.pwd) { raise Errno::EPIPE }
    Timeout.timeout(10) { sleep 0.1 until child.gone? }

    expect($stderr.string).not_to include("terminated with exception")
  ensure
    child&.stop
  end

  it "names the signal that stopped a child that said nothing" do
    child = described_class.new({}, [ RbConfig.ruby, "-e", "Process.kill('KILL', Process.pid)" ], chdir: Dir.pwd)

    expect { child.request("ping", {}) }.to raise_error(described_class::Gone, "it was stopped by signal KILL")
  ensure
    child&.stop
  end
end
