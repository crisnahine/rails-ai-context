# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::BaseTool, ".sensitive_file?" do
  # sensitive_file? is the security boundary behind every tool that accepts a
  # file path. v5.8.0 had zero direct spec coverage on it. v5.8.1 adds this
  # spec so a regression in the matching logic or the default pattern list
  # would fail loudly.

  subject { described_class.send(:sensitive_file?, path) }

  shared_examples "blocks" do |path|
    let(:path) { path }
    it "blocks #{path}" do
      expect(subject).to be true
    end
  end

  shared_examples "allows" do |path|
    let(:path) { path }
    it "allows #{path}" do
      expect(subject).to be false
    end
  end

  describe "Rails secret files (should be blocked)" do
    include_examples "blocks", ".env"
    include_examples "blocks", ".env.production"
    include_examples "blocks", ".env.local"
    include_examples "blocks", "config/master.key"
    include_examples "blocks", "config/credentials.yml.enc"
    include_examples "blocks", "config/credentials/production.yml.enc"
  end

  describe "v5.8.1 expanded default patterns (should be blocked)" do
    include_examples "blocks", "config/database.yml"
    include_examples "blocks", "config/secrets.yml"
    include_examples "blocks", "config/cable.yml"
    include_examples "blocks", "config/storage.yml"
    include_examples "blocks", "config/redis.yml"
    include_examples "blocks", ".pgpass"
    include_examples "blocks", ".netrc"
    include_examples "blocks", ".my.cnf"
    include_examples "blocks", ".aws/credentials"
    include_examples "blocks", ".aws/config"
  end

  describe "private keys and certificates (should be blocked)" do
    include_examples "blocks", "certs/tls.pem"
    include_examples "blocks", "certs/private.key"
    include_examples "blocks", "certs/bundle.p12"
    include_examples "blocks", "certs/keystore.jks"
  end

  describe "common plaintext files (should NOT be blocked)" do
    include_examples "allows", "Gemfile"
    include_examples "allows", "Gemfile.lock"
    include_examples "allows", "README.md"
    include_examples "allows", "config/routes.rb"
    include_examples "allows", "config/application.rb"
    include_examples "allows", "app/models/user.rb"
    include_examples "allows", "app/controllers/users_controller.rb"
    include_examples "allows", "spec/models/user_spec.rb"
    include_examples "allows", ".rspec"
    include_examples "allows", ".rubocop.yml"
  end

  describe "case-insensitivity (File::FNM_CASEFOLD)" do
    include_examples "blocks", ".ENV"
    include_examples "blocks", "Config/Master.Key"
  end

  describe "basename-only matching (dotmatch)" do
    # sensitive_file? matches both the relative path AND the basename alone,
    # so a nested copy of .env or a key file still gets blocked.
    include_examples "blocks", "deep/nested/dir/.env"
    include_examples "blocks", "some/weird/place/id_rsa"
  end

  describe "with a custom sensitive_patterns list" do
    around do |example|
      original = RailsAiContext.configuration.sensitive_patterns.dup
      RailsAiContext.configuration.sensitive_patterns = %w[forbidden/*.txt]
      example.run
      RailsAiContext.configuration.sensitive_patterns = original
    end

    it "blocks files matching the custom pattern" do
      expect(described_class.send(:sensitive_file?, "forbidden/secret.txt")).to be true
    end

    it "allows .env when only custom patterns are configured" do
      expect(described_class.send(:sensitive_file?, ".env")).to be false
    end
  end
end
