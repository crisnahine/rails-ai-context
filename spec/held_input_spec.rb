# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe HeldInput do
  # A server that answers each request on its own line, the second one late and only while its input is open.
  def serve(server_in, server_out)
    Thread.new do
      server_in.each_line.with_index do |line, index|
        sleep 0.3 if index == 1
        next if index == 1 && closed?(server_in)

        server_out.puts JSON.generate("jsonrpc" => "2.0", "id" => JSON.parse(line)["id"], "result" => index)
        server_out.flush
      end
    ensure
      server_out.close
    end
  end

  def closed?(io)
    IO.select([ io ], nil, nil, 0) && io.read_nonblock(1) && false
  rescue EOFError
    true
  rescue IO::WaitReadable
    false
  end

  it "keeps the input open until a repeated id has a reply for each request" do
    server_in, input = IO.pipe
    output, server_out = IO.pipe
    server = serve(server_in, server_out)
    request = "#{JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "ping")}\n"

    text = described_class.exchange(input, output, [ request, request ], wait: 10)

    expect(text.lines.map { |line| JSON.parse(line)["result"] }).to eq([ 0, 1 ])
  ensure
    server&.join
  end
end
