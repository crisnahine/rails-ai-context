# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::HttpClientCallListener do
  def walk(source)
    RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { http: described_class })[:http]
  end

  it "reads the URL of a client call, bare, wrapped in URI or as url:, and the host Net::HTTP.start takes" do
    calls = walk(<<~RUBY)
      Faraday.new(url: "https://a.example")
      ::Net::HTTP.get(URI.parse("https://b.example/x"))
      HTTParty.get(URI("https://c.example/x"))
      URI.open("https://d.example/feed")
      Net::HTTP.start("e.example", 443) { }
    RUBY

    expect(calls.map { |c| c.except(:line) }).to eq([
      { client: "Faraday", url: "https://a.example" },
      { client: "Net::HTTP", url: "https://b.example/x" },
      { client: "HTTParty", url: "https://c.example/x" },
      { client: "URI.open", url: "https://d.example/feed" },
      { client: "Net::HTTP", host: "e.example" }
    ])
  end

  it "skips a client named in a comment or a string, an interpolated URL, and another library's HTTP" do
    calls = walk(<<~RUBY)
      run # HTTParty.get("https://old.example")
      x = "Faraday.get('https://docs.example')"
      Faraday.get("https://\#{host}/x")
      Foo::HTTP.get("https://f.example")
    RUBY

    expect(calls).to eq([])
  end
end
