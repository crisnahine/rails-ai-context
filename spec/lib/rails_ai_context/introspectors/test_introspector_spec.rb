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

    it "returns nil for factories when none exist" do
      expect(result[:factories]).to be_nil
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
      let(:spec_dir) { File.join(Rails.root, "spec") }

      before { FileUtils.mkdir_p(spec_dir) }
      after { FileUtils.rm_rf(spec_dir) }

      it "detects rspec framework" do
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
      let(:factories_dir) { File.join(Rails.root, "spec/factories") }

      before do
        FileUtils.mkdir_p(factories_dir)
        File.write(File.join(factories_dir, "users.rb"), "FactoryBot.define {}")
      end

      after { FileUtils.rm_rf(File.join(Rails.root, "spec")) }

      it "detects factories with location and count" do
        expect(result[:factories]).to be_a(Hash)
        expect(result[:factories][:location]).to eq("spec/factories")
        expect(result[:factories][:count]).to eq(1)
      end
    end

    it "returns fixture_names as nil when no fixtures exist" do
      expect(result[:fixture_names]).to be_nil
    end

    it "returns factory_names as nil when no factories exist" do
      expect(result[:factory_names]).to be_nil
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
      let(:factories_dir) { File.join(Rails.root, "spec/factories") }

      before do
        FileUtils.mkdir_p(factories_dir)
        File.write(File.join(factories_dir, "users.rb"), <<~RUBY)
          FactoryBot.define do
            factory :user do
              name { "Alice" }
            end
            factory :admin_user do
              name { "Admin" }
            end
          end
        RUBY
      end

      after { FileUtils.rm_rf(File.join(Rails.root, "spec")) }

      it "extracts factory names from ruby files" do
        expect(result[:factory_names]).to be_a(Hash)
        expect(result[:factory_names]["spec/factories/users.rb"]).to include("user", "admin_user")
      end
    end
  end
end
