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

  it "leaves out file_fixture_path and paths it cannot read" do
    expect(paths(<<~RUBY)).to eq([])
      self.file_fixture_path = "test/fixtures/files"
      self.fixture_paths << File.expand_path("fixtures", __dir__)
      config.autoload_paths << "lib"
    RUBY
  end
end
