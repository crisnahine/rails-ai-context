# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::GitIgnore do
  describe ".ignored?" do
    let(:rules) { described_class.parse("tmp/\n*.log\n!keep.log\nsecrets/\n") }

    it "ignores a file under an ignored directory" do
      expect(described_class.ignored?(rules, "a/b/secrets/c/d.rb")).to be true
    end

    it "does not re-include a file whose parent directory is ignored" do
      expect(described_class.ignored?(rules, "tmp/keep.log")).to be true
    end

    it "re-includes a file a later negation names" do
      expect(described_class.ignored?(rules, "app/keep.log")).to be false
      expect(described_class.ignored?(rules, "app/other.log")).to be true
    end

    # Each ancestor asked its own ancestors again, so the work doubled per
    # level: a private API app's 31 rules took 2.5 ms a path at depth 8, and
    # the Ruby search fallback over the app went from 1 s to 3.3 s.
    it "evaluates each rule a bounded number of times per path segment" do
      many = described_class.parse((1..31).map { |i| "pattern_#{i}\n" }.join)
      path = (1..8).map { |i| "dir#{i}" }.join("/") + "/file.rb"
      calls = 0
      allow(described_class).to receive(:matches?).and_wrap_original do |original, *args, **kwargs|
        calls += 1
        original.call(*args, **kwargs)
      end

      described_class.ignored?(many, path)

      expect(calls).to be <= 31 * 9
    end
  end

  # ripgrep reads every ignore source git does, not only the root .gitignore:
  # a file hidden by `config/.gitignore`, by `.git/info/exclude` or by the
  # global excludes file was searched by the fallback and skipped by ripgrep.
  describe ".for_tree" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, ".git", "info"))
        # A home of our own, so the developer's real git config never leaks in.
        @home = File.join(dir, "..", "#{File.basename(dir)}-home")
        FileUtils.mkdir_p(@home)
        @global = File.join(@home, ".gitconfig")
        File.write(@global, "")
        keys = %w[HOME GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM XDG_CONFIG_HOME]
        previous = ENV.to_h.slice(*keys)
        ENV["HOME"] = @home
        ENV["GIT_CONFIG_GLOBAL"] = @global
        ENV["GIT_CONFIG_NOSYSTEM"] = "1"
        ENV["XDG_CONFIG_HOME"] = File.join(dir, "no-xdg")
        example.run
      ensure
        keys.each { |k| ENV[k] = previous[k] }
        FileUtils.rm_rf(@home)
      end
    end

    def ignored?(path)
      described_class.for_tree(@root).ignored?(path)
    end

    it "scopes a nested .gitignore to its own directory" do
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "config", ".gitignore"), "local_settings.rb\n")

      expect(ignored?("config/local_settings.rb")).to be true
      expect(ignored?("local_settings.rb")).to be false
    end

    it "scopes a .gitignore in a hidden directory to that directory" do
      FileUtils.mkdir_p(File.join(@root, ".config"))
      File.write(File.join(@root, ".config", ".gitignore"), "local.rb\n")

      expect(ignored?(".config/local.rb")).to be true
      expect(ignored?("config/local.rb")).to be false
    end

    it "anchors a nested pattern to the directory that holds it" do
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "config", ".gitignore"), "/generated/\n")

      expect(ignored?("config/generated/x.rb")).to be true
      expect(ignored?("generated/x.rb")).to be false
    end

    it "lets a deeper .gitignore re-include what a shallower one ignored" do
      File.write(File.join(@root, ".gitignore"), "*.local.rb\n")
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "config", ".gitignore"), "!keep.local.rb\n")

      expect(ignored?("config/keep.local.rb")).to be false
      expect(ignored?("config/other.local.rb")).to be true
    end

    it "reads .git/info/exclude" do
      File.write(File.join(@root, ".git", "info", "exclude"), "scratch/\n")

      expect(ignored?("scratch/notes.rb")).to be true
    end

    it "reads the global excludes file core.excludesFile names" do
      excludes = File.join(@root, "global-ignore")
      File.write(excludes, "*.swp.rb\n")
      File.write(@global, "[core]\n\texcludesFile = #{excludes}\n")

      expect(ignored?("app/a.swp.rb")).to be true
    end

    it "reads core.excludesFile from the XDG git config" do
      excludes = File.join(@root, "xdg-ignore")
      File.write(excludes, "*.xdg.rb\n")
      FileUtils.mkdir_p(File.join(@root, "no-xdg", "git"))
      File.write(File.join(@root, "no-xdg", "git", "config"), "[core]\n\texcludesFile = #{excludes}\n")

      expect(ignored?("app/a.xdg.rb")).to be true
    end

    # ripgrep 15 reads core.excludesFile from ~/.gitconfig and the XDG git
    # config only, so the fallback must not see the repository's own setting.
    it "does not read core.excludesFile from the repository's own config" do
      excludes = File.join(@root, "repo-ignore")
      File.write(excludes, "repo_only.rb\n")
      FileUtils.mkdir_p(File.join(@root, ".git", "objects"))
      FileUtils.mkdir_p(File.join(@root, ".git", "refs"))
      File.write(File.join(@root, ".git", "HEAD"), "ref: refs/heads/main\n")
      File.write(File.join(@root, ".git", "config"), "[core]\n\texcludesFile = #{excludes}\n")

      expect(ignored?("repo_only.rb")).to be false
    end

    it "does not read core.excludesFile from GIT_CONFIG_GLOBAL" do
      excludes = File.join(@root, "env-ignore")
      File.write(excludes, "env_only.rb\n")
      env_config = File.join(@root, "env-gitconfig")
      File.write(env_config, "[core]\n\texcludesFile = #{excludes}\n")
      ENV["GIT_CONFIG_GLOBAL"] = env_config

      expect(ignored?("env_only.rb")).to be false
    end

    it "reads the default global excludes file when none is configured" do
      FileUtils.mkdir_p(File.join(@root, "no-xdg", "git"))
      File.write(File.join(@root, "no-xdg", "git", "ignore"), "*.orig.rb\n")

      expect(ignored?("app/a.orig.rb")).to be true
    end

    # ripgrep's own ignore files: `.ignore`, and `.rgignore` above it, beat a
    # `.gitignore` in the same directory and apply outside a git repository.
    it "lets .ignore re-include what .gitignore in the same directory ignored" do
      File.write(File.join(@root, ".gitignore"), "*.gen.rb\n")
      File.write(File.join(@root, ".ignore"), "!keep.gen.rb\n")

      expect(ignored?("keep.gen.rb")).to be false
      expect(ignored?("other.gen.rb")).to be true
    end

    it "lets .rgignore override .ignore in the same directory" do
      File.write(File.join(@root, ".ignore"), "*.gen.rb\n")
      File.write(File.join(@root, ".rgignore"), "!keep.gen.rb\n")

      expect(ignored?("keep.gen.rb")).to be false
      expect(ignored?("other.gen.rb")).to be true
    end

    it "scopes a nested .ignore to its own directory" do
      FileUtils.mkdir_p(File.join(@root, "lib"))
      File.write(File.join(@root, "lib", ".ignore"), "vendored.rb\n")

      expect(ignored?("lib/vendored.rb")).to be true
      expect(ignored?("vendored.rb")).to be false
    end

    it "reads .ignore and .rgignore outside a git repository, and .gitignore not" do
      FileUtils.rm_rf(File.join(@root, ".git"))
      File.write(File.join(@root, ".gitignore"), "a.rb\n")
      File.write(File.join(@root, ".ignore"), "b.rb\n")
      File.write(File.join(@root, ".rgignore"), "c.rb\n")

      expect(ignored?("a.rb")).to be false
      expect(ignored?("b.rb")).to be true
      expect(ignored?("c.rb")).to be true
    end

    it "reads no .gitignore outside a git repository" do
      FileUtils.rm_rf(File.join(@root, ".git"))
      File.write(File.join(@root, ".gitignore"), "*.rb\n")

      expect(ignored?("x.rb")).to be false
    end
  end

  # The fallback took 19.5 s on a private API app: every file asked every
  # ancestor again, and the whole tree was walked for ignore files before the
  # search.
  describe "the walk" do
    it "never lists an ignored directory and reads each ignore file once" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        FileUtils.mkdir_p(File.join(root, "a", "b"))
        FileUtils.mkdir_p(File.join(root, "skipped", "deep"))
        File.write(File.join(root, ".ignore"), "skipped/\n")
        File.write(File.join(root, "a", ".ignore"), "*.tmp\n")
        %w[a/one.rb a/b/two.rb a/b/three.tmp skipped/deep/four.rb].each { |f| File.write(File.join(root, f), "x\n") }
        listed = []
        allow(Dir).to receive(:children).and_wrap_original { |original, path| listed << path; original.call(path) }
        reads = Hash.new(0)
        allow(RailsAiContext::SafeFile).to receive(:read).and_wrap_original { |original, path, **kw| reads[path] += 1; original.call(path, **kw) }

        files = []
        described_class.for_tree(root).each_file { |_path, relative| files << relative }

        expect(files).to eq(%w[a/b/two.rb a/one.rb])
        expect(listed).not_to include(File.join(root, "skipped"))
        expect(reads.select { |path, _| path.end_with?(".ignore") }.values).to all(eq(1))
      end
    end
  end
end
