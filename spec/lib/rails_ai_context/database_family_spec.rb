# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::DatabaseFamily do
  describe ".of" do
    {
      # Live adapter_name values.
      "PostgreSQL" => :postgresql, "PostGIS" => :postgresql, "Mysql2" => :mysql, "Trilogy" => :mysql, "SQLite" => :sqlite,
      # database.yml adapters.
      "postgresql" => :postgresql, "postgis" => :postgresql, "mysql2" => :mysql, "trilogy" => :mysql, "sqlite3" => :sqlite,
      # URL schemes.
      "postgres" => :postgresql, "mysql" => :mysql, "sqlite" => :sqlite,
      # Display labels, including a database.yml default.
      "MySQL" => :mysql, "PostgreSQL by database.yml default" => :postgresql, "SQLite by database.yml default" => :sqlite,
      # Dump dialects.
      postgresql: :postgresql, mysql: :mysql, sqlite: :sqlite,
      # No family.
      "sqlserver" => :unknown, "SQLServer" => :unknown, "oracle_enhanced" => :unknown, "OracleEnhanced" => :unknown,
      "cockroachdb" => :unknown, "CockroachDB" => :unknown, "jdbcpostgresql" => :unknown, "static_parse" => :unknown,
      "unknown" => :unknown, "" => :unknown, nil => :unknown,
      "PostgreSQL or MySQL" => :unknown, "MySQL or SQLite, database.yml does not say which" => :unknown
    }.each do |source, key|
      it "classifies #{source.inspect} as #{key}" do
        expect(described_class.of(source).key).to eq(key)
      end
    end

    it "reads a connection's adapter_name and a db_config's adapter" do
      expect(described_class.of(double(adapter_name: "Trilogy")).key).to eq(:mysql)
      expect(described_class.of(double(adapter: "postgis")).key).to eq(:postgresql)
    end

    it "never raises on an object that names nothing" do
      expect(described_class.of(Object.new).key).to eq(:unknown)
      expect(described_class.of(double(adapter_name: nil)).key).to eq(:unknown)
    end

    it "answers the same frozen family for every spelling" do
      expect(described_class.of("Mysql2")).to equal(described_class::MYSQL)
      expect(described_class::MYSQL).to be_frozen
    end
  end

  describe "#name" do
    it "names a family as the other surfaces do" do
      expect([ "Mysql2", "Trilogy", "PostGIS", "sqlite3" ].map { |s| described_class.of(s).name }).to eq(%w[MySQL MySQL PostgreSQL SQLite])
    end

    it "keeps the raw name for no family" do
      expect(described_class.of("SQLServer").name).to eq("SQLServer")
      expect(described_class.of("PostgreSQL or MySQL").name).to eq("PostgreSQL or MySQL")
      expect(described_class.of(nil).name).to eq("unknown")
    end
  end

  describe "#known?" do
    it "is true for the three families only" do
      expect(%w[postgresql mysql2 sqlite3 sqlserver].map { |s| described_class.of(s).known? }).to eq([ true, true, true, false ])
    end
  end

  describe "#implicit_pk_type" do
    it "is integer on SQLite and bigint everywhere else" do
      expect(%w[sqlite3 postgresql trilogy sqlserver].map { |s| described_class.of(s).implicit_pk_type }).to eq(%w[integer bigint bigint bigint])
    end
  end

  describe "the library" do
    database = /postg|mysql|trilogy|sqlite|maria/i
    rules = {
      "tests an adapter name" => /\badapter\w*\b.*(?:\.match\?|=~|\.start_with\?|\.end_with\?|\.include\?|==|!=|\.casecmp)/,
      "switches on a database name" => /^\s*when\s+(?:\/|"|')/,
      "keeps a database name pattern" => /\b[A-Z_]*(?:ADAPTER|DIALECT)[A-Z_]*\s*=\s*(?:\/|%r)/
    }
    # Only a database name inside a string or a pattern counts; a family key such as :mysql is the answer, not a test.
    offences = lambda do |source|
      lines = source.lines
      named = Prism.lex(source).value.filter_map do |token, _|
        token.location.start_line if token.type == :STRING_CONTENT && token.value.match?(database)
      end
      named.uniq.filter_map do |number|
        rule = rules.find { |_, pattern| lines[number - 1].match?(pattern) }&.first
        "#{number} #{rule}: #{lines[number - 1].strip}" if rule
      end
    end

    it "decides the family nowhere but in DatabaseFamily" do
      root = File.expand_path("../../../lib", __dir__)
      found = Dir.glob(File.join(root, "**", "*.rb")).sort.flat_map do |file|
        next [] if file.end_with?("rails_ai_context/database_family.rb")

        offences.call(File.read(file)).map { |offence| "#{file.delete_prefix("#{root}/")}:#{offence}" }
      end
      expect(found).to be_empty
    end

    it "catches each way a database name test is spelled" do
      [
        'adapter_name.to_s.match?(/sqlite/i)',
        'db_config.adapter.to_s == "sqlite3"',
        'return if adapter && !adapter.start_with?("postg")',
        "case adapter\nwhen /sqlite/ then 1\nend",
        'MYSQL_ADAPTER = /mysql|trilogy/i'
      ].each { |source| expect(offences.call(source)).not_to be_empty, source }
      expect(offences.call('x = family(adapter) == :mysql if type == "string"')).to be_empty
    end
  end
end
