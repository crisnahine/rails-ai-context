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

    # Rails 8.0 under json 3 raises from ActiveSupport's to_json. The frame
    # that names a failure must not fail the same way, or the client gets the
    # web server's plain-text 500 instead.
    # A direct to_json call goes through ActiveSupport::JSON.encode on every
    # Rails from 7.0, where Hash#to_json sits in a prepended module that
    # any_instance cannot stub.
    it "does not depend on the app's to_json" do
      allow(ActiveSupport::JSON).to receive(:encode).and_raise(ArgumentError, "unknown keyword: quirks_mode")
      expect { {}.to_json }.to raise_error(ArgumentError, /quirks_mode/)

      frame = described_class.internal_error_frame(ArgumentError.new("unknown keyword: quirks_mode"))

      expect(JSON.parse(frame).dig("error", "message")).to eq("Internal error: unknown keyword: quirks_mode")
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

  describe ".serve" do
    let(:base) { RailsAiContext::Tools::BaseTool }
    let(:transport) { instance_double(MCP::Server::Transports::StreamableHTTPTransport) }

    def env_for(session)
      Rack::MockRequest.env_for("/mcp", method: "POST", input: "{}", "HTTP_MCP_SESSION_ID" => session)
    end

    # The SDK answers a request inside a session with a streaming body, and
    # the tool runs when the web server calls it - after serve has returned.
    it "runs a streaming body in the session of the client that sent the request" do
      seen = nil
      allow(transport).to receive(:handle_request).and_return([ 200, {}, proc { |_stream| seen = base.current_session } ])

      _status, _headers, body = described_class.serve(env_for("client-a"), transport)
      expect(base.current_session).to eq(base::DEFAULT_SESSION)

      body.call(StringIO.new)

      expect(seen).to eq("client-a")
      expect(base.current_session).to eq(base::DEFAULT_SESSION)
    end

    it "hands an enumerable body back untouched" do
      allow(transport).to receive(:handle_request).and_return([ 200, {}, [ "{}" ] ])

      expect(described_class.serve(env_for("client-a"), transport).last).to eq([ "{}" ])
    end
  end

  # The SDK answered only a loopback Host, so an app reached by its own name
  # got 403 "Invalid Host header" with allow_http_in_production on, and
  # `myapp.localhost` was refused in development though Rails allows it.
  describe ".host_refusal" do
    def env(host, origin: nil, forwarded: nil)
      Rack::MockRequest.env_for("http://#{host}/mcp", method: "POST", input: "{}", "HTTP_HOST" => host,
                                **({ "HTTP_ORIGIN" => origin } if origin).to_h, **({ "HTTP_X_FORWARDED_HOST" => forwarded } if forwarded).to_h)
    end

    def app_with(hosts, exclude: nil)
      config = double("config", hosts: hosts, host_authorization: exclude ? { exclude: exclude } : {})
      double("app", config: config)
    end

    it "answers every host the app's config.hosts allows, in each form Rails reads" do
      app = app_with([ ".localhost", "myapp.example.com", /\A.*\.internal\z/, IPAddr.new("10.0.0.0/8") ])

      %w[myapp.localhost localhost:3000 myapp.example.com api.internal 10.1.2.3:8080].each do |host|
        expect(described_class.host_refusal(env(host), app)).to be_nil, host
      end
    end

    it "refuses a host config.hosts does not allow, a forwarded one included, as the SDK did" do
      app = app_with([ ".localhost" ])

      [ env("evil.example.com"), env("myapp.localhost", forwarded: "evil.example.com") ].each do |request|
        status, headers, body = described_class.host_refusal(request, app)
        expect(status).to eq(403)
        expect(headers["Content-Type"]).to eq("application/json")
        expect(JSON.parse(body.join).dig("error", "message")).to eq("Forbidden: Invalid Host header")
      end
    end

    it "answers any host when config.hosts is empty, as Rails does, and one its exclusion lets through" do
      expect(described_class.host_refusal(env("anything.example.com"), app_with([]))).to be_nil

      excluded = app_with([ ".localhost" ], exclude: ->(request) { request.path == "/mcp" })
      expect(described_class.host_refusal(env("anything.example.com"), excluded)).to be_nil
    end

    it "refuses a browser's request from another origin and answers one from the app's own" do
      app = app_with([])

      status, _headers, body = described_class.host_refusal(env("myapp.example.com", origin: "https://evil.example.com"), app)
      expect(status).to eq(403)
      expect(JSON.parse(body.join).dig("error", "message")).to eq("Forbidden: Invalid Origin header")
      expect(described_class.host_refusal(env("myapp.example.com", origin: "http://myapp.example.com"), app)).to be_nil
      expect(described_class.host_refusal(env("myapp.example.com:443", origin: "https://myapp.example.com"), app)).to be_nil
    end

    it "turns the SDK's loopback-only check off in the transports it builds" do
      transport = described_class.build_transport(Rails.application)
      request = Rack::Request.new(Rack::MockRequest.env_for("http://myapp.example.com/mcp", method: "POST",
        "HTTP_HOST" => "myapp.example.com", "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream",
        input: JSON.generate(jsonrpc: "2.0", id: 1, method: "initialize",
                             params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } })))

      status, = transport.handle_request(request)
      expect(status).to eq(200)
    ensure
      transport&.close if transport.respond_to?(:close)
    end
  end

  # The middleware and the engine ride the app's own web server, so in
  # production every tool would answer whoever reaches the app.
  describe ".production_refusal" do
    before { described_class.instance_variable_set(:@production_refusal_logged, nil) }

    def in_environment(name)
      allow(RailsAiContext).to receive(:environment_name).and_return(name)
    end

    it "lets development and test through" do
      %w[development test].each do |name|
        in_environment(name)
        expect(described_class.production_refusal).to be_nil
      end
    end

    it "refuses in production with a JSON-RPC error that says how to opt in" do
      in_environment("production")

      status, headers, body = described_class.production_refusal

      expect(status).to eq(403)
      expect(headers).to eq("Content-Type" => "application/json")
      expect(JSON.parse(body.join).dig("error", "message")).to include("config.allow_http_in_production = true")
    end

    # A staging app is reached the way production is.
    it "refuses in every other environment, naming it" do
      %w[staging preview].each do |name|
        in_environment(name)
        status, _headers, body = described_class.production_refusal
        expect(status).to eq(403)
        expect(JSON.parse(body.join).dig("error", "message")).to include("in the #{name} environment")
      end
    end

    it "serves in production once the app opts in" do
      in_environment("production")
      allow(RailsAiContext.configuration).to receive(:allow_http_in_production).and_return(true)

      expect(described_class.production_refusal).to be_nil
    end

    it "logs the refusal once, however often the client retries" do
      in_environment("production")
      allow(RailsAiContext).to receive(:log_warn)

      3.times { described_class.production_refusal }

      expect(RailsAiContext).to have_received(:log_warn).with(/Refused an MCP request/).once
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
