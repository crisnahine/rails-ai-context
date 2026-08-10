# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::McpEdge do
  describe ".internal_error_frame" do
    it "builds a JSON-RPC internal error" do
      frame = described_class.internal_error_frame(RuntimeError.new("disk on fire"))

      expect(JSON.parse(frame)).to eq(
        "jsonrpc" => "2.0",
        "error" => { "code" => -32603, "message" => "Internal error: disk on fire" },
        "id" => nil
      )
    end

    it "is valid JSON even when the message carries quotes" do
      frame = described_class.internal_error_frame(RuntimeError.new(%(bad "input" here)))

      expect(JSON.parse(frame).dig("error", "message")).to eq(%(Internal error: bad "input" here))
    end
  end

  describe ".internal_error_response" do
    it "answers 500 with a JSON content type and the frame" do
      status, headers, body = described_class.internal_error_response(RuntimeError.new("boom"))

      expect(status).to eq(500)
      expect(headers).to eq("Content-Type" => "application/json")
      expect(JSON.parse(body.first).dig("error", "code")).to eq(-32603)
    end

    it "logs the failure once" do
      expect(RailsAiContext).to receive(:log_warn).with(/MCP request failed: RuntimeError: boom/)

      described_class.internal_error_response(RuntimeError.new("boom"))
    end
  end

  describe ".build_transport" do
    it "returns a streamable HTTP transport" do
      expect(described_class.build_transport)
        .to be_a(MCP::Server::Transports::StreamableHTTPTransport)
    end

    it "builds a fresh transport per call, leaving memoization to the caller" do
      expect(described_class.build_transport).not_to equal(described_class.build_transport)
    end
  end
end

RSpec.describe "JSON-RPC error frame ownership" do
  it "is built in one place" do
    lib_root = File.expand_path("../../../lib", __dir__)
    app_root = File.expand_path("../../../app", __dir__)
    owner = File.join(lib_root, "rails_ai_context", "mcp_edge.rb")

    offenders = (Dir.glob(File.join(lib_root, "**", "*.rb")) + Dir.glob(File.join(app_root, "**", "*.rb")))
      .reject { |f| f == owner }
      .select { |f|
        File.readlines(f).reject { |l| l.strip.start_with?("#") }.any? { |l| l.include?("-32603") }
      }
      .map { |f| f.sub("#{File.dirname(lib_root)}/", "") }

    expect(offenders).to be_empty,
      "Files building their own JSON-RPC error frame: #{offenders.join(', ')}"
  end
end
