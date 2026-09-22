# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RailsAiContext.debug_fail" do
  let(:error) { RuntimeError.new("boom") }

  around do |example|
    previous = ENV["DEBUG"]
    example.run
    previous.nil? ? ENV.delete("DEBUG") : ENV["DEBUG"] = previous
  end

  def with_debug(value)
    value.nil? ? ENV.delete("DEBUG") : ENV["DEBUG"] = value
    captured = StringIO.new
    original = $stderr
    $stderr = captured
    yield
    captured.string
  ensure
    $stderr = original
  end

  it "returns the fallback" do
    ENV.delete("DEBUG")
    expect(RailsAiContext.debug_fail(error, [], label: "thing")).to eq([])
  end

  it "returns falsey fallbacks rather than skipping past them" do
    ENV.delete("DEBUG")
    expect(RailsAiContext.debug_fail(error, false, label: "thing")).to be(false)
    expect(RailsAiContext.debug_fail(error, 0, label: "thing")).to eq(0)
    expect(RailsAiContext.debug_fail(error, label: "thing")).to be_nil
  end

  it "writes nothing without DEBUG" do
    output = with_debug(nil) { RailsAiContext.debug_fail(error, [], label: "thing") }
    expect(output).to eq("")
  end

  it "writes the label and the error message to stderr under DEBUG" do
    output = with_debug("1") { RailsAiContext.debug_fail(error, [], label: "detect_form_builders") }
    expect(output).to eq("[rails-ai-context] detect_form_builders failed: boom\n")
  end

  it "still returns the fallback under DEBUG" do
    result = nil
    with_debug("1") { result = RailsAiContext.debug_fail(error, { a: 1 }, label: "thing") }
    expect(result).to eq({ a: 1 })
  end
end
