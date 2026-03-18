# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::GemIntrospector do
  let(:fixture_path) { File.expand_path("../../fixtures", __FILE__) }
  let(:app) { double("app", root: Pathname.new(fixture_path)) }
  let(:introspector) { described_class.new(app) }

  describe "#call" do
    before do
      FileUtils.mkdir_p(fixture_path)
      File.write(File.join(fixture_path, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            devise (4.9.3)
            pg (1.5.4)
            sidekiq (7.2.0)
            turbo-rails (2.0.4)
            rspec-rails (6.1.0)
            rails (7.1.3)

        PLATFORMS
          ruby

        DEPENDENCIES
          devise
          pg
          sidekiq
      LOCK
    end

    after do
      FileUtils.rm_f(File.join(fixture_path, "Gemfile.lock"))
    end

    it "counts total gems" do
      result = introspector.call
      expect(result[:total_gems]).to eq(6)
    end

    it "detects notable gems" do
      result = introspector.call
      names = result[:notable_gems].map { |g| g[:name] }
      expect(names).to include("devise", "pg", "sidekiq", "turbo-rails", "rspec-rails")
    end

    it "categorizes gems correctly" do
      result = introspector.call
      expect(result[:categories]["auth"]).to include("devise")
      expect(result[:categories]["database"]).to include("pg")
      expect(result[:categories]["jobs"]).to include("sidekiq")
    end

    it "includes version info" do
      result = introspector.call
      devise = result[:notable_gems].find { |g| g[:name] == "devise" }
      expect(devise[:version]).to eq("4.9.3")
    end
  end

  context "when Gemfile.lock is missing" do
    let(:app) { double("app", root: Pathname.new("/nonexistent")) }

    it "returns an error" do
      result = introspector.call
      expect(result[:error]).to include("No Gemfile.lock")
    end
  end
end
