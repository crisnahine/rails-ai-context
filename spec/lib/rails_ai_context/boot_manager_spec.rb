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

  # Bundler::GemRequireError names the gem that failed to load and nothing
  # about why; the reason only lives in `cause`.
  it "names the cause of a wrapped boot failure" do
    dir = app_with_environment(<<~RUBY)
      begin
        raise ArgumentError, "wrong number of arguments (given 2, expected 1)"
      rescue ArgumentError
        raise "There was an error while trying to load the gem 'twitter-text'."
      end
    RUBY
    result = described_class.boot!(app_root: dir)
    expect(result.root_cause).to be_a(ArgumentError)
    expect(result.failure_summary)
      .to eq("RuntimeError: There was an error while trying to load the gem 'twitter-text'. " \
             "(cause: ArgumentError: wrong number of arguments (given 2, expected 1))")
  end

  it "reports no cause when the error raised itself" do
    dir = app_with_environment(%(raise "missing REDIS_URL"\n))
    expect(described_class.boot!(app_root: dir).root_cause).to be_nil
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

    it "passes an initializer's exit through with its status" do
      errors = StringIO.new
      original = $stderr
      $stderr = errors

      raised = nil
      begin
        described_class.guard { abort "Mastodon now requires that these variables are set:" }
      rescue SystemExit => e
        raised = e
      ensure
        $stderr = original
      end

      expect(raised).to be_a(SystemExit)
      expect(raised.status).to eq(1)
      expect(errors.string).to include("Mastodon now requires that these variables are set:")
      expect(errors.string).to include("[rails-ai-context] App called exit(1) during boot.")
    end

    # The notice and the boot failure are one sentence, so the caller that
    # prints both would say it twice.
    it "states what the app did, in the words the boot failure uses" do
      errors = StringIO.new
      original = $stderr
      $stderr = errors

      begin
        described_class.guard { exit 3 }
      rescue SystemExit # rubocop:disable Lint/SuppressedException
      ensure
        $stderr = original
      end

      expect(errors.string).to include(described_class::BootExitError.new("App called exit(3) during boot").message)
      expect(errors.string).not_to include("exited")
    end
  end

  describe ".boot! with an app that exits" do
    it "reports the exit as a boot failure the static tier can answer around" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "environment.rb"), %(abort "no RAILS_ENV"\n))

        errors = StringIO.new
        original = $stderr
        $stderr = errors
        begin
          result = described_class.boot!(app_root: dir)
        ensure
          $stderr = original
        end

        expect(result).not_to be_booted
        expect(result.error).to be_a(described_class::BootExitError)
        expect(result.failure_summary).to include("App called exit(1) during boot")
      end
    end

    # The binary prints the failure summary and then answers from the static
    # tier, so the guard's own notice would be the same sentence twice.
    it "leaves the notice to the caller that lets the exit stand" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "environment.rb"), %(abort "no RAILS_ENV"\n))

        errors = StringIO.new
        original = $stderr
        $stderr = errors
        begin
          described_class.boot!(app_root: dir)
        ensure
          $stderr = original
        end

        expect(errors.string).to include("no RAILS_ENV")
        expect(errors.string).not_to include("[rails-ai-context] App called exit")
      end
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
