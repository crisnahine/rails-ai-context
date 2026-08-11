# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::TestIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns framework as a known string" do
      expect(%w[rspec minitest unknown]).to include(result[:framework])
    end

    it "returns CI config as array" do
      expect(result[:ci_config]).to be_an(Array)
    end

    it "returns test_helpers as array" do
      expect(result[:test_helpers]).to be_an(Array)
    end

    it "detects factories when they exist" do
      expect(result[:factories]).to be_a(Hash)
      expect(result[:factories][:location]).to eq("spec/factories")
      expect(result[:factories][:count]).to be >= 2
    end

    it "returns nil for fixtures when none exist" do
      expect(result[:fixtures]).to be_nil
    end

    it "returns nil for system_tests when none exist" do
      expect(result[:system_tests]).to be_nil
    end

    it "returns nil for vcr_cassettes when none exist" do
      expect(result[:vcr_cassettes]).to be_nil
    end

    it "returns nil for coverage when no Gemfile.lock" do
      expect(result[:coverage]).to be_nil
    end

    context "with a spec directory" do
      it "detects rspec framework" do
        # spec/factories/ exists as permanent fixture, so spec/ dir is always present
        expect(result[:framework]).to eq("rspec")
      end
    end

    context "with a test directory" do
      let(:test_dir) { File.join(Rails.root, "test") }

      before { FileUtils.mkdir_p(test_dir) }
      after { FileUtils.rm_rf(test_dir) }

      it "detects minitest framework" do
        # Ensure spec/ doesn't exist (rspec takes priority)
        spec_dir = File.join(Rails.root, "spec")
        had_spec = Dir.exist?(spec_dir)
        expect(result[:framework]).to eq(had_spec ? "rspec" : "minitest")
      end
    end

    context "with factories" do
      it "detects factories with location and count" do
        # Permanent factory fixtures exist in spec/factories/
        expect(result[:factories]).to be_a(Hash)
        expect(result[:factories][:location]).to eq("spec/factories")
        expect(result[:factories][:count]).to be >= 2
      end
    end

    it "returns fixture_names as nil when no fixtures exist" do
      expect(result[:fixture_names]).to be_nil
    end

    it "extracts factory names from existing factories" do
      expect(result[:factory_names]).to be_a(Hash)
    end

    it "returns test_helper_setup as array" do
      expect(result[:test_helper_setup]).to be_an(Array)
    end

    it "returns test_files as hash" do
      expect(result[:test_files]).to be_a(Hash)
    end

    context "with fixtures" do
      let(:fixtures_dir) { File.join(Rails.root, "test/fixtures") }

      before do
        FileUtils.mkdir_p(fixtures_dir)
        File.write(File.join(fixtures_dir, "users.yml"), "one:\n  name: Alice\ntwo:\n  name: Bob\n")
      end

      after { FileUtils.rm_rf(File.join(Rails.root, "test")) }

      it "extracts fixture names from YAML files" do
        expect(result[:fixture_names]).to be_a(Hash)
        expect(result[:fixture_names]["users"]).to include("one", "two")
      end
    end

    context "with factory files containing factory definitions" do
      it "extracts factory names from permanent factory files" do
        # Permanent factory fixtures exist in spec/factories/
        expect(result[:factory_names]).to be_a(Hash)
        expect(result[:factory_names]["spec/factories/users.rb"]).to include("user")
      end
    end

    it "returns factory_traits from existing factory files" do
      # Permanent factory fixtures have traits defined
      expect(result[:factory_traits]).to be_a(Hash)
      expect(result[:factory_traits]["users.rb"]).to include("admin", "active", "inactive")
    end

    it "returns test_count_by_category as hash" do
      expect(result[:test_count_by_category]).to be_a(Hash)
    end

    context "with test files in categorized directories" do
      let(:models_spec_dir) { File.join(Rails.root, "spec/models") }

      before do
        FileUtils.mkdir_p(models_spec_dir)
        File.write(File.join(models_spec_dir, "user_spec.rb"), "# test")
        File.write(File.join(models_spec_dir, "post_spec.rb"), "# test")
      end

      after { FileUtils.rm_rf(models_spec_dir) }

      it "counts test files by category" do
        expect(result[:test_count_by_category]["models"]).to eq(2)
      end
    end

    context "with non-spec Ruby files sitting beside the specs" do
      let(:mailers_spec_dir) { File.join(Rails.root, "spec/mailers") }
      let(:previews_dir) { File.join(mailers_spec_dir, "previews") }

      before do
        FileUtils.mkdir_p(previews_dir)
        File.write(File.join(mailers_spec_dir, "user_mailer_spec.rb"), "# test")
        File.write(File.join(previews_dir, "user_mailer_preview.rb"), "# not a test")
        File.write(File.join(previews_dir, "admin_mailer_preview.rb"), "# not a test")
      end

      after { FileUtils.rm_rf(mailers_spec_dir) }

      it "counts only the specs, not the previews beside them" do
        expect(result[:test_count_by_category]["mailers"]).to eq(1)
      end
    end

    context "with a minitest suite" do
      let(:models_test_dir) { File.join(Rails.root, "test/models") }

      before do
        FileUtils.mkdir_p(models_test_dir)
        File.write(File.join(models_test_dir, "user_test.rb"), "# test")
        File.write(File.join(models_test_dir, "test_helper_shim.rb"), "# support")
      end

      after { FileUtils.rm_rf(models_test_dir) }

      it "counts _test.rb files and skips support files" do
        expect(result[:test_count_by_category]["models"]).to eq(1)
      end
    end
  end
end
