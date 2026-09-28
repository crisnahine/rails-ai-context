# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::TestFramework do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  def write(rel, body = "")
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def lockfile(deps: [], specs: [])
    write("Gemfile.lock", <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:
      #{specs.map { |s| "    #{s}" }.join("\n")}

      DEPENDENCIES
      #{deps.map { |d| "  #{d}" }.join("\n")}
    LOCK
  end

  it "reads a spec directory of Jasmine JavaScript as minitest when test/ holds the suite" do
    write("spec/javascripts/admin_spec.js")
    write("spec/support/jasmine-browser.json", "{}")
    write("test/unit/user_test.rb")
    lockfile(deps: %w[minitest rubocop-rspec], specs: [ "rspec-core (3.13.6)", "minitest (5.25.4)" ])

    expect(described_class.for(@root)).to eq("minitest")
  end

  # Diaspora's Gemfile carries `gem "minitest"` with no test/ directory at all.
  # A gem in the bundle is not a suite.
  it "does not read a bundled minitest with no test tree as a suite" do
    write("spec/models/user_spec.rb")
    lockfile(deps: %w[rspec-rails minitest], specs: [ "rspec-rails (7.1.0)", "minitest (5.25.4)" ])

    expect(described_class.for(@root)).to eq("rspec")
  end

  it "does not read a bundled rspec with no spec tree as a suite" do
    write("test/unit/user_test.rb")
    lockfile(deps: %w[rspec rubocop-rspec], specs: [ "rspec (3.13.2)", "rspec-core (3.13.6)" ])

    expect(described_class.for(@root)).to eq("minitest")
  end

  it "names both when each framework has its own suite" do
    write("spec/models/user_spec.rb")
    write("test/unit/user_test.rb")
    lockfile

    expect(described_class.for(@root)).to eq("rspec, minitest")
  end

  it "reads an app with only spec files as rspec" do
    write("spec/models/user_spec.rb")
    lockfile

    expect(described_class.for(@root)).to eq("rspec")
  end

  it "reads spec/factories without spec files as rspec" do
    write("spec/factories/users.rb")
    lockfile

    expect(described_class.for(@root)).to eq("rspec")
  end

  # Every Rails app bundles minitest through activesupport, so a bundle with
  # it in says nothing about a suite; with no test anywhere the app runs none.
  it "says there are no tests, and which framework the bundle holds, when the app has none" do
    lockfile(specs: [ "minitest (5.25.4)" ])

    expect(described_class.for(@root)).to eq("no tests yet (minitest in the bundle)")
  end

  it "falls back to the lockfile with no test directory at all, GIT section included" do
    write("Gemfile.lock", <<~LOCK)
      GIT
        remote: https://github.com/rspec/rspec-rails.git
        revision: 0123456789abcdef0123456789abcdef01234567
        specs:
          rspec-rails (7.1.0)
    LOCK

    expect(described_class.for(@root)).to eq("no tests yet (rspec-rails in the bundle)")
  end

  it "says there are no tests with nothing to read" do
    expect(described_class.for(@root)).to eq("no tests yet")
  end

  it "still scaffolds and runs the framework the bundle holds" do
    expect(described_class.command("no tests yet (rspec-rails in the bundle)")).to eq("bundle exec rspec")
    expect(described_class.command("no tests yet (minitest in the bundle)")).to eq("rails test")
  end
  describe ".candidates" do
    # OpenFoodNetwork keeps spec/requests/payments_controller_spec.rb.
    it "tries every controller suffix in both controller spec directories" do
      list = described_class.candidates("/nonexistent", :controller, "payments", {})

      expect(list).to include("spec/requests/payments_controller_spec.rb", "spec/controllers/payments_spec.rb")
    end
  end

  describe ".test_style" do
    def tests(files)
      files.each { |rel, body| write(rel, body) }
      described_class.test_style(@root, "test/controllers")
    end

    it "reads a superclass written from the root scope" do
      style = tests(
        "test/controllers/users_controller_test.rb" => "class UsersControllerTest < ::ActionController::TestCase\nend\n",
        "test/controllers/posts_controller_test.rb" => "class PostsControllerTest < ::ActionController::TestCase\nend\n"
      )

      expect(style[:test_case]).to be(true)
    end

    it "follows an app base class to the framework class it inherits" do
      style = tests(
        "test/application_controller_test_case.rb" =>
          "class ApplicationControllerTestCase < ActionController::TestCase\nend\n",
        "test/controllers/admin/users_controller_test.rb" =>
          "class Admin::UsersControllerTest < ApplicationControllerTestCase\nend\n",
        "test/controllers/admin/posts_controller_test.rb" =>
          "class Admin::PostsControllerTest < ApplicationControllerTestCase\nend\n",
        "test/controllers/home_controller_test.rb" => "class HomeControllerTest < ActionDispatch::IntegrationTest\nend\n"
      )

      expect(style[:test_case]).to be(true)
    end

    it "counts FactoryBot.create as building with factories" do
      style = tests(
        "test/controllers/users_controller_test.rb" =>
          "class UsersControllerTest < ActionDispatch::IntegrationTest\n  setup { @user = FactoryBot.create(:user) }\nend\n"
      )

      expect(style).to eq(test_case: false, factories: true)
    end

    it "does not take an ActiveRecord create for a factory" do
      style = tests(
        "test/controllers/users_controller_test.rb" =>
          "class UsersControllerTest < ActionDispatch::IntegrationTest\n  setup { @user = User.create(name: \"a\") }\nend\n"
      )

      expect(style[:factories]).to be(false)
    end
  end
end
