# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::DatabaseYml do
  def path_for(search_path, username: nil)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      yml = +"#{RailsAiContext.environment_name}:\n  adapter: postgresql\n  schema_search_path: #{search_path.inspect}\n"
      yml << "  username: #{username}\n" if username
      File.write(File.join(dir, "config", "database.yml"), yml)
      described_class.schema_search_path(dir)
    end
  end

  # PostgreSQL splits the list itself (SplitIdentifierString): a quoted name keeps its commas and spaces and reads "" as a quote.
  it "reads a quoted schema name whole, a comma, a space and a doubled quote in it" do
    expect(path_for(%("my ""s", "a,b", " x y ", Public, "Mixed", public))).to eq([ 'my "s', "a,b", " x y ", "public", "Mixed" ])
  end

  it "drops an empty quoted entry" do
    expect(path_for(%("", public))).to eq(%w[public])
  end

  it "reads the $user entry quoted or not, as the configured username" do
    expect(path_for(%("$user", public), username: "app")).to eq(%w[app public])
    expect(path_for(%($user, public), username: "app")).to eq(%w[app public])
  end

  describe "an adapter the file computes in ERB" do
    def adapter_for(value)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), "#{RailsAiContext.environment_name}:\n  adapter: #{value}\n")
        described_class.adapter("primary", described_class.primary(dir))
      end
    end

    it "reads the literal default ENV.fetch falls back to as the adapter's default" do
      expect(adapter_for(%(<%= ENV.fetch("DB_ADAPTER", "mysql2") %>))).to eq([ "mysql2", true ])
    end

    it "reads the default a fetch block returns" do
      expect(adapter_for(%(<%= ENV.fetch("DB_ADAPTER") { "postgresql" } %>))).to eq([ "postgresql", true ])
    end

    it "leaves a fetch whose result is computed on unknown" do
      expect(adapter_for(%(<%= ENV.fetch("DB_ADAPTER", "mysql") + "2" %>))).to eq([ nil, false ])
    end
  end
end
