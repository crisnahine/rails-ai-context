# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Redaction do
  describe ".call" do
    it "strips URI userinfo" do
      expect(described_class.call("redis://app:hunter2@cache.internal:6379/0"))
        .to eq("redis://[FILTERED]@cache.internal:6379/0")
    end

    it "strips a quoted value behind a secret-ish key" do
      expect(described_class.call('password: "hunter2"')).to eq('password: "[FILTERED]"')
      expect(described_class.call('api_key => "abc123"')).to eq('api_key => "[FILTERED]"')
    end

    it "strips a bare assignment to a secret-ish name" do
      expect(described_class.call('secret_key = "s3cr3t"')).to eq('secret_key = "[FILTERED]"')
    end

    it "leaves a value that carries no credential alone" do
      expect(described_class.call("config.eager_load = true")).to eq("config.eager_load = true")
    end

    it "leaves a word that merely contains a key name alone" do
      expect(described_class.call("passwordless_login = true")).to eq("passwordless_login = true")
    end

    it "handles a nil value" do
      expect(described_class.call(nil)).to be_nil
    end
  end

  describe ".redact_and_shorten" do
    # The bug this exists to make unwritable: shortening first cuts the
    # credential away from the `@host` the pattern needs, so the prefix of a
    # real password ships in plaintext.
    it "redacts a credential that a cut would have separated from its host" do
      long = "redis://app:#{'z' * 200}@cache.internal:6379/0"

      expect(described_class.redact_and_shorten(long, 60)).to eq("redis://[FILTERED]@cache.internal:6379/0")
    end

    it "redacts a long quoted secret before the cut can split the quotes" do
      long = %(password: "#{'z' * 200}")

      expect(described_class.redact_and_shorten(long, 60)).to eq('password: "[FILTERED]"')
    end

    it "still shortens a long value that carries no credential" do
      result = described_class.redact_and_shorten("a" * 200, 60)

      expect(result.length).to eq(60)
      expect(result).to end_with("...")
    end

    it "leaves a short value untouched" do
      expect(described_class.redact_and_shorten("timeout = 30", 60)).to eq("timeout = 30")
    end
  end

  # The config listener sees the assigned value on its own; the setting's
  # name is the only thing that says whether it is a secret.
  describe ".redact_setting" do
    it "filters a value assigned to a secret-named setting" do
      expect(described_class.redact_setting(:secret_key, '"s3cr3t"')).to eq('"[FILTERED]"')
      expect(described_class.redact_setting("api_key", '"abc123"')).to eq('"[FILTERED]"')
    end

    it "keeps the quoting style it was given" do
      expect(described_class.redact_setting(:password, "'hunter2'")).to eq("'[FILTERED]'")
      expect(described_class.redact_setting(:password, "ENV['PW']")).to eq("[FILTERED]")
    end

    it "leaves an ordinary setting's value alone" do
      expect(described_class.redact_setting(:eager_load, "true")).to eq("true")
      expect(described_class.redact_setting(:timeout_in, "30.minutes")).to eq("30.minutes")
    end

    it "still scrubs a credential embedded in an ordinary setting's value" do
      expect(described_class.redact_setting(:cache_store, '"redis://app:pw@cache:6379"'))
        .to eq('"redis://[FILTERED]@cache:6379"')
    end

    it "handles a setting with no value" do
      expect(described_class.redact_setting(:jwt, nil)).to be_nil
    end

    # An evaluated value is not always a String: the AST extractor returns
    # arrays, hashes, symbols and numbers. Letting those past because they
    # are not Strings leaves the credential in the one field that skipped
    # the check.
    it "filters a secret-named setting holding an array" do
      expect(described_class.redact_setting(:secret_keys, [ "abc123", "def456" ])).to eq("[FILTERED]")
    end

    it "filters a secret-named setting holding a hash" do
      expect(described_class.redact_setting(:credentials, { token: "tok_live_xyz" })).to eq("[FILTERED]")
    end

    it "filters a secret-named setting holding a symbol" do
      expect(described_class.redact_setting(:api_key, :some_constant)).to eq("[FILTERED]")
    end

    it "leaves a non-string value of an ordinary setting alone" do
      expect(described_class.redact_setting(:timeout_in, 30)).to eq(30)
      expect(described_class.redact_setting(:eager_load, true)).to be(true)
      expect(described_class.redact_setting(:queue_adapter, :sidekiq)).to eq(:sidekiq)
    end

    # A descriptor still describes, whatever type it holds.
    it "leaves a descriptor's non-string value alone" do
      expect(described_class.redact_setting(:password_length, 6..128)).to eq(6..128)
    end
  end

  describe ".redact_log_line" do
    it "uses the email marker for addresses" do
      expect(described_class.redact_log_line("Sent to ada@example.com"))
        .to eq("Sent to [EMAIL]")
    end

    it "uses the filtered marker for everything else" do
      expect(described_class.redact_log_line('{"password":"hunter2"}'))
        .to include("[FILTERED]")
    end

    it "never emits the old markers" do
      samples = [
        '{"password":"hunter2"}',
        "SECRET_KEY_BASE=abcdef0123456789",
        "[dotenv] Set SECRET_KEY_BASE, DATABASE_URL"
      ]

      samples.each do |sample|
        expect(described_class.redact_log_line(sample)).not_to include("REDACTED")
      end
    end
  end

  describe "the marker vocabulary" do
    it "publishes exactly the two markers" do
      expect(described_class::FILTERED).to eq("[FILTERED]")
      expect(described_class::EMAIL).to eq("[EMAIL]")
    end
  end
end

RSpec.describe "Redaction marker vocabulary in lib" do
  it "spells no marker other than [FILTERED] and [EMAIL]" do
    lib_root = File.expand_path("../../../lib", __dir__)

    offenders = Dir.glob(File.join(lib_root, "**", "*.rb")).flat_map { |file|
      File.readlines(file).each_with_index.filter_map { |line, i|
        next unless line.match?(/\[REDACTED\]|\[redacted\]|REDACTED\]/)
        "#{file.sub("#{lib_root}/", '')}:#{i + 1}"
      }
    }

    expect(offenders).to be_empty,
      "Files still emitting a retired redaction marker: #{offenders.join(', ')}"
  end
end
