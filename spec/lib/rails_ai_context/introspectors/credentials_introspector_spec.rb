# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::CredentialsIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns a Hash without error" do
      expect(result).to be_a(Hash)
      expect(result).not_to have_key(:error)
    end

    it "returns default credentials metadata" do
      expect(result[:default]).to be_a(Hash)
      expect(result[:default][:file]).to eq("config/credentials.yml.enc")
      expect(result[:default]).to have_key(:present)
    end

    it "returns environments as array" do
      expect(result[:environments]).to be_an(Array)
    end

    it "reports master_key_source as one of expected strings" do
      expect(result[:master_key_source]).to be_in([ "env:RAILS_MASTER_KEY", "file:config/master.key", "missing" ])
    end

    it "returns require_master_key as boolean" do
      expect(result[:require_master_key]).to eq(true).or(eq(false))
    end

    it "returns encrypted_configs as array" do
      expect(result[:encrypted_configs]).to be_an(Array)
    end

    context "with a per-environment encrypted credentials file" do
      let(:creds_dir) { File.join(Rails.root, "config/credentials") }
      let(:enc_path) { File.join(creds_dir, "staging.yml.enc") }

      before do
        FileUtils.mkdir_p(creds_dir)
        File.write(enc_path, "encrypted_fake_content")
      end

      after do
        FileUtils.rm_f(enc_path)
        FileUtils.rm_rf(creds_dir) if Dir.exist?(creds_dir) && Dir.empty?(creds_dir)
      end

      it "lists the environment" do
        entry = result[:environments].find { |e| e[:environment] == "staging" }
        expect(entry).not_to be_nil
        expect(entry[:file]).to eq("config/credentials/staging.yml.enc")
        expect(entry[:key_file_present]).to eq(false)
      end
    end

    it "never leaks decrypted values in output" do
      serialized = result.inspect
      # Whatever content exists in credentials must not appear raw in output.
      # We assert the output is a structured hash with no unexpected string payload
      expect(result[:default]).not_to have_key(:values)
      expect(serialized).not_to include("secret_key_base")
    end

    context "with a stubbed credentials object containing a sentinel value" do
      let(:sentinel) { "SENTINEL_CREDENTIAL_VALUE_MUST_NEVER_APPEAR" }
      let(:stub_creds) do
        # Struct's single-field constructor takes the hash as its one positional
        # arg — matches the real `ActiveSupport::EncryptedConfiguration#config`
        # API which returns a Hash.
        Struct.new(:config).new({ api_key: sentinel, database_password: sentinel, secret_token: sentinel })
      end

      let(:enc_path) { File.join(Rails.root, "config/credentials.yml.enc") }

      before do
        # `inspect_default_credentials` short-circuits if the .enc file
        # doesn't exist. Create a fake one so the stubbed creds path is
        # actually reached.
        File.write(enc_path, "fake_encrypted_content_for_testing")
        allow(Rails.application).to receive(:credentials).and_return(stub_creds)
      end

      after { FileUtils.rm_f(enc_path) }

      it "returns top-level key names but not values" do
        top_level = result[:default][:top_level_keys]
        expect(top_level).to be_an(Array)
        expect(top_level).to contain_exactly("api_key", "database_password", "secret_token")
        expect(result.inspect).not_to include(sentinel)
      end
    end

    context "when credentials inspection raises mid-inspection" do
      let(:enc_path) { File.join(Rails.root, "config/credentials.yml.enc") }

      let(:raising_creds) do
        Class.new do
          def config
            raise Errno::EACCES, "/Users/alice/secret/master.key"
          end
        end.new
      end

      before do
        File.write(enc_path, "fake_encrypted_content_for_testing")
        allow(Rails.application).to receive(:credentials).and_return(raising_creds)
      end

      after { FileUtils.rm_f(enc_path) }

      it "surfaces structured error metadata without echoing the exception message" do
        # The inner `attempt_top_level_keys` rescues and returns nil, so the
        # `:default` hash reports `present: true` with no `:top_level_keys`.
        # Critically, the exception message — which includes the absolute
        # path `/Users/alice/secret/master.key` — must never reach output.
        default = result[:default]
        expect(default[:file]).to eq("config/credentials.yml.enc")
        expect(default[:present]).to eq(true)
        expect(default[:top_level_keys]).to be_nil
        # Username path from the exception message never leaks. (The
        # hard-coded "config/master.key" reported as `key_file` is a safe
        # relative path and not derived from user input.)
        expect(result.inspect).not_to include("/Users/alice")
        expect(result.inspect).not_to include("alice/secret")
      end
    end
  end
end
