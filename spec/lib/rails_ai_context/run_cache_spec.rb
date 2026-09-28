# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::RunCache do
  it "answers a key once within a run" do
    calls = 0
    answers = described_class.around do
      Array.new(3) { described_class.fetch(:k) { calls += 1 } }
    end

    expect(answers).to eq([ 1, 1, 1 ])
    expect(calls).to eq(1)
  end

  it "asks every time outside a run, and forgets a run's answers when it ends" do
    calls = 0
    described_class.around { described_class.fetch(:k) { calls += 1 } }
    2.times { described_class.fetch(:k) { calls += 1 } }

    expect(calls).to eq(3)
    expect(described_class.active?).to be(false)
  end

  it "keeps a nil or false answer" do
    calls = 0
    described_class.around do
      2.times { described_class.fetch(:none) { calls += 1; nil } }
    end

    expect(calls).to eq(1)
  end

  it "shares the outer run's answers with a nested one, and ends with the outer one" do
    described_class.around do
      described_class.fetch(:k) { :outer }
      described_class.around { expect(described_class.fetch(:k) { :inner }).to eq(:outer) }
      expect(described_class.active?).to be(true)
    end

    expect(described_class.active?).to be(false)
  end

  it "ends the run when the block raises, and keeps no answer the block did not give" do
    expect { described_class.around { described_class.fetch(:k) { raise "boom" } } }.to raise_error("boom")
    expect(described_class.active?).to be(false)

    described_class.around do
      expect { described_class.fetch(:k) { raise "again" } }.to raise_error("again")
      expect(described_class.fetch(:k) { :then }).to eq(:then)
    end
  end

  # Two MCP requests on two threads each have their own run.
  it "keeps one thread's run from another" do
    seen = nil
    described_class.around do
      described_class.fetch(:k) { :mine }
      Thread.new { seen = [ described_class.active?, described_class.fetch(:k) { :theirs } ] }.join
    end

    expect(seen).to eq([ false, :theirs ])
  end
end
