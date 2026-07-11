# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::AppKind do
  it "detects Mongoid via config/mongoid.yml" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
      expect(described_class.mongoid?(dir)).to be(true)
    end
  end

  it "detects Mongoid via Gemfile.lock" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    mongoid (9.0.4)\n")
      expect(described_class.mongoid?(dir)).to be(true)
    end
  end

  it "is false for an ActiveRecord app" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    pg (1.5.6)\n")
      expect(described_class.mongoid?(dir)).to be(false)
    end
  end

  it "does not match gems whose name merely contains mongoid" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    mongoid_paranoia (1.0.0)\n")
      expect(described_class.mongoid?(dir)).to be(false)
    end
  end
end
