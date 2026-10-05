# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::GemLock do
  let(:lock_text) do
    <<~LOCK
    GIT
      remote: https://github.com/heartcombo/devise.git
      revision: 0123456789abcdef0123456789abcdef01234567
      specs:
        devise (4.9.4)
          railties (>= 4.1.0)

    PATH
      remote: engines/billing
      specs:
        billing (0.1.0)

    GEM
      remote: https://rubygems.org/
      specs:
        bugsnag-capistrano (2.1.0)
        database_cleaner-active_record (2.2.0)
          database_cleaner-core (~> 2.0.0)
        database_cleaner-core (2.0.1)
        nokogiri (1.16.5-arm64-darwin)
          racc (~> 1.4)
        nokogiri (1.16.5-x86_64-linux)
          racc (~> 1.4)
        racc (1.8.0)
        rails (7.2.2)

    PLATFORMS
      arm64-darwin
      x86_64-linux

    DEPENDENCIES
      billing!
      devise!
      nokogiri
      rails (~> 7.2.0)

    RUBY VERSION
       ruby 3.3.4p94

    BUNDLED WITH
       2.5.11
  LOCK
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      File.write(File.join(dir, "Gemfile.lock"), lock_text)
      example.run
    end
  end

  subject(:lock) { described_class.for(@root) }

  it "sees gems from the GIT and PATH sections, not only GEM" do
    expect(lock.present?("devise")).to be true
    expect(lock.present?("billing")).to be true
    expect(lock.present?("rails")).to be true
  end

  it "names each PATH section's remote, as the one lockfile reader" do
    expect(lock.path_remotes).to eq([ "engines/billing" ])
  end

  it "names a PATH remote in a lockfile with CRLF line ends" do
    File.write(File.join(@root, "Gemfile.lock"), lock_text.gsub("\n", "\r\n"))

    expect(described_class.for(@root).path_remotes).to eq([ "engines/billing" ])
  end

  it "matches a name exactly, so a longer gem name is not its prefix" do
    expect(lock.present?("bugsnag")).to be false
    expect(lock.present?("database_cleaner")).to be false
    expect(lock.present?("database_cleaner-active_record")).to be true
  end

  it "answers the version without the platform suffix" do
    expect(lock.version("nokogiri")).to eq("1.16.5")
    expect(lock.version("rails")).to eq("7.2.2")
    expect(lock.version("nope")).to be_nil
  end

  it "answers any? over several names" do
    expect(lock.any?("pagy", "kaminari", "rails")).to be true
    expect(lock.any?("pagy", "kaminari")).to be false
  end

  it "lists every name once, sorted" do
    expect(lock.names).to eq(%w[billing bugsnag-capistrano database_cleaner-active_record database_cleaner-core devise nokogiri racc rails])
  end

  it "reads the ruby version" do
    expect(lock.ruby_version).to eq("3.3.4p94")
  end

  it "distinguishes no lockfile from a lockfile that says no" do
    Dir.mktmpdir do |bare|
      expect(described_class.for(bare).missing?).to be true
      expect(described_class.for(bare).present?("rails")).to be false
    end
    expect(lock.missing?).to be false
  end

  it "rereads when the lockfile changes and not before" do
    first = described_class.for(@root)
    expect(described_class.for(@root)).to equal(first)

    path = File.join(@root, "Gemfile.lock")
    File.write(path, lock_text.sub("rails (7.2.2)", "rails (8.0.1)"))
    File.utime(Time.now + 2, Time.now + 2, path)

    expect(described_class.for(@root).version("rails")).to eq("8.0.1")
  end

  it "reads the ruby version whatever the section is indented by" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rails (8.0.0)

        RUBY VERSION
          ruby 4.0.6

        BUNDLED WITH
          2.7.2
      LOCK
      expect(described_class.for(dir).ruby_version).to eq("4.0.6")
    end
  end

  # A gem depending on a gem named ruby writes "      ruby (>= 2.0)" under
  # specs:, six spaces in, which the spec-line grammar does not catch.
  it "does not read a dependency on a gem named ruby as the ruby version" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            some_gem (1.0.0)
              ruby (>= 2.0)
      LOCK

      expect(described_class.for(dir).ruby_version).to be_nil
    end
  end

  it "falls back to the Gemfile's ruby line when the lockfile names no version" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.0.0)\n")
      File.write(File.join(dir, "Gemfile"), "source \"https://rubygems.org\"\n\nruby \"3.3.4\"\n")

      expect(described_class.for(dir).ruby_version).to eq("3.3.4")
    end
  end

  it "does not read a Gemfile ruby requirement as a version" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.0.0)\n")
      File.write(File.join(dir, "Gemfile"), "ruby '>= 3.3.0', '< 4.1.0'\n")

      expect(described_class.for(dir).ruby_version).to be_nil
    end
  end

  it "reads .ruby-version when neither the lockfile nor the Gemfile names one" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.0.0)\n")
      File.write(File.join(dir, ".ruby-version"), "3.3.6\n")

      spec = described_class.for(dir)

      expect(spec.ruby_version).to eq("3.3.6")
      expect(spec.ruby_version_source).to eq(".ruby-version")
    end
  end

  it "reads the ruby line of .tool-versions last" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.0.0)\n")
      File.write(File.join(dir, ".tool-versions"), "nodejs 20.11.0\nruby 3.2.2\n")

      expect(described_class.for(dir).ruby_version).to eq("3.2.2")
      expect(described_class.for(dir).ruby_version_source).to eq(".tool-versions")
    end
  end

  it "prefers the lockfile over the version-manager files and says so when they disagree" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rails (8.0.0)

        RUBY VERSION
          ruby 3.4.1
      LOCK
      File.write(File.join(dir, ".ruby-version"), "ruby-3.3.6\n")

      spec = described_class.for(dir)

      expect(spec.ruby_version).to eq("3.4.1")
      expect(spec.ruby_version_source).to eq("Gemfile.lock")
      expect(spec.ruby_versions).to eq("Gemfile.lock" => "3.4.1", ".ruby-version" => "3.3.6")
    end
  end

  it "reads .ruby-version with no lockfile at all" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".ruby-version"), "3.1.4\n")

      expect(described_class.for(dir).ruby_version).to eq("3.1.4")
    end
  end

  # This used to answer like an app with no gems, so a truncated or corrupt
  # lockfile made every gem-dependent answer say the app does not use the gem.
  it "does not answer a file with no gem entries as an app with no gems" do
    File.write(File.join(@root, "Gemfile.lock"), "not a lockfile\n  GEM\n specs")
    File.utime(Time.now + 2, Time.now + 2, File.join(@root, "Gemfile.lock"))
    expect(described_class.for(@root).missing?).to be true
    expect(described_class.for(@root).reason).to eq("Gemfile.lock has no specs section")
    expect(described_class.for(@root).present?("rails")).to be false
  end

  it "names which of the two ways it could not answer" do
    Dir.mktmpdir do |bare|
      expect(described_class.for(bare).reason).to eq("No Gemfile.lock found")
    end
    expect(lock.reason).to be_nil
  end

  # Which gems resolved and which Ruby the app declares are two facts, and the
  # Gemfile answers the second whether or not a lockfile answers the first.
  it "reads the Gemfile's ruby line when there is no lockfile at all" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), "source \"https://rubygems.org\"\n\nruby \"3.2.4\"\n")

      spec = described_class.for(dir)

      expect(spec.ruby_version).to eq("3.2.4")
      expect(spec.absent?).to be true
      expect(spec.reason).to eq("No Gemfile.lock found")
      expect(spec.present?("rails")).to be false
    end
  end

  it "reads gems.locked beside gems.rb, the pair Bundler uses before Gemfile" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "gems.rb"), "source \"https://rubygems.org\"\nruby \"3.4.9\"\ngem \"devise\"\n")
      File.write(File.join(dir, "gems.locked"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            devise (4.9.4)
            rails (8.1.4)

        DEPENDENCIES
          devise
      LOCK

      spec = described_class.for(dir)

      expect(spec).not_to be_absent
      expect(spec.version("rails")).to eq("8.1.4")
      expect(spec.ruby_versions).to eq("gems.rb" => "3.4.9")
      expect(described_class.lockfile_name(dir)).to eq("gems.locked")
    end
  end
  describe "mise config" do
    it "reads the ruby tool of mise.toml when nothing else names a version" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "mise.toml"), "[env]\nruby = \"no\"\n\n[tools]\nnode = \"22\"\nruby = \"3.3.6\"\n")

        spec = described_class.for(dir)

        expect(spec.ruby_version).to eq("3.3.6")
        expect(spec.ruby_version_source).to eq("mise.toml")
      end
    end

    it "reads the other names mise looks for, the array and table forms, and mise.local.toml first" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".config"))
        File.write(File.join(dir, ".config/mise.toml"), "[tools]\nruby = { version = \"3.2.5\" }\n")
        expect(described_class.for(dir).ruby_versions).to eq(".config/mise.toml" => "3.2.5")

        File.write(File.join(dir, "mise.local.toml"), "[tools]\nruby = [\"3.4.9\", \"3.3.6\"]\n")
        expect(described_class.for(dir).ruby_version).to eq("3.4.9")
      end
    end

    it "does not follow a mise directory symlinked out of the app" do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "config.toml"), "[tools]\nruby = \"3.3.6\"\n")
        Dir.mktmpdir do |dir|
          File.symlink(outside, File.join(dir, "mise"))
          expect(described_class.for(dir).ruby_versions).to eq({})
        end
      end
    end

    it "reads nothing from a mise.toml with no ruby tool or an unreadable one" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "mise.toml"), "[tools]\nruby = \"latest\"\n")
        expect(described_class.for(dir).ruby_versions).to eq({})
        File.binwrite(File.join(dir, "mise.toml"), "\xFF\xFE[tools]\nruby = \"\xFF\"\n".b)
        File.utime(Time.now + 2, Time.now + 2, File.join(dir, "mise.toml"))
        expect(described_class.for(dir).ruby_versions).to eq({})
      end
    end
  end

  describe "the Ruby engine" do
    it "reads an engine-prefixed .ruby-version as that engine, with no Ruby version" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".ruby-version"), "jruby-9.4.8.0\n")

        spec = described_class.for(dir)

        expect(spec.ruby_engine).to eq("JRuby 9.4.8.0")
        expect(spec.ruby_version).to be_nil
      end
    end

    it "reads the engine Bundler writes into RUBY VERSION" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              rails (8.1.4)

          RUBY VERSION
             ruby 3.1.4p0 (jruby 9.4.8.0)
        LOCK

        spec = described_class.for(dir)

        expect(spec.ruby_version).to eq("3.1.4p0")
        expect(spec.ruby_engine).to eq("JRuby 9.4.8.0")
      end
    end

    it "reads engine: and engine_version: on the Gemfile's ruby line" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile"), %(ruby "3.1.4", engine: "jruby", engine_version: "9.4.8.0"\ngem "rails"\n))

        spec = described_class.for(dir)

        expect(spec.ruby_version).to eq("3.1.4")
        expect(spec.ruby_engine).to eq("JRuby 9.4.8.0")
      end
    end

    it "reads an engine in .tool-versions" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".tool-versions"), "ruby truffleruby-24.1.1\n")

        expect(described_class.for(dir).ruby_engine).to eq("TruffleRuby 24.1.1")
      end
    end

    it "names no engine for CRuby, however the version is written" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".ruby-version"), "ruby-3.4.9\n")

        spec = described_class.for(dir)

        expect(spec.ruby_engine).to be_nil
        expect(spec.ruby_version).to eq("3.4.9")
      end
    end

    it "takes the engine from the file that decides the version" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.1.4)\n\nRUBY VERSION\n   ruby 3.4.9p82\n")
        File.write(File.join(dir, ".ruby-version"), "jruby-9.4.8.0\n")

        expect(described_class.for(dir).ruby_engine).to be_nil
      end
    end
  end
end
