# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::GemIntrospector do
  let(:tmpdir) { Dir.mktmpdir }
  let(:app) { double("app", root: tmpdir) }
  let(:introspector) { described_class.new(app) }

  after { FileUtils.remove_entry(tmpdir) }

  describe "#call" do
    # An absent lockfile is a source the app never wrote, which every other
    # section reports as unavailable; a lockfile it could not read is a
    # failure and stays one.
    it "reports a missing Gemfile.lock as unavailable, not as a failure" do
      result = introspector.call
      expect(result).to eq({ unavailable: "No Gemfile.lock found" })
    end

    it "says why rather than reporting no gems when the lockfile has no gem entries" do
      File.write(File.join(tmpdir, "Gemfile.lock"), "not a lockfile\n")

      expect(introspector.call).to eq({ error: "Gemfile.lock has no specs section" })
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

    context "with a gem only in the GIT section" do
      before do
        content = <<~LOCK
          GIT
            remote: https://github.com/heartcombo/devise.git
            revision: 0123456789abcdef0123456789abcdef01234567
            specs:
              devise (4.9.4)
                railties (>= 4.1.0)

          GEM
            remote: https://rubygems.org/
            specs:
              rails (8.0.0)

          RUBY VERSION
             ruby 3.3.4p94

          DEPENDENCIES
            devise!
        LOCK
        File.write(File.join(tmpdir, "Gemfile.lock"), content)
      end

      it "reports the git gem as notable" do
        result = introspector.call
        names = result[:notable_gems].map { |g| g[:name] }
        expect(names).to include("devise")
      end

      # Named for its source: the context's own ruby_version is the Ruby the
      # app runs on, and a reader seeing both needs to know which is which.
      it "reads the ruby version from the RUBY VERSION section" do
        result = introspector.call

        expect(result[:declared_ruby_version]).to eq("3.3.4p94")
        expect(result).not_to have_key(:ruby_version)
      end
    end

    context "with a lockfile Bundler indented by two spaces" do
      before do
        content = <<~LOCK
          GEM
            remote: https://rubygems.org/
            specs:
              rails (8.0.0)

          RUBY VERSION
            ruby 4.0.6
        LOCK
        File.write(File.join(tmpdir, "Gemfile.lock"), content)
      end

      it "still names the ruby version" do
        expect(introspector.call[:declared_ruby_version]).to eq("4.0.6")
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

  # Every Rails app resolves minitest through activesupport, so an RSpec-only
  # app was told it had a Minitest suite in a test/ directory it does not have.
  describe "a notable gem that arrives as someone else's dependency" do
    def write_lockfile(dependencies)
      File.write(File.join(tmpdir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            activesupport (8.0.5.1)
              minitest (>= 5.1)
            minitest (5.25.4)
            rspec-rails (8.0.4)

        DEPENDENCIES
        #{dependencies.map { |d| "  #{d}" }.join("\n")}
      LOCK
    end

    it "leaves minitest out when nothing in the app points at it" do
      write_lockfile([ "rspec-rails (= 8.0.4)" ])

      expect(introspector.call[:notable_gems].map { |g| g[:name] }).not_to include("minitest")
    end

    it "keeps it when the Gemfile names it" do
      write_lockfile([ "minitest", "rspec-rails (= 8.0.4)" ])

      expect(introspector.call[:notable_gems].map { |g| g[:name] }).to include("minitest")
    end

    it "keeps it when the app has a test directory" do
      write_lockfile([ "rspec-rails (= 8.0.4)" ])
      FileUtils.mkdir_p(File.join(tmpdir, "test"))

      expect(introspector.call[:notable_gems].map { |g| g[:name] }).to include("minitest")
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

    # Each of these changes how code in an app is written, and an app built
    # on them read as an app with none of them.
    it "covers the gems that shape an app's architecture" do
      %w[active_interaction paper_trail rack-cors sidekiq-scheduler sidekiq-unique-jobs
         lockbox blind_index neighbor stripe webauthn figaro].each do |name|
        expect(described_class::NOTABLE_GEMS).to have_key(name)
      end
    end

    it "ends every note with terminal punctuation" do
      described_class::NOTABLE_GEMS.each do |gem_name, info|
        expect(info[:note]).to match(/[.!?)]\z/), "Note for #{gem_name} is missing terminal punctuation: #{info[:note].inspect}"
      end
    end
  end
end
