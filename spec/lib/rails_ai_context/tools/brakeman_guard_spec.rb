# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::BrakemanGuard do
  around do |example|
    saved_env = ENV.fetch("DEBUG", nil)
    saved_debug = $DEBUG
    example.run
  ensure
    saved_env ? ENV["DEBUG"] = saved_env : ENV.delete("DEBUG")
    $DEBUG = saved_debug
  end

  # Brakeman's ruby_parser runs `$DEBUG = true if ENV["DEBUG"]` as it loads,
  # and a DEBUG=1 run then printed every exception the process raised.
  it "hides DEBUG from what runs inside and puts $DEBUG back after" do
    ENV["DEBUG"] = "1"
    seen = described_class.quietly do
      debug = ENV.fetch("DEBUG", nil)
      $DEBUG = true if ENV["DEBUG"]
      debug
    end

    expect(seen).to be_nil
    expect($DEBUG).to be(false)
    expect(ENV.fetch("DEBUG", nil)).to eq("1")
  end

  it "puts both back when the block raises" do
    ENV["DEBUG"] = "1"
    expect { described_class.quietly { $DEBUG = true; raise "scan failed" } }.to raise_error("scan failed")

    expect($DEBUG).to be(false)
    expect(ENV.fetch("DEBUG", nil)).to eq("1")
  end
end
