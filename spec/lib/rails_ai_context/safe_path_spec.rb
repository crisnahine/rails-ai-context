# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::SafePath do
  around do |example|
    Dir.mktmpdir("safe-path") do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@root, "app/views/posts"))
      FileUtils.mkdir_p(File.join(@root, "app/views_backup"))
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "app/views/posts/index.html.erb"), "<h1>Posts</h1>\n")
      File.write(File.join(@root, "app/views_backup/secret.html.erb"), "leak\n")
      File.write(File.join(@root, "config/master.key"), "0123456789abcdef\n")
      File.write(File.join(@root, "app/views/leak.key"), "0123456789abcdef\n")
      File.symlink(File.join(@root, "app/views_backup/secret.html.erb"), File.join(@root, "app/views/posts/escape.html.erb"))
      File.symlink(File.join(@root, "app/views/leak.key"), File.join(@root, "app/views/posts/benign.html.erb"))
      example.run
    end
  end

  let(:views) { File.join(@root, "app/views") }

  def locate(path, **opts)
    described_class.locate(path, under: views, root: @root, **opts)
  end

  describe ".locate" do
    it "answers the realpath and the root-relative path for a file under the directory" do
      result = locate("posts/index.html.erb")

      expect(result.refusal).to be_nil
      expect(result.realpath).to eq(File.join(@root, "app/views/posts/index.html.erb"))
      expect(result.relative).to eq("app/views/posts/index.html.erb")
    end

    # The refusals below are ordered the way the checks run. A test per step
    # is what pins the order: swapping two of them leaves every happy path
    # green and reopens the oracle.
    it "refuses traversal on the caller string before any stat" do
      expect(locate("../config/master.key").refusal).to eq(:traversal)
      expect(locate("/etc/passwd").refusal).to eq(:traversal)
      expect(locate("posts/\0index").refusal).to eq(:traversal)
    end

    it "refuses a sensitive name on the caller string whether or not the file exists" do
      expect(locate("master.key").refusal).to eq(:sensitive)
      expect(locate("posts/.env").refusal).to eq(:sensitive)
      expect(locate("leak.key").refusal).to eq(:sensitive)
    end

    it "answers missing for a file that is not there" do
      expect(locate("posts/nope.html.erb").refusal).to eq(:missing)
    end

    it "answers missing for a directory" do
      expect(locate("posts").refusal).to eq(:missing)
    end

    it "refuses a symlink that resolves outside the directory, including a sibling that shares the prefix" do
      expect(locate("posts/escape.html.erb").refusal).to eq(:outside)
    end

    it "refuses a benign name whose realpath is a sensitive file" do
      expect(locate("posts/benign.html.erb").refusal).to eq(:sensitive)
    end

    it "refuses a file over the size cap and still names the file" do
      result = locate("posts/index.html.erb", max_size: 3)

      expect(result.refusal).to eq(:too_large)
      expect(result.realpath).to eq(File.join(@root, "app/views/posts/index.html.erb"))
    end

    it "treats the directory itself as contained" do
      expect(described_class.contained?(views, views)).to be true
      expect(described_class.contained?(File.join(@root, "app/views_backup"), views)).to be false
    end
  end

  describe ".read" do
    it "returns the content with the resolution for a readable file" do
      content, result = described_class.read("posts/index.html.erb", under: views, root: @root)

      expect(content).to eq("<h1>Posts</h1>\n")
      expect(result.refusal).to be_nil
    end

    it "reads a file over the configured cap when the caller raises the cap" do
      allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(3)

      content, result = described_class.read("posts/index.html.erb", under: views, root: @root, max_size: 1_000)

      expect(result.refusal).to be_nil
      expect(content).to eq("<h1>Posts</h1>\n")
    end

    it "returns nil content with the refusal when the file is refused" do
      content, result = described_class.read("posts/benign.html.erb", under: views, root: @root)

      expect(content).to be_nil
      expect(result.refusal).to eq(:sensitive)
    end
  end

  describe ".sensitive?" do
    it "matches the configured patterns on the whole path and on the basename, case-insensitively" do
      expect(described_class.sensitive?("config/master.key")).to be true
      expect(described_class.sensitive?("CONFIG/MASTER.KEY")).to be true
      expect(described_class.sensitive?("app/models/user.rb")).to be false
    end

    shared_examples "blocks" do |path|
      it "blocks #{path}" do
        expect(described_class.sensitive?(path)).to be true
      end
    end

    shared_examples "allows" do |path|
      it "allows #{path}" do
        expect(described_class.sensitive?(path)).to be false
      end
    end

    describe "Rails secret files" do
      include_examples "blocks", ".env"
      include_examples "blocks", ".env.production"
      include_examples "blocks", ".env.local"
      include_examples "blocks", "config/master.key"
      include_examples "blocks", "config/credentials.yml.enc"
      include_examples "blocks", "config/credentials/production.yml.enc"
    end

    describe "connection and credential files" do
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

    describe "private keys and certificates" do
      include_examples "blocks", "certs/tls.pem"
      include_examples "blocks", "certs/private.key"
      include_examples "blocks", "certs/bundle.p12"
      include_examples "blocks", "certs/keystore.jks"
    end

    describe "common plaintext files" do
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

    describe "case-insensitivity" do
      include_examples "blocks", ".ENV"
      include_examples "blocks", "Config/Master.Key"
    end

    describe "basename-only matching" do
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
        expect(described_class.sensitive?("forbidden/secret.txt")).to be true
      end

      it "allows .env when only custom patterns are configured" do
        expect(described_class.sensitive?(".env")).to be false
      end
    end
  end
end
