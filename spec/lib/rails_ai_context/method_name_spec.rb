# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::MethodName do
  describe ".call_end" do
    let(:pattern) { Regexp.new("\\bping#{described_class.call_end('ping')}") }

    it "reads a call of the name" do
      [ "obj.ping == 1", "obj.ping =~ /x/", "{ ping => 1 }", "obj.ping ||= 1", "obj.ping += 1",
        "x = obj.ping", "ping", "ping arg", "ping ? 1 : 2", "ping(1)", "ping != 2", "ping==1" ].each do |line|
        expect(line).to match(pattern)
      end
    end

    it "does not read a setter or a neighbouring name" do
      [ "obj.ping = 1", "obj.ping=1", "obj.ping  =  2", "obj.ping?", "obj.ping!", "pinger" ].each do |line|
        expect(line).not_to match(pattern)
      end
    end
  end

  describe ".definition_end" do
    let(:pattern) { Regexp.new("\\Adef\\s+ping#{described_class.definition_end('ping')}") }

    it "reads an endless def and leaves ?, ! and = methods alone" do
      expect([ "def ping", "def ping(x)", "def ping = 1" ]).to all(match(pattern))
      [ "def ping?", "def ping!", "def ping=(v)", "def pinger" ].each { |line| expect(line).not_to match(pattern) }
    end
  end

  it "adds nothing after a name that already ends in punctuation" do
    expect(described_class.call_end("ping?")).to eq("")
    expect(described_class.definition_end("ping?")).to eq("")
  end
end
