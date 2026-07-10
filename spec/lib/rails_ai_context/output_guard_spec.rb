# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::OutputGuard do
  it "redirects $stdout writes to $stderr during the block" do
    captured_out = StringIO.new
    captured_err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    begin
      $stdout = captured_out
      $stderr = captured_err
      described_class.quarantine_stdout { puts "boot noise" }
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    expect(captured_err.string).to include("boot noise")
    expect(captured_out.string).to be_empty
  end

  it "restores $stdout when the block raises" do
    original = $stdout
    expect {
      described_class.quarantine_stdout { raise ArgumentError, "boom" }
    }.to raise_error(ArgumentError, "boom")
    expect($stdout).to equal(original)
  end

  it "returns the block's value" do
    expect(described_class.quarantine_stdout { :value }).to eq(:value)
  end
end
