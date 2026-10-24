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

    it "says require_master_key is unavailable when the config cannot be read, not false" do
      allow(Rails.application.config).to receive(:require_master_key).and_raise(NoMethodError)

      expect(result[:require_master_key]).to start_with("[UNAVAILABLE")
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

    # Rails reads config/credentials/<env>.yml.enc when it exists, with the key at
    # `credentials.key_path`; Rails 7.0 names <env>.key there even when that file is missing.
    context "with both the default and a per-environment credentials file" do
      let(:config_dir) { File.join(Rails.root, "config") }
      let(:env_enc) { File.join(config_dir, "credentials/test.yml.enc") }
      let(:env_key) { File.join(config_dir, "credentials/test.key") }
      let(:env_creds) { Rails.application.encrypted(env_enc, key_path: env_key) }

      around do |example|
        saved = ENV.delete("RAILS_MASTER_KEY")
        example.run
      ensure
        ENV["RAILS_MASTER_KEY"] = saved if saved
      end

      before do
        FileUtils.mkdir_p(File.dirname(env_enc))
        File.write(File.join(config_dir, "credentials.yml.enc"), "fake_encrypted_content_for_testing")
        File.write(env_key, ActiveSupport::EncryptedConfiguration.generate_key)
        env_creds.write("only_in_env_file: SENTINEL_ENV_VALUE\n")
        allow(Rails.application).to receive(:credentials).and_return(env_creds)
      end

      after do
        FileUtils.rm_f([ File.join(config_dir, "credentials.yml.enc"), File.join(config_dir, "master.key"), env_enc, env_key ])
        FileUtils.rm_rf(File.dirname(env_enc)) if Dir.exist?(File.dirname(env_enc)) && Dir.empty?(File.dirname(env_enc))
      end

      it "lists the key names under the file Rails read and names the key Rails uses" do
        env_entry = result[:environments].find { |e| e[:environment] == "test" }

        expect(env_entry[:top_level_keys]).to eq([ "only_in_env_file" ])
        expect(result[:default]).not_to have_key(:top_level_keys)
        expect(result[:master_key_source]).to eq("file:config/credentials/test.key")
        expect(result.inspect).not_to include("SENTINEL_ENV_VALUE")
      end

      it "reports the key as missing when the key file Rails names is not there, even beside master.key" do
        File.delete(env_key)
        File.write(File.join(config_dir, "master.key"), ActiveSupport::EncryptedConfiguration.generate_key)

        expect(result[:master_key_source]).to eq("missing")
      end
    end

    # `config.credentials.content_path` and `key_path` set to other files: Rails reads those.
    context "with credentials at a custom content_path" do
      let(:enc) { File.join(Rails.root, "config/secrets/app.yml.enc") }
      let(:key) { File.join(Rails.root, "config/secrets/app.key") }

      around do |example|
        saved = ENV.delete("RAILS_MASTER_KEY")
        example.run
      ensure
        ENV["RAILS_MASTER_KEY"] = saved if saved
        FileUtils.rm_rf(File.join(Rails.root, "config/secrets"))
      end

      before do
        FileUtils.mkdir_p(File.dirname(enc))
        File.write(key, ActiveSupport::EncryptedConfiguration.generate_key)
        creds = Rails.application.encrypted(enc, key_path: key)
        creds.write("only_in_custom_file: SENTINEL_CUSTOM_VALUE\n")
        allow(Rails.application).to receive(:credentials).and_return(creds)
      end

      it "lists the key names under the file Rails read" do
        expect(result[:custom]).to eq(file: "config/secrets/app.yml.enc", present: true, key_file: "config/secrets/app.key",
                                      key_file_present: true, top_level_keys: [ "only_in_custom_file" ])
        expect(result[:master_key_source]).to eq("file:config/secrets/app.key")
        expect(result.inspect).not_to include("SENTINEL_CUSTOM_VALUE")
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
        # arg - matches the real `ActiveSupport::EncryptedConfiguration#config`
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
        # Critically, the exception message - which includes the absolute
        # path `/Users/alice/secret/master.key` - must never reach output.
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

  # Without a boot there is no credentials object and no decryption, so the files are all it can report.
  # ActiveSupport::EncryptedFile keeps a symlinked content_path as its realpath (encrypted_file.rb, 7.0 to 8.1).
  describe "with credentials files behind symlinks" do
    around do |example|
      saved = ENV.delete("RAILS_MASTER_KEY")
      Dir.mktmpdir do |tmp|
        @app_root = File.join(tmp, "app")
        @outside = File.join(tmp, "outside-secrets")
        FileUtils.mkdir_p([ File.join(@app_root, "config/credentials"), @outside ])
        example.run
      end
    ensure
      ENV["RAILS_MASTER_KEY"] = saved if saved
    end

    def booted_result(content_path, key_path)
      File.write(key_path, ActiveSupport::EncryptedConfiguration.generate_key) unless File.exist?(key_path)
      creds = ActiveSupport::EncryptedConfiguration.new(config_path: content_path, key_path: key_path, env_key: "RAILS_MASTER_KEY", raise_if_missing_key: false)
      creds.write("api_token: SENTINEL_LINKED_VALUE\n")
      app = Struct.new(:root, :credentials).new(Pathname.new(@app_root), creds)
      described_class.new(app).call
    end

    it "lists the default file's key names when it links outside the app, and prints no outside path" do
      FileUtils.touch(File.join(@outside, "real.yml.enc"))
      File.symlink(File.join(@outside, "real.yml.enc"), File.join(@app_root, "config/credentials.yml.enc"))
      File.write(File.join(@outside, "master.key"), ActiveSupport::EncryptedConfiguration.generate_key)
      File.symlink(File.join(@outside, "master.key"), File.join(@app_root, "config/master.key"))
      result = booted_result(File.join(@app_root, "config/credentials.yml.enc"), File.join(@app_root, "config/master.key"))

      expect(result).not_to have_key(:custom)
      expect(result[:master_key_source]).to eq("file:config/master.key")
      expect(result[:default][:top_level_keys]).to eq([ "api_token" ])
      expect(result.inspect).not_to include("outside-secrets")
      expect(result.inspect).not_to include("SENTINEL_LINKED_VALUE")
    end

    it "lists an environment file's key names when it links outside the app" do
      env = RailsAiContext.environment_name
      FileUtils.touch(File.join(@outside, "env.yml.enc"))
      File.symlink(File.join(@outside, "env.yml.enc"), File.join(@app_root, "config/credentials/#{env}.yml.enc"))
      result = booted_result(File.join(@app_root, "config/credentials/#{env}.yml.enc"), File.join(@app_root, "config/credentials/#{env}.key"))

      expect(result).not_to have_key(:custom)
      expect(result[:environments].find { |entry| entry[:environment] == env }[:top_level_keys]).to eq([ "api_token" ])
      expect(result.inspect).not_to include("outside-secrets")
    end

    it "names a custom content_path outside the app without its path" do
      result = booted_result(File.join(@outside, "app.yml.enc"), File.join(@outside, "app.key"))

      expect(result[:custom]).to eq(file: "(outside the app root)", present: true, key_file: "(outside the app root)",
                                    key_file_present: true, top_level_keys: [ "api_token" ])
      expect(result[:master_key_source]).to eq("file:(outside the app root)")
      expect(result.inspect).not_to include("outside-secrets")
    end
  end

  describe "on the static tier" do
    it "reports the credentials files it sees without key names and without failing" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config/credentials"))
        File.write(File.join(dir, "config/credentials.yml.enc"), "fake_encrypted_content_for_testing")
        File.write(File.join(dir, "config/master.key"), "0" * 32)
        File.write(File.join(dir, "config/credentials/production.yml.enc"), "fake_encrypted_content_for_testing")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call

        expect(result[:default]).to eq(file: "config/credentials.yml.enc", present: true,
                                       key_file: "config/master.key", key_file_present: true)
        expect(result[:environments]).to eq([ { environment: "production", file: "config/credentials/production.yml.enc",
                                                key_file: "config/credentials/production.key", key_file_present: false } ])
      end
    end

    # Expected sources are what Rails 7.0.10 and 8.1.4 report as credentials.key_path in a development app.
    def static_key_source(rails:, files:)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    railties (#{rails})\n\nDEPENDENCIES\n  railties\n")
        FileUtils.mkdir_p(File.join(dir, "config/credentials"))
        files.each { |relative| File.write(File.join(dir, relative), "x") }
        allow(RailsAiContext).to receive(:environment_name).and_return("development")
        described_class.new(RailsAiContext::StaticApp.new(dir)).call[:master_key_source]
      end
    end

    it "names the key Rails reads for per-environment credentials, by the locked Rails version" do
      stub_const("ENV", ENV.to_h.except("RAILS_MASTER_KEY"))
      both = %w[config/credentials.yml.enc config/master.key config/credentials/development.yml.enc]

      expect(static_key_source(rails: "7.0.10", files: both + %w[config/credentials/development.key])).to eq("file:config/credentials/development.key")
      expect(static_key_source(rails: "8.1.4", files: both + %w[config/credentials/development.key])).to eq("file:config/credentials/development.key")
      expect(static_key_source(rails: "7.0.10", files: both)).to eq("missing")
      expect(static_key_source(rails: "7.1.6", files: both)).to eq("file:config/master.key")
      only_key = %w[config/credentials.yml.enc config/master.key config/credentials/development.key]
      expect(static_key_source(rails: "7.0.10", files: only_key)).to eq("file:config/master.key")
      expect(static_key_source(rails: "8.1.4", files: only_key)).to eq("file:config/credentials/development.key")
    end

    def static_require_master_key(files)
      Dir.mktmpdir do |dir|
        files.each do |relative, body|
          FileUtils.mkdir_p(File.dirname(File.join(dir, relative)))
          File.write(File.join(dir, relative), body)
        end
        described_class.new(RailsAiContext::StaticApp.new(dir)).call[:require_master_key]
      end
    end

    let(:env_file) { "config/environments/#{RailsAiContext.environment_name}.rb" }

    it "reads a literal require_master_key, the environment file winning over application.rb" do
      expect(static_require_master_key("config/application.rb" => "config.require_master_key = true\n")).to eq(true)
      expect(static_require_master_key("config/application.rb" => "config.require_master_key = true\n",
                                       env_file => "Rails.application.configure do\n  config.require_master_key = false\nend\n")).to eq(false)
    end

    # railties 7.0 to 8.1 configuration.rb: `@require_master_key = false`, and no load_defaults changes it.
    it "answers Rails' default, false, when no file Rails runs sets it outside a comment" do
      expect(static_require_master_key({})).to eq(false)
      expect(static_require_master_key(env_file => "Rails.application.configure do\n  # config.require_master_key = true\nend\n")).to eq(false)
    end

    it "takes text that names the setting in a string or after __END__ for no mention, and a send that names it for one" do
      unknown = RailsAiContext::Confidence.unavailable(RailsAiContext::Introspectors::StaticTier.unavailable_reason)

      expect(static_require_master_key(env_file => "warn \"set require_master_key in production\"\n")).to eq(false)
      expect(static_require_master_key(env_file => "x = 1\n__END__\nconfig.require_master_key = true\n")).to eq(false)
      expect(static_require_master_key(env_file => "config.public_send(:require_master_key=, true)\n")).to eq(unknown)
    end

    it "follows an environment file's require_relative into config/, in the order the files run" do
      production = { "config/environments/production.rb" => "Rails.application.configure do\n  config.require_master_key = true\nend\n" }

      expect(static_require_master_key(production.merge(env_file => "require_relative \"production\"\n"))).to eq(true)
      expect(static_require_master_key(production.merge(env_file => "require_relative \"production\"\nRails.application.configure do\n  config.require_master_key = false\nend\n"))).to eq(false)
      expect(static_require_master_key(env_file => "require \"active_support/core_ext/integer/time\"\n")).to eq(false)
    end

    it "says the value is unknown when a file Rails runs loads one it cannot follow" do
      unknown = RailsAiContext::Confidence.unavailable(RailsAiContext::Introspectors::StaticTier.unavailable_reason)

      expect(static_require_master_key(env_file => "load \"config/strict.rb\"\n")).to eq(unknown)
      expect(static_require_master_key(env_file => "require_relative \"../../lib/strict\"\n", "lib/strict.rb" => "")).to eq(unknown)
      expect(static_require_master_key(env_file => "require_relative ENV.fetch(\"BASE\")\n")).to eq(unknown)
    end

    it "says the value is unknown when no literal sets it" do
      unknown = RailsAiContext::Confidence.unavailable(RailsAiContext::Introspectors::StaticTier.unavailable_reason)

      expect(static_require_master_key(env_file => "config.require_master_key = ENV[\"STRICT\"].present?\n")).to eq(unknown)
      expect(static_require_master_key(env_file => "config.require_master_key = true if ENV[\"CI\"]\n")).to eq(unknown)
    end
  end
end
