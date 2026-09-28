# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::EnvReferences do
  around { |example| Dir.mktmpdir { |dir| @root = File.realpath(dir); example.run } }

  def write(rel, body)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def names_in(rel)
    Array(described_class.scan(@root)[File.join(@root, rel)]).map { |ref| ref[:name] }
  end

  it "reads each ENV name a Ruby file reads, with its default and whether it can be nil" do
    write("app/services/billing.rb", <<~RUBY)
      class Billing
        KEY = ENV.fetch("STRIPE_TIMEOUT", "30")
        PORT = ENV["PORT"]
      end
    RUBY

    refs = described_class.scan(@root)[File.join(@root, "app/services/billing.rb")]

    expect(refs).to include(a_hash_including(name: "STRIPE_TIMEOUT", default: "30"))
    expect(refs).to include(a_hash_including(name: "PORT", bracket: true))
  end

  it "reads the ERB in a config YAML file" do
    write("config/database.yml", "production:\n  host: <%= ENV[\"DB_HOST\"] %>\n")

    expect(names_in("config/database.yml")).to eq(%w[DB_HOST])
  end

  it "does not read a commented-out ENV reference" do
    write("lib/tasks/setup.rake", "# ENV[\"GONE\"]\nENV.fetch(\"KEPT\")\n")

    expect(names_in("lib/tasks/setup.rake")).to eq(%w[KEPT])
  end

  it "leaves out a file that reads no ENV" do
    write("app/models/user.rb", "class User; end\n")

    expect(described_class.scan(@root)).to be_empty
  end
end
