# frozen_string_literal: true

require "spec_helper"

# The promise this seam makes is negative: the block never sees anything but
# real data, and every other case comes back as an honest answer rather than
# a crash or an empty-looking result. Negative promises are what example
# specs miss, because the missing case is the one nobody thought to write.
#
# Deterministic by construction - a failure names the exact section shape.
RSpec.describe "SectionFetch properties" do
  # Every shape an introspector section can be by the time a tool asks for it.
  UNUSABLE = {
    never_introspected: nil,
    raised: { error: "disk on fire" },
    raised_empty_message: { error: "" },
    data_source_absent: { unavailable: "requires a booted Rails app" },
    not_a_hash: "unexpected string",
    an_array: [],
    a_number: 42
  }.freeze

  USABLE = {
    empty_hash: {},
    real_data: { total: 3, rows: %w[a b] },
    hash_with_false: { enabled: false },
    hash_with_nil_error: { error: nil }
  }.freeze

  def tool_asking_for(section_data, key: :gems)
    klass = Class.new(RailsAiContext::Tools::BaseTool) do
      tool_name "rails_spec_section_probe"
      description "probe"
      input_schema(properties: {})
    end
    allow(klass).to receive(:cached_context).and_return(section_data.nil? ? {} : { key => section_data })
    klass
  end

  after { @built&.each(&:abstract!) }

  def fetch(section_data, **options, &block)
    tool = tool_asking_for(section_data)
    (@built ||= []) << tool
    tool.fetch_section(:gems, subject: "Gem introspection", **options, &block)
  end

  it "never hands the block anything but a usable hash" do
    leaked = []

    UNUSABLE.each do |name, data|
      fetch(data) { |given| leaked << "#{name}: block received #{given.inspect}" }
    end

    expect(leaked).to be_empty,
      "The block ran for #{leaked.size} unusable shape(s):\n#{leaked.join("\n")}"
  end

  it "answers every unusable shape with text a caller can read" do
    bad = []

    UNUSABLE.each do |name, data|
      response = fetch(data) { "must not run" }

      text = response.respond_to?(:content) ? response.content.first[:text] : nil
      bad << "#{name}: #{response.inspect}" if text.nil? || text.strip.empty?
    end

    expect(bad).to be_empty,
      "#{bad.size} unusable shape(s) produced no readable answer:\n#{bad.join("\n")}"
  end

  it "runs the block for every usable shape" do
    skipped = []

    USABLE.each do |name, data|
      ran = false
      fetch(data) { ran = true }
      skipped << name unless ran
    end

    expect(skipped).to be_empty,
      "#{skipped.size} usable shape(s) never reached the block:\n#{skipped.join("\n")}"
  end

  it "hands the block the section itself, unaltered" do
    mismatched = []

    USABLE.each do |name, data|
      fetch(data) { |given| mismatched << name unless given == data }
    end

    expect(mismatched).to be_empty, "#{mismatched.size} shape(s) reached the block altered"
  end

  it "never raises, whatever the section turned out to be" do
    (UNUSABLE.merge(USABLE)).each do |name, data|
      expect { fetch(data) { |given| given } }.not_to raise_error, "raised for #{name}"
    end
  end

  # A runtime-only section must refuse on its declaration, not on whatever
  # the section hash happened to hold - including when it holds real data
  # left over from a previous boot.
  it "refuses a runtime-only section in the static tier, whatever the data says" do
    served = []

    allow(RailsAiContext).to receive(:static_tier?).and_return(true)
    allow(RailsAiContext).to receive(:static_reason).and_return("RuntimeError: boom")

    USABLE.each do |name, data|
      tool = tool_asking_for(data, key: :config)
      (@built ||= []) << tool

      response = tool.fetch_section(:config, subject: "Config introspection") { served << name }
      text = response.respond_to?(:content) ? response.content.first[:text] : ""
      served << "#{name}: answered #{text[0, 40]}" unless text.include?("requires a booted Rails app")
    end

    expect(served).to be_empty,
      "#{served.size} runtime-only case(s) were served in the static tier:\n#{served.join("\n")}"
  end

  it "serves a files-only section in the static tier" do
    allow(RailsAiContext).to receive(:static_tier?).and_return(true)

    ran = false
    fetch({ total: 1 }) { ran = true }

    expect(ran).to be(true)
  end
end
