# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::TestIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "an engine's test/dummy" do
    it "reads the engine's suite" do
      Dir.mktmpdir do |engine|
        dummy = File.join(engine, "test", "dummy")
        FileUtils.mkdir_p([ File.join(engine, "test", "fixtures", "shop"), File.join(engine, "test", "models"), dummy ])
        File.write(File.join(engine, "test", "fixtures", "shop", "widgets.yml"), "one:\n  name: x\n")
        File.write(File.join(engine, "test", "models", "widget_test.rb"), "")
        allow(RailsAiContext::PathResolver).to receive(:enclosing_engine_roots).and_return([ engine ])

        result = described_class.new(RailsAiContext::StaticApp.new(dummy)).call

        expect(result[:fixtures]).to include(location: "test/fixtures")
        expect(result[:test_files]).to include("models")
      end
    end

    it "reports the dummy's config/ci.rb with its steps, and the engine's .github, as the project's CI" do
      Dir.mktmpdir do |engine|
        dummy = File.join(engine, "test", "dummy")
        FileUtils.mkdir_p([ File.join(engine, ".github", "workflows"), File.join(engine, "test", "models"), File.join(dummy, "config") ])
        File.write(File.join(engine, "test", "models", "widget_test.rb"), "")
        File.write(File.join(dummy, "config", "ci.rb"), %(CI.run do\n  step "Tests: Rails", "bin/rails test"\nend\n))
        allow(RailsAiContext::PathResolver).to receive(:enclosing_engine_roots).and_return([ engine ])

        result = described_class.new(RailsAiContext::StaticApp.new(dummy)).call

        expect(result[:ci_config]).to eq(%w[rails_ci github_actions])
        expect(result[:ci_steps]).to eq([ { name: "Tests: Rails", command: "bin/rails test" } ])
        expect(result[:ci_steps_dir]).to eq("test/dummy/")
        expect(result[:test_files]).to include("models")
      end
    end
  end

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

    # Errbit sets Devise up in spec/support/devise.rb, not in rails_helper.
    it "reads the helper setup an app keeps in spec/support" do
      support = File.join(Rails.root, "spec/support/devise_setup.rb")
      FileUtils.mkdir_p(File.dirname(support))
      File.write(support, "RSpec.configure do |config|\n  config.include Devise::Test::ControllerHelpers, type: :controller\nend\n")

      File.write(File.join(File.dirname(support), "page_helpers.rb"), "module PageHelpers\n  include Capybara::DSL\nend\n")

      expect(result[:test_helper_setup]).to include("Devise::Test::ControllerHelpers")
      expect(result[:test_helper_setup]).not_to include("Capybara::DSL")
    ensure
      FileUtils.rm_rf(File.dirname(support))
    end

    it "reads a helper included for tagged examples as the helper, not the tag" do
      support = File.join(Rails.root, "spec/support/browser_setup.rb")
      FileUtils.mkdir_p(File.dirname(support))
      File.write(support, "RSpec.configure do |config|\n  config.include BrowserHelpers, :js\nend\n")

      expect(result[:test_helper_setup]).to include("BrowserHelpers")
      expect(result[:test_helper_setup]).not_to include("js")
    ensure
      FileUtils.rm_rf(File.dirname(support))
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

      it "skips the shared-attribute anchor and Rails' own _fixture key" do
        File.write(File.join(fixtures_dir, "accounts.yml"), <<~YAML)
          DEFAULTS: &DEFAULTS
            active: true

          _fixture:
            model_class: Account

          alice:
            <<: *DEFAULTS
            name: Alice
        YAML

        expect(result[:fixture_names]["accounts"]).to eq([ "alice" ])
      end
    end

    context "when both spec/ and test/ hold the same thing" do
      after do
        FileUtils.rm_rf(File.join(Rails.root, "test"))
        FileUtils.rm_rf(File.join(Rails.root, "spec/fixtures"))
        FileUtils.rm_rf(File.join(Rails.root, "spec/cassettes"))
        FileUtils.rm_rf(File.join(Rails.root, "spec/vcr_cassettes"))
      end

      # factory_bot loads every one of its definition paths, in this order.
      it "reports the test/ and spec/ factories, as factory_bot loads both" do
        FileUtils.mkdir_p(File.join(Rails.root, "test/factories"))
        File.write(File.join(Rails.root, "test/factories/orders.rb"), "factory :order\n")

        expect(result[:factories][:location]).to eq("test/factories, spec/factories")
      end

      it "reports the spec/ fixtures and not the test/ ones" do
        FileUtils.mkdir_p(File.join(Rails.root, "spec/fixtures"))
        FileUtils.mkdir_p(File.join(Rails.root, "test/fixtures"))
        File.write(File.join(Rails.root, "spec/fixtures/users.yml"), "one:\n  name: Alice\n")
        File.write(File.join(Rails.root, "test/fixtures/orders.yml"), "one:\n  ref: A\n")

        expect(result[:fixtures]).to eq(location: "spec/fixtures", locations: %w[spec/fixtures], count: 1)
      end

      it "walks past a cassette directory that exists but holds nothing" do
        FileUtils.mkdir_p(File.join(Rails.root, "spec/cassettes"))
        FileUtils.mkdir_p(File.join(Rails.root, "spec/vcr_cassettes"))
        File.write(File.join(Rails.root, "spec/vcr_cassettes/get_user.yml"), "http_interactions: []\n")

        expect(result[:vcr_cassettes]).to eq(location: "spec/vcr_cassettes", count: 1)
      end

      it "counts cassettes in nested directories" do
        FileUtils.mkdir_p(File.join(Rails.root, "spec/cassettes/api"))
        File.write(File.join(Rails.root, "spec/cassettes/api/get_user.yml"), "http_interactions: []\n")

        expect(result[:vcr_cassettes]).to eq(location: "spec/cassettes", count: 1)
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

  describe "categories derived from the app's own layout" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def write_file(relative)
      path = File.join(@root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# test")
    end

    def payload
      described_class.new(double("app", root: @root)).call
    end

    it "counts a directory no naming convention would predict" do
      write_file("spec/models/user_spec.rb")
      write_file("spec/quacking_ducks/duck_spec.rb")
      expect(payload[:test_files]).to eq(
        "models" => { location: "spec/models", count: 1 },
        "quacking_ducks" => { location: "spec/quacking_ducks", count: 1 }
      )
    end

    it "keeps files loose at the root of spec out of a spec/other row" do
      write_file("spec/smoke_spec.rb")
      write_file("spec/other/thing_spec.rb")
      expect(payload[:test_files]).to eq(
        "other" => { location: "spec/other", count: 1 },
        "spec" => { location: "spec", count: 1 }
      )
    end

    it "sums one category across spec and test and names both locations" do
      write_file("spec/models/user_spec.rb")
      write_file("spec/models/post_spec.rb")
      write_file("test/models/comment_test.rb")
      expect(payload[:test_files]["models"]).to eq(location: "spec/models, test/models", count: 3)
    end

    it "gives support files no row of their own" do
      write_file("spec/models/user_spec.rb")
      write_file("spec/support/auth_helpers.rb")
      expect(payload[:test_files].keys).to eq(%w[models])
    end

    it "counts only test files under a system directory" do
      write_file("spec/system/login_spec.rb")
      write_file("spec/system/page_objects/dashboard.rb")
      expect(payload[:system_tests]).to eq(location: "spec/system", count: 1)
    end

    it "sums system tests across spec and test and names both locations" do
      write_file("spec/system/login_spec.rb")
      write_file("test/system/signup_test.rb")
      expect(payload[:system_tests]).to eq(location: "spec/system, test/system", count: 2)
    end

    it "walks each test directory once per introspection" do
      write_file("spec/models/user_spec.rb")
      allow(Dir).to receive(:children).and_call_original

      payload

      expect(Dir).to have_received(:children).with(File.join(@root, "spec")).once
    end

    it "costs the categories, not the whole section, when the walk fails" do
      write_file("spec/models/user_spec.rb")
      allow(Dir).to receive(:children).and_raise(ArgumentError, "invalid byte sequence in UTF-8")

      expect(payload).to include(framework: "rspec", test_files: {}, test_count_by_category: {})
      expect(payload).not_to have_key(:error)
    end

    it "orders rows by count descending, then by name" do
      write_file("spec/models/user_spec.rb")
      write_file("spec/models/post_spec.rb")
      write_file("spec/policies/user_policy_spec.rb")
      write_file("spec/lib/importer_spec.rb")
      expect(payload[:test_files].keys).to eq(%w[models lib policies])
    end
  end

  describe "#detect_database_cleaner" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def cleaner_for(lock)
      File.write(File.join(@root, "Gemfile.lock"), lock)
      described_class.new(double("app", root: @root)).send(:detect_database_cleaner)
    end

    it "reports database_cleaner for database_cleaner-active_record" do
      lock = <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            database_cleaner-active_record (2.2.0)
              database_cleaner-core (~> 2.0.0)
            database_cleaner-core (2.0.1)
      LOCK
      expect(cleaner_for(lock)).to eq({ detected: true })
    end

    it "reports database_cleaner for an adapter other than active_record" do
      lock = <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            database_cleaner-core (2.0.1)
            database_cleaner-mongoid (2.0.1)
      LOCK
      expect(cleaner_for(lock)).to eq({ detected: true })
    end

    it "does not report database_cleaner for database_cleaner-redis alone" do
      lock = <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            database_cleaner-redis (2.0.0)
      LOCK
      expect(cleaner_for(lock)).to be_nil
    end
  end

  describe "#detect_coverage" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    it "does not report simplecov for simplecov-cobertura alone" do
      lock = <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            simplecov-cobertura (2.1.0)
      LOCK
      File.write(File.join(@root, "Gemfile.lock"), lock)
      expect(described_class.new(double("app", root: @root)).send(:detect_coverage)).to be_nil
    end
  end

  # Rails names the set in test/fixtures/admin/notes.yml `admin/notes`;
  # keyed by its basename it answered for a notes.yml the app does not have.
  describe "fixture names in a nested fixture directory" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    it "keys a nested fixture set by its path under the fixtures directory" do
      FileUtils.mkdir_p(File.join(@root, "test", "fixtures", "admin"))
      File.write(File.join(@root, "test", "fixtures", "admin", "notes.yml"), "one:\n  title: A\n")
      File.write(File.join(@root, "test", "fixtures", "users.yml"), "bob:\n  name: B\n")

      names = described_class.new(double("app", root: @root)).call[:fixture_names]

      expect(names).to eq("admin/notes" => %w[one], "users" => %w[bob])
    end
  end

  # A spec/fixtures directory can hold hundreds of JSON, XML and binary files
  # for file_fixture beside one YAML file; "(1 file)" read as the whole directory.
  describe "a fixtures directory that holds more than fixture sets" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    it "counts the YAML fixture sets and the other files apart" do
      FileUtils.mkdir_p(File.join(@root, "spec", "fixtures", "files"))
      File.write(File.join(@root, "spec", "fixtures", "users.yml"), "bob:\n  name: B\n")
      %w[a.json b.json c.pdf].each { |f| File.write(File.join(@root, "spec", "fixtures", "files", f), "x") }

      fixtures = described_class.new(double("app", root: @root)).call[:fixtures]

      expect(fixtures).to eq(location: "spec/fixtures", locations: %w[spec/fixtures], count: 1, other_files: 3)
    end

    it "counts a sensitive-named file too, since counting reads nothing" do
      FileUtils.mkdir_p(File.join(@root, "spec", "fixtures", "ldap"))
      File.write(File.join(@root, "spec", "fixtures", "users.yml"), "bob:\n  name: B\n")
      File.write(File.join(@root, "spec", "fixtures", "ldap", "snakeoil.pem"), "x")

      fixtures = described_class.new(double("app", root: @root)).call[:fixtures]

      expect(fixtures[:other_files]).to eq(1)
    end

    # rspec-rails gives fixture_paths no default, so without one spec/fixtures holds no fixture sets.
    it "reads no fixture sets from spec/fixtures when the RSpec helper sets no fixture_paths" do
      FileUtils.mkdir_p(File.join(@root, "spec", "fixtures", "sidekiq"))
      File.write(File.join(@root, "spec", "fixtures", "sidekiq", "invalid.yml"), "hello\n")
      File.write(File.join(@root, "spec", "rails_helper.rb"), "RSpec.configure do |config|\n  # config.fixture_path = \"spec/fixtures\"\nend\n")

      result = described_class.new(double("app", root: @root)).call

      expect(result[:fixtures]).to be_nil
      expect(result[:fixture_names]).to be_nil
    end

    it "reads spec/fixtures when the RSpec helper sets fixture_paths to it" do
      FileUtils.mkdir_p(File.join(@root, "spec", "fixtures"))
      File.write(File.join(@root, "spec", "fixtures", "users.yml"), "bob:\n  name: B\n")
      File.write(File.join(@root, "spec", "rails_helper.rb"),
                 "RSpec.configure do |config|\n  config.fixture_paths = [Rails.root.join(\"spec/fixtures\")]\nend\n")

      expect(described_class.new(double("app", root: @root)).call[:fixture_names]).to eq("users" => %w[bob])
    end

    it "reads spec/fixtures when the RSpec helper sets fixture_path in a form no listener reads" do
      FileUtils.mkdir_p(File.join(@root, "spec", "fixtures"))
      File.write(File.join(@root, "spec", "fixtures", "users.yml"), "bob:\n  name: B\n")
      File.write(File.join(@root, "spec", "rails_helper.rb"),
                 "RSpec.configure do |config|\n  config.fixture_path = File.expand_path(\"../fixtures\", __FILE__)\nend\n")

      expect(described_class.new(double("app", root: @root)).call[:fixture_names]).to eq("users" => %w[bob])
    end

    it "reads only the directory an RSpec helper sets fixture_paths to, not spec/fixtures beside it" do
      FileUtils.mkdir_p([ File.join(@root, "spec", "fixtures"), File.join(@root, "spec", "support", "fx") ])
      File.write(File.join(@root, "spec", "fixtures", "widgets.yml"), "a:\n  name: A\n")
      File.write(File.join(@root, "spec", "support", "fx", "gadgets.yml"), "b:\n  name: B\n")
      File.write(File.join(@root, "spec", "rails_helper.rb"),
                 "RSpec.configure do |config|\n  config.fixture_paths = [Rails.root.join(\"spec/support/fx\")]\nend\n")

      expect(described_class.new(double("app", root: @root)).call[:fixture_names]).to eq("gadgets" => %w[b])
    end

    it "reads no sets from spec/fixtures when only test/test_helper.rb sets fixture_paths" do
      FileUtils.mkdir_p(File.join(@root, "spec", "fixtures"))
      FileUtils.mkdir_p(File.join(@root, "test", "shared"))
      File.write(File.join(@root, "spec", "fixtures", "users.yml"), "bob:\n  name: B\n")
      File.write(File.join(@root, "test", "shared", "orders.yml"), "one:\n  ref: A\n")
      File.write(File.join(@root, "spec", "rails_helper.rb"), "RSpec.configure do |config|\nend\n")
      File.write(File.join(@root, "test", "test_helper.rb"), "self.fixture_paths << \"test/shared\"\n")

      expect(described_class.new(double("app", root: @root)).call[:fixture_names]).to eq("orders" => %w[one])
    end
  end

  # Consul defines a comment factory per model in a loop,
  # `factory :"#{model}_comment"`. Its name is computed, so it is left out of
  # the names, and counted so no total claims to be exact.
  describe "a factory whose name is computed" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    it "keeps it out of the names and counts it apart" do
      FileUtils.mkdir_p(File.join(@root, "spec", "factories"))
      File.write(File.join(@root, "spec", "factories", "comments.rb"), <<~'RUBY')
        FactoryBot.define do
          factory :comment do
            trait :hidden do
            end
          end
          %w[debate proposal].each do |model|
            factory :"#{model}_comment" do
            end
          end
        end
      RUBY

      result = described_class.new(double("app", root: @root)).call

      expect(result[:factory_names]).to eq("spec/factories/comments.rb" => %w[comment])
      expect(result[:computed_factories]).to eq(1)
      expect(result[:factory_traits]).to eq("comments.rb" => %w[hidden])
    end
  end

  describe "CI configuration" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def write(rel, body = "")
      path = File.join(@root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    def payload
      described_class.new(double("app", root: @root)).call
    end

    it "names Rails 8.1's config/ci.rb and lists the steps bin/ci runs" do
      write("config/ci.rb", <<~RUBY)
        CI.run do
          step "Setup", "bin/setup --skip-server"
          step "Tests: Rails", "bin/rails test"
          # step "Tests: System", "bin/rails test:system"
        end
      RUBY

      expect(payload[:ci_config]).to eq(%w[rails_ci])
      expect(payload[:ci_steps]).to eq([
        { name: "Setup", command: "bin/setup --skip-server" },
        { name: "Tests: Rails", command: "bin/rails test" }
      ])
    end

    it "names Buildkite, Jenkins and Bitbucket Pipelines beside the others" do
      write(".gitlab-ci.yml")
      write(".circleci/config.yml")
      write(".buildkite/pipeline.yml")
      write("Jenkinsfile")
      write("bitbucket-pipelines.yml")

      expect(payload[:ci_config]).to eq(%w[circleci gitlab_ci buildkite jenkins bitbucket_pipelines])
      expect(payload[:ci_steps]).to be_nil
    end

    it "keeps a config/ci.rb that does not parse to its name" do
      write("config/ci.rb", "CI.run do\n  step \"Setup\", \n")

      expect(payload[:ci_config]).to eq(%w[rails_ci])
    end
  end

  # The layout `rails new` and `bin/rails g authentication` write in 8.1.
  describe "test helpers and the setup the helper files run" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def write(rel, body = "")
      path = File.join(@root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    before do
      write("test/helpers/users_helper_test.rb", "class UsersHelperTest < ActionView::TestCase\nend\n")
      write("test/test_helpers/session_test_helper.rb", "module SessionTestHelper\n  def sign_in_as(user)\n  end\nend\n")
      write("test/test_helper.rb", <<~RUBY)
        require "rails/test_help"
        require_relative "test_helpers/session_test_helper"

        module ActiveSupport
          class TestCase
            parallelize(workers: :number_of_processors)
            fixtures :all
          end
        end
      RUBY
      write("test/application_system_test_case.rb", <<~RUBY)
        class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
          driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
        end
      RUBY
    end

    let(:result) { described_class.new(double("app", root: @root)).call }

    it "names test/test_helpers and leaves helper tests to the test files" do
      expect(result[:test_helpers]).to eq(%w[test/test_helpers/session_test_helper.rb])
      expect(result[:test_files]["helpers"]).to eq(location: "test/helpers", count: 1)
    end

    it "shows the parallelize, fixtures and driven_by calls" do
      expect(result[:test_helper_setup]).to eq([
        "parallelize(workers: :number_of_processors)",
        "fixtures :all",
        "driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]"
      ])
    end
  end

  describe "fixture sets read the way ActiveRecord reads them" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def write(rel, body = "")
      path = File.join(@root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    def payload
      described_class.new(double("app", root: @root)).call
    end

    it "keeps subfolder sets apart and drops the labels _fixture ignores" do
      write("test/fixtures/users.yml", "DEFAULTS: &DEFAULTS\n  name: Default\nalice:\n  <<: *DEFAULTS\n  email: alice@example.com\n")
      write("test/fixtures/admin/posts.yml", "pinned:\n  title: Admin pinned\n")
      write("test/fixtures/posts.yml", "_fixture:\n  model_class: Post\n  ignore: base\nbase:\n  title: Base\nfirst:\n  title: Hello\n")

      expect(payload[:fixture_names]).to eq("admin/posts" => %w[pinned], "posts" => %w[first], "users" => %w[alice])
    end

    it "reads the sets under a directory the test helper adds to fixture_paths" do
      write("test/test_helper.rb", "class ActiveSupport::TestCase\n  self.fixture_paths << Rails.root.join(\"test/shared_fixtures\")\nend\n")
      write("test/fixtures/users.yml", "bob:\n  name: B\n")
      write("test/shared_fixtures/plans.yml", "free:\n  price: 0\n")

      result = payload
      expect(result[:fixture_names]).to eq("users" => %w[bob], "plans" => %w[free])
      expect(result[:fixtures]).to eq(location: "test/fixtures, test/shared_fixtures", locations: %w[test/fixtures test/shared_fixtures], count: 2)
    end

    it "reads a directory the test helper adds relative to its own file" do
      write("test/test_helper.rb", "ActiveSupport::TestCase.fixture_paths << File.expand_path(\"../extra_fx\", __dir__)\n")
      write("test/fixtures/users.yml", "bob:\n  name: B\n")
      write("extra_fx/widgets.yml", "one:\n  name: W\n")

      expect(payload[:fixture_names]).to eq("users" => %w[bob], "widgets" => %w[one])
    end

    it "does not follow a fixture path out of the app or into a missing directory" do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "secrets.yml"), "leak:\n  key: x\n")
        FileUtils.mkdir_p(File.join(@root, "test"))
        File.symlink(outside, File.join(@root, "test", "linked"))
        write("test/test_helper.rb", "self.fixture_paths += [\"test/linked\", \"test/nowhere\", \"../up\"]\n")
        write("test/fixtures/users.yml", "bob:\n  name: B\n")

        expect(payload[:fixture_names]).to eq("users" => %w[bob])
      end
    end

    it "reads no fixture file that links out of the app or to a sensitive file" do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "leak.yml"), "secret_label:\n  key: x\n")
        write("config/database.yml", "production:\n  password: x\n")
        write("test/fixtures/users.yml", "bob:\n  name: B\n")
        File.symlink(File.join(outside, "leak.yml"), File.join(@root, "test", "fixtures", "leak.yml"))
        File.symlink(File.join(@root, "config", "database.yml"), File.join(@root, "test", "fixtures", "db.yml"))

        result = payload
        expect(result[:fixture_names]).to eq("users" => %w[bob])
        expect(result[:fixtures]).to eq(location: "test/fixtures", locations: %w[test/fixtures], count: 1)
      end
    end
  end

  # factory_bot loads factories.rb, test/factories.rb and spec/factories.rb and
  # the directories of those names; packs-rails adds each pack's own.
  describe "factories, fabricators and a Cucumber tree" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def write(rel, body = "")
      path = File.join(@root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    def payload
      described_class.new(double("app", root: @root)).call
    end

    before do
      write("spec/factories.rb", "FactoryBot.define do\n  factory :account do\n    name { \"x\" }\n  end\nend\n")
      write("packs/billing/package.yml", "enforce_dependencies: true\n")
      write("packs/billing/spec/factories/invoices.rb", "FactoryBot.define do\n  factory :invoice do\n    number { \"1\" }\n  end\nend\n")
      write("spec/fabricators/product_fabricator.rb", "Fabricator(:product) do\n  title \"W\"\nend\n")
      write("features/x.feature", "Feature: X\n")
      write("features/step_definitions/s.rb", "Given(/^x$/) { }\n")
    end

    it "reads every place factory_bot loads definitions from, packs included" do
      result = payload

      expect(result[:factories]).to eq(location: "spec/factories.rb, packs/billing/spec/factories", count: 2)
      expect(result[:factory_names]).to eq("spec/factories.rb" => %w[account], "packs/billing/spec/factories/invoices.rb" => %w[invoice])
    end

    it "reads the root factories directory and test/factories.rb" do
      write("factories/users.rb", "FactoryBot.define do\n  factory :user\nend\n")
      write("test/factories.rb", "FactoryBot.define do\n  factory :order\nend\n")

      expect(payload[:factory_names].values.flatten).to contain_exactly("account", "invoice", "user", "order")
    end

    # factory_bot loads the paths only when find_definitions or reload runs; factory_bot_rails
    # runs find_definitions on the defaults before any spec helper loads.
    describe "a helper that sets FactoryBot.definition_file_paths" do
      let(:defaults) { %w[spec/factories.rb packs/billing/spec/factories/invoices.rb] }

      before do
        write("custom/factories/c.rb", "FactoryBot.define do\n  factory :custom_one\nend\n")
        write("lib/factories/l.rb", "FactoryBot.define do\n  factory :lib_one\nend\n")
      end

      def with_factory_bot_rails
        write("Gemfile.lock", "GEM\n  specs:\n    factory_bot_rails (6.5.1)\n\nDEPENDENCIES\n  factory_bot_rails\n")
      end

      it "loads only the paths it sets and then finds, and adds the ones it appends" do
        write("spec/support/fb.rb", "::FactoryBot.definition_file_paths = %w[custom/factories]\n::FactoryBot.find_definitions\n")
        expect(payload[:factory_names]).to eq("custom/factories/c.rb" => %w[custom_one])

        write("spec/support/fb.rb", "FactoryBot.definition_file_paths << \"lib/factories\"\nFactoryBot.find_definitions\n")
        expect(payload[:factory_names].keys).to contain_exactly(*defaults, "lib/factories/l.rb")
      end

      it "keeps the defaults when nothing loads the paths it sets" do
        write("spec/support/fb.rb", "FactoryBot.find_definitions\nFactoryBot.definition_file_paths = %w[custom/factories]\n")
        expect(payload[:factory_names].keys).to contain_exactly(*defaults)

        with_factory_bot_rails
        write("spec/support/fb.rb", "FactoryBot.definition_file_paths = %w[custom/factories]\n")
        expect(payload[:factory_names].keys).to contain_exactly(*defaults)
      end

      it "under factory_bot_rails, adds the paths find_definitions loads and replaces them on reload" do
        with_factory_bot_rails
        write("spec/support/fb.rb", "FactoryBot.definition_file_paths = %w[custom/factories]\nFactoryBot.find_definitions\n")
        expect(payload[:factory_names].keys).to contain_exactly(*defaults, "custom/factories/c.rb")

        write("spec/support/fb.rb", "FactoryBot.definition_file_paths = %w[custom/factories]\nFactoryBot.reload\n")
        expect(payload[:factory_names].keys).to eq(%w[custom/factories/c.rb])
      end
    end

    it "reads no pack factories from a pack that is a gem" do
      write("packs/billing/billing.gemspec", "")

      expect(payload[:factory_names].keys).to eq(%w[spec/factories.rb])
    end

    it "reads Fabrication's fabricators" do
      result = payload

      expect(result[:fabricators]).to eq(location: "spec/fabricators", count: 1)
      expect(result[:fabricator_names]).to eq("spec/fabricators/product_fabricator.rb" => %w[product])
    end

    it "counts the Cucumber features and step definitions" do
      expect(payload[:cucumber]).to eq(location: "features", count: 1, step_definitions: 1)
    end

    it "does not read a factory file linked from outside the app" do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "leak.rb"), "FactoryBot.define do\n  factory :leak\nend\n")
        FileUtils.mkdir_p(File.join(@root, "spec/factories"))
        File.symlink(File.join(outside, "leak.rb"), File.join(@root, "spec/factories/leak.rb"))

        expect(payload[:factory_names].values.flatten).not_to include("leak")
      end
    end
  end

  describe "#detect_framework" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def write(rel, body = "")
      path = File.join(@root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    it "does not call a Jasmine spec directory RSpec when test/ holds the suite" do
      write("spec/javascripts/admin_spec.js")
      write("spec/support/jasmine-browser.json", "{}")
      write("test/unit/user_test.rb")
      write("Gemfile.lock", "GEM\n  specs:\n    minitest (5.25.4)\n\nDEPENDENCIES\n  minitest\n")

      expect(described_class.new(double("app", root: @root)).call[:framework]).to eq("minitest")
    end
  end
end
