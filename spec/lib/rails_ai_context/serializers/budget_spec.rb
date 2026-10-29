# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::Budget do
  describe ".list" do
    it "joins what fits the width and counts the rest" do
      names = (1..100).map { |i| "Name#{i}" }

      line = described_class.list(names, lead: "**Services:** ")

      expect(line).to start_with("**Services:** Name1, Name2")
      expect(line).to end_with("more")
      expect(line.size).to be <= described_class::LINE_WIDTH
      expect(line[/(\d+) more/, 1].to_i + line.scan(/Name\d+/).size).to eq(100)
    end

    it "stops at the cap even where more would fit" do
      expect(described_class.list(%w[a b c d], cap: 2)).to eq("a, b, ...2 more")
    end

    it "leaves a list that fits whole" do
      expect(described_class.list(%w[a b])).to eq("a, b")
    end

    # A name too wide for the line on its own still names the count.
    it "says how many there are when not even one fits" do
      expect(described_class.list([ "x" * 500, "y" ], lead: "- ")).to eq("- ...2 more")
    end
  end

  describe ".wrap" do
    it "keeps every item, over lines of the width" do
      names = (1..80).map { |i| "`tool_number_#{i}`" }

      lines = described_class.wrap(names, lead: "Tools that take `detail`: ")

      expect(lines.size).to be > 1
      expect(lines.all? { |line| line.size <= described_class::LINE_WIDTH }).to be(true)
      expect(lines.join(" ").scan(/tool_number_\d+/).size).to eq(80)
    end
  end

  # The order the root file's data sections stand in is the order a cut takes them.
  it "orders the root file's data sections the way a cut keeps them" do
    body = described_class.root_body(architecture: [ "a" ], gems: [ "g" ], key_models: [ "m" ], stack: [ "s" ])

    expect(body).to eq(%w[s m g a])
  end

  describe ".fit" do
    it "cuts the data from the bottom up to the byte budget and keeps the head and the kept sections whole" do
      head = [ "# App - AI Context", "" ]
      body = (1..400).map { |i| "- line #{i} #{"x" * 40}" }
      keep = [ "## Conventions", "- keep me" ]

      text = described_class.fit(head: head, body: body, keep: keep, kind: :root, note: "_trimmed_")

      expect(text.bytesize).to be <= described_class::BYTES.fetch(:root)
      expect(text).to start_with("# App - AI Context")
      expect(text).to include("- line 1 ", "_trimmed_", "## Conventions\n- keep me")
      expect(text).not_to include("- line 400 ")
    end

    # It dropped a line at a time and joined the whole file again each time:
    # 40,000 lines of a large app's full mode took 22 seconds.
    it "cuts a long body in one pass" do
      body = Array.new(40_000) { |i| "- line #{i} #{"x" * 40}" }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      text = described_class.fit(head: [ "# A" ], body: body, keep: [ "## Conventions" ], kind: :full, note: "_t_", max_lines: 150)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      expect(text.split("\n").count { |l| !l.strip.empty? }).to eq(150)
    end

    it "leaves text under the budget as it is" do
      expect(described_class.fit(head: [ "# A" ], body: [ "b" ], keep: [ "c" ], kind: :root, note: "_t_")).to eq("# A\nb\nc")
    end
  end

  # Every size rule lives in Budget; a literal cap in a renderer was the
  # seventh such number and the reason no file had a size anyone could state.
  it "is the only place a serializer caps a list" do
    dir = File.expand_path("../../../../lib/rails_ai_context/serializers", __dir__)
    offenders = Dir.glob(File.join(dir, "*.rb")).reject { |f| f.end_with?("budget.rb") }.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, i|
        "#{File.basename(file)}:#{i + 1}" if line.match?(/\.first\(\d+\)|limit: \d+|[A-Z_]+_SHOWN = \d+|max_show = \d+/)
      end
    end

    expect(offenders).to eq([])
  end
end
