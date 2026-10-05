# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

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

  it "does not read a commented-out gem line as a gem" do
    File.write(File.join(@root, "Gemfile"), "gem \"rails\"\n# gem \"stripe\"\n")

    expect(described_class.names(@root)).to eq(%w[rails])
  end

  it "answers nothing with no Gemfile" do
    expect(described_class.names(@root)).to eq([])
    expect(described_class.entries(@root)).to eq([])
  end
end
