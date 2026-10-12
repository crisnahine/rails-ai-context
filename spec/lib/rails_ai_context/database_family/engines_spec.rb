# frozen_string_literal: true

require "spec_helper"

# Runs each family against a real engine. Each group runs only when its URL is set,
# with the driver from gemfiles/engines.gemfile (see CONTRIBUTING.md).
RSpec.describe RailsAiContext::DatabaseFamily do
  def self.engine(env)
    ENV[env] ? false : "set #{env} to run this family against a real engine"
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    @took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  let(:conn) { RacEngineSpecRecord.connection }
  let(:family) { described_class.of(conn) }

  def connect(env)
    stub_const("RacEngineSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RacEngineSpecRecord.establish_connection(ENV.fetch(env))
    RacEngineSpecRecord.connection.tap do |c|
      c.execute("DROP VIEW IF EXISTS rac_engine_view")
      c.execute("DROP TABLE IF EXISTS rac_engine_rows")
      c.execute("CREATE TABLE rac_engine_rows (id int)")
      c.execute("INSERT INTO rac_engine_rows VALUES (1), (2), (3)")
      c.execute("CREATE VIEW rac_engine_view AS SELECT id FROM rac_engine_rows")
    end
  end

  after do
    if defined?(RacEngineSpecRecord)
      RacEngineSpecRecord.connection.execute("DROP VIEW IF EXISTS rac_engine_view")
      RacEngineSpecRecord.connection.execute("DROP TABLE IF EXISTS rac_engine_rows")
      RacEngineSpecRecord.remove_connection
    end
  end

  shared_examples "a guarded engine" do
    it "reads rows" do
      expect(family.read_only(conn, "WITH t AS (SELECT id FROM rac_engine_rows) SELECT id FROM t ORDER BY id", timeout: 5).rows.flatten.map(&:to_i))
        .to eq([ 1, 2, 3 ])
    end

    it "refuses a write" do
      expect { family.read_only(conn, "INSERT INTO rac_engine_rows VALUES (9)", timeout: 5) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(conn.select_value("SELECT COUNT(*) FROM rac_engine_rows").to_i).to eq(3)
    end

    it "reads an error about a missing column named timeout as an SQL error" do
      expect { family.read_only(conn, "SELECT timeout FROM rac_engine_rows", timeout: 5) }
        .to raise_error(ActiveRecord::StatementInvalid) { |e| expect(e).not_to be_a(described_class::TimedOut) }
    end

    it "explains a statement" do
      expect(family.explain(conn, "SELECT id FROM rac_engine_rows", timeout: 5)[:raw]).to include("rac_engine_rows")
    end

    it "sizes and counts base tables only" do
      sized = family.table_sizes(conn).map { |r| r[:name] }
      counted = family.row_estimates(conn).map { |r| r[:table] }

      expect([ sized, counted ]).to all(include("rac_engine_rows"))
      expect(sized + counted).not_to include("rac_engine_view")
    end
  end

  shared_examples "a MySQL-family engine" do
    it_behaves_like "a guarded engine"

    it "bounds a WITH statement" do
      elapsed do
        expect { family.read_only(conn, "WITH t AS (SELECT id FROM rac_engine_rows) SELECT id FROM t WHERE SLEEP(1) = 0", timeout: 0.5) }
          .to raise_error(described_class::TimedOut)
      end
      expect(@took).to be < 2
    end
  end

  describe "PostgreSQL", skip: engine("RAC_TEST_PG_URL") do
    before { connect("RAC_TEST_PG_URL") }

    it_behaves_like "a guarded engine"

    it "bounds a statement" do
      elapsed { expect { family.read_only(conn, "SELECT pg_sleep(3)", timeout: 0.5) }.to raise_error(described_class::TimedOut) }
      expect(@took).to be < 2
    end

    it "bounds EXPLAIN ANALYZE" do
      elapsed { expect { family.explain(conn, "SELECT pg_sleep(3)", timeout: 0.5) }.to raise_error(described_class::TimedOut) }
      expect(@took).to be < 2
    end

    it "plans without running" do
      expect(family.plan(conn, "SELECT id FROM rac_engine_rows", timeout: 5)).to include("Node Type" => "Seq Scan")
    end

    it "traces a renamed result column to its table column" do
      expect(family.column_sources(conn, "SELECT 1 AS one, id AS n FROM rac_engine_rows", plan: nil)).to eq([ [ 1, "id" ] ])
    end

    it "reports index usage" do
      expect(family.index_usage(conn)).to be_an(Array)
    end
  end

  describe "MySQL", skip: engine("RAC_TEST_MYSQL_URL") do
    before { connect("RAC_TEST_MYSQL_URL") }

    it_behaves_like "a MySQL-family engine"

    it "bounds EXPLAIN ANALYZE" do
      elapsed { family.read_only(conn, "EXPLAIN ANALYZE SELECT id FROM rac_engine_rows WHERE SLEEP(1) = 0", timeout: 0.5) }
      expect(@took).to be < 2
    end

    it "restores the session's own max_execution_time, also after a timeout" do
      conn.execute("SET SESSION max_execution_time = 4321")
      family.read_only(conn, "SELECT 1", timeout: 5)
      expect { family.read_only(conn, "SELECT id FROM rac_engine_rows WHERE SLEEP(1) = 0", timeout: 0.5) }.to raise_error(described_class::TimedOut)

      expect(conn.select_value("SELECT @@SESSION.max_execution_time").to_i).to eq(4321)
    end
  end

  describe "MariaDB", skip: engine("RAC_TEST_MARIADB_URL") do
    before { connect("RAC_TEST_MARIADB_URL") }

    it_behaves_like "a MySQL-family engine"
  end
end
