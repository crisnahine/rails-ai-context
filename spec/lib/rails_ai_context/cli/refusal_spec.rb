# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "rails_ai_context/cli/refusal"

RSpec.describe RailsAiContext::CLI::Refusal do
  def answers(reason, *requests)
    out = StringIO.new
    input = StringIO.new(requests.map { |request| "#{request.is_a?(String) ? request : JSON.generate(request)}\n" }.join)
    described_class.serve(reason, io_in: input, io_out: out)
    out.string.lines.map { |line| JSON.parse(line) }
  end

  it "connects with no tools and the reason as its instructions, until its input ends" do
    replies = answers("No app here.",
                      { jsonrpc: "2.0", id: 0, method: "server/discover", params: {} },
                      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } },
                      { jsonrpc: "2.0", method: "notifications/initialized" },
                      "not json",
                      { jsonrpc: "2.0", id: 2, method: "tools/list" },
                      { jsonrpc: "2.0", id: 3, method: "ping" },
                      { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "rails_get_schema" } })

    expect(replies.map { |reply| reply["id"] }).to eq([ 0, 1, 2, 3, 4 ])
    # A client takes method-not-found on discover for a server that speaks only initialize.
    expect(replies[0]["error"]).to include("code" => -32_601)
    expect(replies[1]["result"]).to include("protocolVersion" => "2025-06-18", "capabilities" => { "tools" => {} }, "instructions" => "No app here.")
    expect(replies[2]["result"]).to eq("tools" => [])
    expect(replies[3]["result"]).to eq({})
    expect(replies[4]["error"]).to eq("code" => -32_601, "message" => "No app here.")
  end

  # A C locale tags a path binary, and json 3 refuses such a string outright.
  it "answers a reason that names a folder outside ASCII, whatever its encoding tag" do
    reason = "/home/caf\xC3\xA9 holds no Rails app.".b
    reply = nil
    # json 2.x converts the string with a warning where json 3 raises.
    expect { reply = answers(reason, { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }).first }.not_to output.to_stderr

    expect(reply.dig("result", "instructions")).to eq("/home/café holds no Rails app.")
  end

  # json 3 refuses a binary string outside ASCII, which is how a C locale tags each line read.
  it "reads a request line outside ASCII as UTF-8, whatever its encoding tag" do
    allow(JSON).to receive(:parse).and_wrap_original do |parse, source, *rest|
      raise JSON::ParserError, "binary source" if source.encoding == Encoding::BINARY && !source.ascii_only?

      parse.call(source, *rest)
    end
    line = JSON.generate(jsonrpc: "2.0", id: 1, method: "initialize", params: { clientInfo: { name: "caf\u00e9" } }).b
    out = StringIO.new
    described_class.serve("No app here.", io_in: StringIO.new("#{line}\n".b), io_out: out)

    expect(JSON.parse(out.string)).to include("id" => 1)
  end

  it "answers with the client's protocol revision where it knows it, else its newest" do
    replies = answers("x", { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05" } },
                      { jsonrpc: "2.0", id: 2, method: "initialize", params: { protocolVersion: "2099-01-01" } })

    expect(replies.map { |reply| reply.dig("result", "protocolVersion") }).to eq(%w[2024-11-05 2025-11-25])
  end
end
