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

    it "refuses a symlink to a directory outside before deciding it is not a file" do
      File.symlink(File.join(@root, "app/views_backup"), File.join(@root, "app/views/posts/escape_dir"))

      expect(locate("posts/escape_dir").refusal).to eq(:outside)
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

    it "treats the filesystem root as containing every path under it" do
      expect(described_class.contained?(views, File::SEPARATOR)).to be true
      expect(described_class.contained?(File::SEPARATOR, File::SEPARATOR)).to be true
    end

    it "names a file under a directory outside the root relative to the root, as an engine's view from its test/dummy" do
      dummy = File.join(@root, "test/dummy")
      FileUtils.mkdir_p(dummy)
      result = described_class.locate("posts/index.html.erb", under: views, root: dummy)

      expect(result.relative).to eq("../../app/views/posts/index.html.erb")
    end

    it "names a file relative to a filesystem-root root without a leading separator" do
      result = described_class.locate("posts/index.html.erb", under: views, root: File::SEPARATOR)

      expect(result.relative).to eq(File.join(@root, "app/views/posts/index.html.erb").delete_prefix(File::SEPARATOR))
    end
  end

  describe ".locate with a listed path" do
    it "resolves a plain file and a linked one as realpath does, and refuses a link to a secret" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "real/config"))
        File.write(File.join(dir, "real/config/api.yml"), "openapi: 3.0.0\n")
        File.write(File.join(dir, "real/config/master.key"), "secret")
        File.symlink("real", File.join(dir, "app"))
        File.symlink("api.yml", File.join(dir, "real/config/linked.yml"))
        File.symlink("master.key", File.join(dir, "real/config/key.yml"))

        plain = described_class.locate("app/config/api.yml", under: dir, listed: true)
        linked = described_class.locate("app/config/linked.yml", under: dir, listed: true)
        expect(plain.realpath).to eq(File.realpath(File.join(dir, "real/config/api.yml")))
        expect(linked.realpath).to eq(plain.realpath)
        expect(described_class.locate("app/config/key.yml", under: dir, listed: true).refusal).to eq(:sensitive)
        expect(described_class.locate("app/config/none.yml", under: dir, listed: true).refusal).to eq(:missing)
      end
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

    # Each of these is a secrets file by its own tool's convention, and each
    # is the file that tool tells you to gitignore.
    describe "secret files of the config gems" do
      include_examples "blocks", "config/application.yml"       # figaro
      include_examples "blocks", ".envrc"                       # direnv
      include_examples "blocks", "config/settings.local.yml"    # config gem
      include_examples "blocks", "config/settings/production.local.yml"
      include_examples "blocks", "config/secrets.yml.enc"       # Rails 5.1
      include_examples "blocks", "config/secrets.production.yml"
      include_examples "blocks", "certs/apns.p8"                # Apple auth key
      include_examples "blocks", "docker/secrets.env"           # compose env_file
      include_examples "allows", "features/support/env.rb"
      # The placeholder beside a secrets file exists to be read.
      include_examples "allows", "config/application.example.yml"
      include_examples "allows", ".env.example"
      include_examples "allows", ".env.sample"
      include_examples "allows", "docker/.env.template"
      include_examples "allows", ".env.production.dist"
      include_examples "blocks", ".env.example.local"
      # A path pattern means the whole directory, placeholders included.
      include_examples "blocks", ".ssh/id_rsa.template"
      include_examples "blocks", ".ssh/config.dist"
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

      it "blocks a placeholder a pattern names exactly or a path pattern covers, not one a basename glob matches" do
        RailsAiContext.configuration.sensitive_patterns = %w[.env.example .env.* forbidden/*]
        expect(described_class.sensitive?(".env.example")).to be true
        expect(described_class.sensitive?("forbidden/keys.sample")).to be true
        expect(described_class.sensitive?(".env.sample")).to be false
      end

      it "reads a brace in a pattern as a literal character, as the match does" do
        RailsAiContext.configuration.sensitive_patterns = %w[{app}.env.example]
        expect(described_class.sensitive?("{app}.env.example")).to be true
      end

      it "allows .env when only custom patterns are configured" do
        expect(described_class.sensitive?(".env")).to be false
      end
    end
  end

  describe ".git_root" do
    it "finds the nearest .git above a directory, a worktree's .git file included, and nil outside one" do
      Dir.mktmpdir do |dir|
        nested = File.join(dir, "repo", "test", "dummy")
        FileUtils.mkdir_p(nested)
        expect(described_class.git_root(nested)).to be_nil

        File.write(File.join(dir, "repo", ".git"), "gitdir: /elsewhere\n")
        expect(described_class.git_root(nested)).to eq(File.join(dir, "repo"))
      end
    end
  end

  describe ".canonical" do
    it "spells a place one way whatever links lead to it, there yet or not" do
      Dir.mktmpdir do |dir|
        real = File.realpath(dir)
        FileUtils.mkdir_p(File.join(real, "target/app"))
        File.symlink(File.join(real, "target"), File.join(real, "link"))

        expect(described_class.canonical(File.join(dir, "link/app"))).to eq(File.join(real, "target/app"))
        expect(described_class.canonical(File.join(dir, "link/app/not/yet"))).to eq(File.join(real, "target/app/not/yet"))
        expect(described_class.canonical(File.join(dir, "link/../link/app"))).to eq(File.join(real, "target/app"))
      end
    end

    # Dir.children hands a Latin-1 name back as a broken UTF-8 string and
    # realpath answers it as bytes. Joining those raised, on every Ruby for a
    # UTF-8 name below, and on 3.1 for any path, whose delete_prefix left a
    # broken string whole.
    it "spells a place under a folder whose name is not UTF-8, there yet or not" do
      Dir.mktmpdir do |dir|
        latin = File.join(File.realpath(dir).b, "caf\xE9".b)
        Dir.mkdir(latin)
        broken = latin.dup.force_encoding(Encoding::UTF_8)

        expect(described_class.canonical(broken).b).to eq(latin)
        expect(described_class.canonical(File.join(broken, "app")).b).to eq(File.join(latin, "app"))
        expect(described_class.canonical(File.join(broken, "\u0448\u043e\u043f")).b).to eq(File.join(latin, "\u0448\u043e\u043f".b))
      end
    end
  end
end
