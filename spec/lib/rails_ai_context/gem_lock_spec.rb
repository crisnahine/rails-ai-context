# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

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

  it "answers no gems for a file with no specs section" do
    File.write(File.join(@root, "Gemfile.lock"), "not a lockfile\n  GEM\n specs")
    File.utime(Time.now + 2, Time.now + 2, File.join(@root, "Gemfile.lock"))
    expect(described_class.for(@root).present?("rails")).to be false
    expect(described_class.for(@root).missing?).to be false
  end
end
