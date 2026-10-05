# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::GemfileGems do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  it "names the gems the Gemfile declares, grouped ones included, in order" do
    File.write(File.join(@root, "Gemfile"), <<~RUBY)
      source "https://rubygems.org"
      gem "rails", "~> 8.0"
      group :test do
        gem "rspec-rails"
      end
      gem "rails"
    RUBY

    expect(described_class.names(@root)).to eq(%w[rails rspec-rails])
  end

  it "reads gems.rb, which Bundler looks for before Gemfile" do
    File.write(File.join(@root, "gems.rb"), "source \"https://rubygems.org\"\ngem \"devise\"\n")
    File.write(File.join(@root, "Gemfile"), "gem \"stale\"\n")

    expect(described_class.names(@root)).to eq(%w[devise])
  end

  it "reads the gems a file named by eval_gemfile declares, under the groups around it" do
    FileUtils.mkdir_p(File.join(@root, "gemfiles"))
    File.write(File.join(@root, "Gemfile"), <<~RUBY)
      gem "rails"
      eval_gemfile "Gemfile.local"
      group :test do
        eval_gemfile File.expand_path("gemfiles/test.rb", __dir__)
      end
      eval_gemfile "missing.rb"
      eval_gemfile "../outside.rb"
      eval_gemfile ENV.fetch("EXTRA", "x")
    RUBY
    File.write(File.join(@root, "Gemfile.local"), "gem \"stripe\"\neval_gemfile \"Gemfile\"\n")
    File.write(File.join(@root, "gemfiles/test.rb"), "gem \"rspec-rails\"\neval_gemfile \"nested.rb\"\n")
    File.write(File.join(@root, "gemfiles/nested.rb"), "gem \"faker\"\n")
    File.write(File.join(File.dirname(@root), "outside.rb"), "gem \"leaked\"\n")

    expect(described_class.names(@root)).to eq(%w[rails stripe rspec-rails faker])
    expect(described_class.entries(@root).find { |e| e[:name] == "faker" }[:groups]).to eq([ :test ])
  ensure
    FileUtils.rm_f(File.join(File.dirname(@root), "outside.rb"))
  end

  it "does not read a commented-out gem line as a gem" do
    File.write(File.join(@root, "Gemfile"), "gem \"rails\"\n# gem \"stripe\"\n")

    expect(described_class.names(@root)).to eq(%w[rails])
  end

  it "answers nothing with no Gemfile" do
    expect(described_class.names(@root)).to eq([])
    expect(described_class.entries(@root)).to eq([])
  end

  describe "an engine's test/dummy, whose config/boot.rb points Bundler at the engine's Gemfile" do
    let(:dummy) { File.join(@root, "test", "dummy") }

    before do
      FileUtils.mkdir_p([ File.join(dummy, "config"), File.join(@root, ".git") ])
      File.write(File.join(dummy, "config", "boot.rb"), %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)\n))
      File.write(File.join(@root, "Gemfile"), %(source "https://rubygems.org"\ngemspec\ngem "stripe"\n))
      File.write(File.join(@root, "Gemfile.lock"), "GEM\n  specs:\n    stripe (13.0.0)\n")
    end

    it "names the gems of that Gemfile, the one GemLock reads" do
      expect(described_class.names(dummy)).to eq(%w[stripe])
    end

    it "names none when that Gemfile is outside the app's git repository" do
      FileUtils.rm_rf(File.join(@root, ".git"))

      expect(described_class.names(dummy)).to eq([])
    end
  end
end
