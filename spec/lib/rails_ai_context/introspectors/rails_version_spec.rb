# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::RailsVersion do
  describe ".at_least?" do
    it "compares releases and takes the newest rules when the version is unknown" do
      expect(described_class.at_least?("7.2.2", "7.2.2")).to be(true)
      expect(described_class.at_least?("7.10.0", "7.2")).to be(true)
      expect(described_class.at_least?("8.0.0.rc1", "8.0")).to be(false)
      expect(described_class.at_least?(nil, "8.1")).to be(true)
    end
  end

  describe ".of" do
    def root_locking(rails)
      dir = Dir.mktmpdir
      File.write(File.join(dir, "Gemfile"), "gem \"rails\"\n")
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (#{rails})\n\nDEPENDENCIES\n  rails\n")
      dir
    end

    it "reads the lockfile without a boot" do
      RailsAiContext.tier = :static
      dir = root_locking("7.2.4")
      expect(described_class.of(dir)).to eq("7.2.4")
    ensure
      RailsAiContext.tier = nil
      FileUtils.rm_rf(dir) if dir
    end

    it "reads the running Rails when booted" do
      dir = root_locking("7.2.4")
      expect(described_class.of(dir)).to eq(Rails.version)
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
