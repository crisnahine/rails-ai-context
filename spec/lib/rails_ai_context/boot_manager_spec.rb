# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::BootManager do
  def app_with_environment(content)
    dir = Dir.mktmpdir("boot-manager")
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "environment.rb"), content)
    dir
  end

  it "returns a booted result when the environment file loads cleanly" do
    dir = app_with_environment("$boot_manager_probe = :loaded\n")
    result = described_class.boot!(app_root: dir)
    expect(result).to be_booted
    expect(result.failure_summary).to be_nil
    expect($boot_manager_probe).to eq(:loaded)
  end

  it "quarantines stdout writes during boot" do
    dir = app_with_environment(%(puts "chatty initializer"\n))
    captured_out = StringIO.new
    captured_err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    begin
      $stdout = captured_out
      $stderr = captured_err
      expect(described_class.boot!(app_root: dir)).to be_booted
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    expect(captured_out.string).to be_empty
    expect(captured_err.string).to include("chatty initializer")
  end

  it "captures StandardError raised during boot" do
    dir = app_with_environment(%(raise "missing REDIS_URL"\n))
    result = described_class.boot!(app_root: dir)
    expect(result).not_to be_booted
    expect(result.error).to be_a(RuntimeError)
    expect(result.failure_summary).to eq("RuntimeError: missing REDIS_URL")
  end

  it "captures SyntaxError raised during boot" do
    dir = app_with_environment("def broken(\n")
    result = described_class.boot!(app_root: dir)
    expect(result).not_to be_booted
    expect(result.error).to be_a(ScriptError)
  end

  it "times out a hanging boot with a friendly message, not the raw Timeout::Error" do
    dir = app_with_environment("sleep 5\n")
    result = described_class.boot!(app_root: dir, timeout: 1)
    expect(result).not_to be_booted
    expect(result.error).to be_a(described_class::BootTimeoutError)
    expect(result.failure_summary).to include("did not finish within 1s")
    expect(result.failure_summary).not_to include("Timeout::Error")
    expect(result.failure_summary).not_to include("execution expired")
  end

  it "fails with a clear message when no Rails app exists" do
    dir = Dir.mktmpdir("boot-manager-empty")
    result = described_class.boot!(app_root: dir)
    expect(result).not_to be_booted
    expect(result.failure_summary).to include("No Rails app found")
  end

  describe ".guard" do
    it "returns a booted result when the block succeeds" do
      result = described_class.guard { :ok }
      expect(result).to be_booted
    end

    it "times out a hanging block with the friendly message" do
      result = described_class.guard(timeout: 1) { sleep 5 }
      expect(result).not_to be_booted
      expect(result.error).to be_a(described_class::BootTimeoutError)
      expect(result.failure_summary).to include("did not finish within 1s")
    end

    it "captures StandardError from the block" do
      result = described_class.guard { raise "missing REDIS_URL" }
      expect(result).not_to be_booted
      expect(result.failure_summary).to eq("RuntimeError: missing REDIS_URL")
    end
  end

  describe ".env_timeout" do
    around do |example|
      original = ENV["RAILS_AI_CONTEXT_BOOT_TIMEOUT"]
      example.run
    ensure
      if original.nil?
        ENV.delete("RAILS_AI_CONTEXT_BOOT_TIMEOUT")
      else
        ENV["RAILS_AI_CONTEXT_BOOT_TIMEOUT"] = original
      end
    end

    it "returns the default when unset" do
      ENV.delete("RAILS_AI_CONTEXT_BOOT_TIMEOUT")
      expect(described_class.env_timeout).to eq(described_class::DEFAULT_TIMEOUT)
    end

    it "parses the variable" do
      ENV["RAILS_AI_CONTEXT_BOOT_TIMEOUT"] = "7"
      expect(described_class.env_timeout).to eq(7)
    end

    it "warns and falls back on a value that is not a number" do
      ENV["RAILS_AI_CONTEXT_BOOT_TIMEOUT"] = "soon"
      captured = StringIO.new
      orig_err = $stderr
      begin
        $stderr = captured
        expect(described_class.env_timeout).to eq(described_class::DEFAULT_TIMEOUT)
      ensure
        $stderr = orig_err
      end
      expect(captured.string).to include("not a number")
    end
  end
end
