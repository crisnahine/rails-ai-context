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
    # Element-wise, not wholesale: the reader still learns the shape - that
    # there are two keys, that a hash has a `token` - while the values go.
    it "filters a secret-named setting holding an array" do
      expect(described_class.redact_setting(:secret_keys, [ "abc123", "def456" ]))
        .to eq([ "[FILTERED]", "[FILTERED]" ])
    end

    it "filters a secret-named setting holding a hash" do
      expect(described_class.redact_setting(:credentials, { token: "tok_live_xyz" }))
        .to eq(token: "[FILTERED]")
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

    # A Symbol is an identifier, a boolean is a policy, a number is a size.
    # None of them is credential material, and filtering them hides the
    # config a reader came for.
    it "keeps a secret-named setting's symbol and boolean values" do
      expect(described_class.redact_setting(:reset_password_keys, [ :email ])).to eq([ :email ])
      expect(described_class.redact_setting(:send_password_change_notification, false)).to be(false)
      expect(described_class.redact_setting(:api_key, :from_env)).to eq(:from_env)
    end

    it "filters the strings inside a secret-named collection" do
      expect(described_class.redact_setting(:secret_keys, [ "abc123", "def456" ]))
        .to eq([ "[FILTERED]", "[FILTERED]" ])
    end

    # The classic stock Rails line: the setting is not secret-named, the key
    # inside it is.
    it "filters a credential nested under an ordinary setting" do
      settings = { user_name: "app", password: "hunter2", address: "smtp.example.com" }

      expect(described_class.redact_setting(:smtp_settings, settings))
        .to eq(user_name: "app", password: "[FILTERED]", address: "smtp.example.com")
    end

    it "filters a credential nested two levels down" do
      value = { cache: { url: "redis://u:pw@host:6379", token: "tok_live_xyz" } }

      expect(described_class.redact_setting(:stores, value))
        .to eq(cache: { url: "redis://[FILTERED]@host:6379", token: "[FILTERED]" })
    end

    it "still scrubs a URI credential inside an ordinary collection" do
      expect(described_class.redact_setting(:cache_store, [ :redis_cache_store, { url: "redis://u:pw@h:6379" } ]))
        .to eq([ :redis_cache_store, { url: "redis://[FILTERED]@h:6379" } ])
    end
  end

  # Devise's pepper and ActiveRecord encryption's keys are the two most
  # common hand-written secrets in config/initializers.
  describe "secret vocabulary" do
    it "recognises the names people actually put credentials under" do
      %i[pepper salt master_key signing_key encryption_key deterministic_key key_derivation_salt].each do |name|
        expect(described_class.redact_setting(name, '"abc123deadbeef"'))
          .to eq('"[FILTERED]"'), "#{name} was not treated as a secret"
      end
    end

    # `primary_key` is ordinary ActiveRecord vocabulary; only the encryption
    # one is a credential, and the path is what tells them apart.
    it "leaves a bare primary_key alone but filters the encryption one" do
      expect(described_class.redact_setting(:primary_key, ":id")).to eq(":id")
      expect(described_class.redact_setting(%i[active_record encryption primary_key], '"deadbeef"'))
        .to eq('"[FILTERED]"')
    end
  end

  # The listener emits an evaluated value and the raw source slice for the
  # same assignment. Deciding separately let them disagree: `source` is
  # always a String, so a rule about the value's type never reached it, and
  # `secret_key = 12345` came out filtered in one field and plain in the
  # other. One decision, both fields.
  describe ".redact_assignment" do
    def redact(name, value, source)
      described_class.redact_assignment(name, value: value, source: source)
    end

    it "filters both fields for a numeric secret" do
      expect(redact(:secret_key, 12345, "12345"))
        .to eq(value: "[FILTERED]", source: "[FILTERED]")
    end

    it "keeps both fields for a policy switch" do
      expect(redact(:send_password_change_notification, false, "false"))
        .to eq(value: false, source: "false")
    end

    it "keeps both fields for a list of field names" do
      expect(redact(:reset_password_keys, [ :email ], "[:email]"))
        .to eq(value: [ :email ], source: "[:email]")
    end

    it "keeps both fields for a descriptor" do
      expect(redact(:password_length, "[INFERRED]", "6..128"))
        .to eq(value: "[INFERRED]", source: "6..128")
    end

    # A descriptor suffix suppresses a name, and that suppression used to win
    # even when the value was plainly a credential.
    it "filters a credential-shaped value a descriptor suffix would have excused" do
      expect(redact(:api_key_params, "sk_live_abcdefghijkl", '"sk_live_abcdefghijkl"'))
        .to eq(value: "[FILTERED]", source: '"[FILTERED]"')
    end

    it "still reaches a credential nested under an ordinary setting" do
      result = redact(:smtp_settings,
                      { user_name: "app", password: "hunter2" },
                      '{ user_name: "app", password: "hunter2" }')

      expect(result[:value]).to eq(user_name: "app", password: "[FILTERED]")
      expect(result[:source]).to include("[FILTERED]")
      expect(result[:source]).to include("app")
    end

    it "handles an assignment with no value" do
      expect(redact(:jwt, nil, nil)).to eq(value: nil, source: nil)
    end
  end

  # The env tool cannot redact a `.env.example` default the way a log line is
  # scrubbed - there is no surrounding key to match on, only the value. What
  # it needs from the module is the judgement, not the marker.
  describe ".secret_value?" do
    it "recognises a long hex blob" do
      expect(described_class.secret_value?("a1b2c3d4e5f60718")).to be(true)
    end

    it "recognises vendor key prefixes" do
      expect(described_class.secret_value?("sk_live_abc")).to be(true)
      expect(described_class.secret_value?("pk_test_abc")).to be(true)
    end

    it "recognises a value that names itself a secret" do
      expect(described_class.secret_value?("my_secret_thing")).to be(true)
      expect(described_class.secret_value?("key_abc")).to be(true)
    end

    it "leaves an ordinary value alone" do
      expect(described_class.secret_value?("development")).to be(false)
      expect(described_class.secret_value?("localhost:3000")).to be(false)
      expect(described_class.secret_value?("")).to be(false)
    end
  end

  # A `.env.example` exists to be read: its values are placeholders, and the
  # word "secret" in one is a label, not a credential. Only a value actually
  # shaped like a credential is worth hiding there.
  describe ".credential_shaped?" do
    it "recognises a hex blob or a vendor prefix" do
      expect(described_class.credential_shaped?("a1b2c3d4e5f60718")).to be(true)
      expect(described_class.credential_shaped?("sk_live_abc")).to be(true)
    end

    it "leaves a value that merely says 'secret' alone" do
      expect(described_class.credential_shaped?("<your-secret-here>")).to be(false)
      expect(described_class.credential_shaped?("generate_with_rails_secret")).to be(false)
      expect(described_class.credential_shaped?("some_key_name")).to be(false)
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
