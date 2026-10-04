# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

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

  # Ruby reads any non-ASCII character as part of a name, and ripgrep reads
  # the same pattern alike.
  describe "non-ASCII text" do
    lines = [ "pingé", "obj.pingé(1)", "ping\u00A0= 1", "ping \u00A0x", "ping\u2003", "def pingé", "def ping\u00A0",
              "ping(1)", "def ping", "obj.ping = 1" ]
    let(:patterns) do
      { "call" => "\\bping#{described_class.call_end('ping')}", "def" => "^def\\s+ping#{described_class.definition_end('ping')}" }
    end

    def matching(lines, pattern)
      lines.each_index.select { |i| lines[i].match?(Regexp.new(pattern)) }
    end

    it "counts a non-ASCII character as part of the name" do
      expect(matching(lines, patterns["call"])).to eq([ 3, 7, 8 ])
      expect(matching(lines, patterns["def"])).to eq([ 8 ])
      expect(described_class.definition_end("pingé")).not_to eq("")
    end

    it "matches the same lines in ripgrep" do
      skip "requires ripgrep" unless RailsAiContext::Tools::SearchCode.send(:ripgrep_available?)

      Dir.mktmpdir do |dir|
        file = File.join(dir, "lines.txt")
        File.write(file, "#{lines.join("\n")}\n")
        patterns.each do |kind, pattern|
          out, = Open3.capture2("rg", "--no-filename", "-n", "-e", pattern, file)
          expect(out.lines.map { |l| l.to_i - 1 }).to eq(matching(lines, pattern)), kind
        end
      end
    end
  end

  it "adds nothing after a name that already ends in punctuation" do
    expect(described_class.call_end("ping?")).to eq("")
    expect(described_class.definition_end("ping?")).to eq("")
  end
end
