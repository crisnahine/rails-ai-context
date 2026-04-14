# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::GemIntrospector do
  let(:tmpdir) { Dir.mktmpdir }
  let(:app) { double("app", root: tmpdir) }
  let(:introspector) { described_class.new(app) }

  after { FileUtils.remove_entry(tmpdir) }

  describe "#call" do
    it "returns error when Gemfile.lock is missing" do
      result = introspector.call
      expect(result).to eq({ error: "No Gemfile.lock found" })
    end

    context "with a Gemfile.lock" do
      let(:lockfile_content) do
        <<~LOCK
          GEM
            remote: https://rubygems.org/
            specs:
              devise (4.9.4)
              pundit (2.4.0)
              sidekiq (7.3.0)
              turbo-rails (2.0.11)
              pg (1.5.9)
              rspec-rails (7.1.0)
              pagy (9.3.3)
              nokogiri (1.16.7)
              rails (8.0.0)
              actionpack (8.0.0)

          PLATFORMS
            ruby

          DEPENDENCIES
            rails (~> 8.0)
        LOCK
      end

      before do
        File.write(File.join(tmpdir, "Gemfile.lock"), lockfile_content)
      end

      it "returns total gem count" do
        result = introspector.call
        expect(result[:total_gems]).to eq(10)
      end

      it "detects notable gems" do
        result = introspector.call
        names = result[:notable_gems].map { |g| g[:name] }
        expect(names).to include("devise", "pundit", "sidekiq", "turbo-rails", "pg", "rspec-rails", "pagy", "nokogiri")
      end

      it "includes version for notable gems" do
        result = introspector.call
        devise = result[:notable_gems].find { |g| g[:name] == "devise" }
        expect(devise[:version]).to eq("4.9.4")
      end

      it "categorizes gems correctly" do
        result = introspector.call
        categories = result[:categories]
        expect(categories["auth"]).to include("devise", "pundit")
        expect(categories["jobs"]).to include("sidekiq")
        expect(categories["frontend"]).to include("turbo-rails")
        expect(categories["database"]).to include("pg")
        expect(categories["testing"]).to include("rspec-rails")
        expect(categories["pagination"]).to include("pagy")
      end

      it "includes category and note for each notable gem" do
        result = introspector.call
        devise = result[:notable_gems].find { |g| g[:name] == "devise" }
        expect(devise[:category]).to eq("auth")
        expect(devise[:note]).to include("Devise")
      end

      it "does not include non-notable gems in notable_gems" do
        result = introspector.call
        names = result[:notable_gems].map { |g| g[:name] }
        expect(names).not_to include("rails", "actionpack")
      end
    end

    context "with minimal Gemfile.lock" do
      before do
        content = <<~LOCK
          GEM
            remote: https://rubygems.org/
            specs:
              rails (8.0.0)
              puma (6.5.0)

          PLATFORMS
            ruby
        LOCK
        File.write(File.join(tmpdir, "Gemfile.lock"), content)
      end

      it "detects puma as a notable gem" do
        result = introspector.call
        names = result[:notable_gems].map { |g| g[:name] }
        expect(names).to include("puma")
      end

      it "returns server category for puma" do
        result = introspector.call
        expect(result[:categories]).to have_key("server")
        expect(result[:categories]["server"]).to include("puma")
      end

      it "returns correct total count" do
        result = introspector.call
        expect(result[:total_gems]).to eq(2)
      end
    end

    context "with empty GEM section" do
      before do
        content = <<~LOCK
          GEM
            remote: https://rubygems.org/
            specs:

          PLATFORMS
            ruby
        LOCK
        File.write(File.join(tmpdir, "Gemfile.lock"), content)
      end

      it "returns zero gems" do
        result = introspector.call
        expect(result[:total_gems]).to eq(0)
        expect(result[:notable_gems]).to eq([])
        expect(result[:categories]).to eq({})
      end
    end
  end

  describe "NOTABLE_GEMS" do
    it "covers all expected categories" do
      categories = described_class::NOTABLE_GEMS.values.map { |v| v[:category] }.uniq
      expect(categories).to include(:auth, :jobs, :frontend, :api, :database, :testing, :deploy, :monitoring, :admin, :pagination, :search, :forms, :server)
    end

    it "has a note for every gem" do
      described_class::NOTABLE_GEMS.each do |gem_name, info|
        expect(info[:note]).to be_a(String), "Missing note for #{gem_name}"
        expect(info[:note]).not_to be_empty, "Empty note for #{gem_name}"
      end
    end

    it "includes solid_errors under monitoring" do
      entry = described_class::NOTABLE_GEMS["solid_errors"]
      expect(entry).not_to be_nil
      expect(entry[:category]).to eq(:monitoring)
    end
  end
end
