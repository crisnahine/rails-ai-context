# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::FixturePathsListener do
  def paths(source)
    RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { fixtures: described_class })[:fixtures]
  end

  it "reads every literal form a test helper sets a fixture directory in" do
    expect(paths(<<~RUBY)).to eq(%w[spec/fixtures spec/legacy_fixtures test/fixtures/ test/shared_fixtures db/fixtures])
      config.fixture_paths = [Rails.root.join("spec/fixtures")]
      config.fixture_path = "\#{::Rails.root}/spec/legacy_fixtures"
      self.fixture_paths << "\#{Rails.root}/test/fixtures/"
      self.fixture_paths += [Rails.root.join("test", "shared_fixtures")]
      fixture_paths.push "db/fixtures"
    RUBY
  end

  it "reads the setting on the block parameter RSpec.configure yields" do
    expect(paths(<<~RUBY)).to eq(%w[spec/fixtures])
      RSpec.configure do |config|
        config.fixture_paths = [Rails.root.join("spec/fixtures")]
      end
    RUBY
  end

  it "leaves out file_fixture_path, and records a write whose path it cannot read as unread" do
    expect(paths(<<~RUBY)).to eq([ :unread ])
      self.file_fixture_path = "test/fixtures/files"
      self.fixture_paths << File.expand_path("fixtures", __dir__)
      config.autoload_paths << "lib"
    RUBY
  end

  it "reads a path relative to the helper's own directory, on the test case constant too" do
    found = RailsAiContext::Introspectors::SourceIntrospector.walk_source(<<~RUBY, { fixtures: -> { described_class.new(file: "test/test_helper.rb") } })[:fixtures]
      ActiveSupport::TestCase.fixture_paths << File.expand_path("../extra_fx", __dir__)
      self.fixture_paths << File.expand_path("../../shared_fx", __FILE__)
      self.fixture_paths << File.join(__dir__, "more_fx")
    RUBY
    expect(found).to eq(%w[extra_fx shared_fx test/more_fx])
  end
end
