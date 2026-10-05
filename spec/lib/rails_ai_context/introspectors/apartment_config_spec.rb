# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::ApartmentConfig do
  def read_with(files)
    Dir.mktmpdir do |dir|
      files.each do |path, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), body)
      end
      described_class.read(dir)
    end
  end

  it "reads the excluded models an Apartment.configure block assigns, and where" do
    found = read_with("config/initializers/apartment.rb" => <<~RUBY)
      Apartment.configure do |config|
        config.excluded_models = %w[Organization ::Billing::Plan]
        config.tenant_names = -> { Organization.pluck(:subdomain) }
      end
    RUBY

    expect(found).to eq(excluded_models: %w[Organization Billing::Plan], file: "config/initializers/apartment.rb")
  end

  it "keeps a computed list as written" do
    found = read_with("config/initializers/00_tenancy.rb" => "Apartment.configure do |config|\n  config.excluded_models = SHARED.map(&:name)\nend\n")

    expect(found).to eq(excluded_models_source: "SHARED.map(&:name)", file: "config/initializers/00_tenancy.rb")
  end

  it "answers an empty list when the block excludes nothing" do
    expect(read_with("config/initializers/apartment.rb" => "Apartment.configure do |config|\nend\n"))
      .to eq(excluded_models: [], file: "config/initializers/apartment.rb")
  end

  it "keeps a list with a computed name as written" do
    found = read_with("config/initializers/apartment.rb" => "Apartment.configure do |config|\n  config.excluded_models = [Plan.name, \"A\"]\nend\n")

    expect(found).to eq(excluded_models_source: "[Plan.name, \"A\"]", file: "config/initializers/apartment.rb")
  end

  it "reads the list through whatever name the block gives its parameter" do
    found = read_with("config/initializers/apartment.rb" => "Apartment.configure do |c|\n  c.excluded_models = %w[Organization]\nend\n")

    expect(found).to eq(excluded_models: %w[Organization], file: "config/initializers/apartment.rb")
  end

  it "keeps a list the block adds to with += or << as written" do
    plus = read_with("config/initializers/apartment.rb" => "Apartment.configure do |config|\n  config.excluded_models += %w[Organization]\nend\n")
    push = read_with("config/initializers/apartment.rb" => "Apartment.configure { |c| c.excluded_models << \"Organization\" }\n")

    expect(plus).to eq(excluded_models_source: "config.excluded_models += %w[Organization]", file: "config/initializers/apartment.rb")
    expect(push).to eq(excluded_models_source: "c.excluded_models << \"Organization\"", file: "config/initializers/apartment.rb")
  end

  it "reads a list the block only iterates over afterwards" do
    found = read_with("config/initializers/apartment.rb" => <<~RUBY)
      Apartment.configure do |config|
        config.excluded_models = %w[Organization]
        config.excluded_models.each { |name| name.constantize }
      end
    RUBY

    expect(found).to eq(excluded_models: %w[Organization], file: "config/initializers/apartment.rb")
  end

  it "answers nil without an Apartment.configure, and for a file that does not parse" do
    expect(read_with("config/initializers/other.rb" => "config.excluded_models = %w[A]\n")).to be_nil
    expect(read_with("config/initializers/apartment.rb" => "Apartment.configure do |config|\n  config.excluded_models = %w[\n")).to be_nil
    expect(read_with({})).to be_nil
  end
end
