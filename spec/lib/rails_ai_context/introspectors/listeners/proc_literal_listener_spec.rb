# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::ProcLiteralListener do
  it "records each Proc literal spelling with its line and source" do
    results = parse_and_dispatch(<<~RUBY)
      a = -> { 1 }
      b = lambda { 2 }
      c = proc { 3 }
      d = Proc.new { 4 }
    RUBY

    expect(results).to eq([
      { line: 1, constant: nil, source: "-> { 1 }" },
      { line: 2, constant: nil, source: "lambda { 2 }" },
      { line: 3, constant: nil, source: "proc { 3 }" },
      { line: 4, constant: nil, source: "Proc.new { 4 }" }
    ])
  end

  it "names the constant a Proc is assigned to" do
    results = parse_and_dispatch("QUEUE = -> { :low }\n")

    expect(results).to eq([ { line: 1, constant: "QUEUE", source: "-> { :low }" } ])
  end

  it "skips a call that only shares a name, and a Proc.new on another receiver" do
    results = parse_and_dispatch(<<~RUBY)
      lambda
      obj.proc { 1 }
      Other.new { 2 }
      x.lambda { 3 }
    RUBY

    expect(results).to eq([])
  end
end
