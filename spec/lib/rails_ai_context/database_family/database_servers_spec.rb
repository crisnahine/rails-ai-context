# frozen_string_literal: true

require "spec_helper"

# Runs each family against a real database server. Each group runs only when its URL is set,
# with the driver from gemfiles/database_servers.gemfile (see CONTRIBUTING.md).
RSpec.describe RailsAiContext::DatabaseFamily do
  def self.server(env)
    ENV[env] ? false : "set #{env} to run this family against a real database server"
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    @took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  let(:conn) { RacServerSpecRecord.connection }
  let(:family) { described_class.of(conn) }

  def connect(env)
    stub_const("RacServerSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RacServerSpecRecord.establish_connection(ENV.fetch(env))
    RacServerSpecRecord.connection.tap do |c|
      c.execute("DROP VIEW IF EXISTS rac_server_view")
      c.execute("DROP TABLE IF EXISTS rac_server_rows")
      c.execute("CREATE TABLE rac_server_rows (id int)")
      c.execute("INSERT INTO rac_server_rows VALUES (1), (2), (3)")
      c.execute("CREATE VIEW rac_server_view AS SELECT id FROM rac_server_rows")
    end
  end

  # A second session on the same server, to hold a lock the first one waits on.
  def other_session(env)
    stub_const("RacServerLockRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RacServerLockRecord.establish_connection(ENV.fetch(env))
    RacServerLockRecord.connection_pool.checkout
  end

  after do
    RacServerLockRecord.remove_connection if defined?(RacServerLockRecord)
    if defined?(RacServerSpecRecord)
      RacServerSpecRecord.connection.execute("DROP VIEW IF EXISTS rac_server_view")
      RacServerSpecRecord.connection.execute("DROP TABLE IF EXISTS rac_server_rows")
      RacServerSpecRecord.remove_connection
    end
  end

  shared_examples "a guarded database server" do
    it "reads rows" do
      expect(family.read_only(conn, "WITH t AS (SELECT id FROM rac_server_rows) SELECT id FROM t ORDER BY id", timeout: 5).rows.flatten.map(&:to_i))
        .to eq([ 1, 2, 3 ])
    end

    it "refuses a write" do
      expect { family.read_only(conn, "INSERT INTO rac_server_rows VALUES (9)", timeout: 5) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(conn.select_value("SELECT COUNT(*) FROM rac_server_rows").to_i).to eq(3)
    end

    it "reads an error about a missing column named timeout as an SQL error" do
      expect { family.read_only(conn, "SELECT timeout FROM rac_server_rows", timeout: 5) }
        .to raise_error(ActiveRecord::StatementInvalid) { |e| expect(e).not_to be_a(described_class::TimedOut) }
    end

    it "explains a statement" do
      expect(family.explain(conn, "SELECT id FROM rac_server_rows", timeout: 5)[:raw]).to include("rac_server_rows")
    end

    it "lists every base table's columns in one read, as Rails lists them" do
      listed = family.relation_columns(conn)

      expect(listed.fetch("rac_server_rows")).to eq(conn.columns("rac_server_rows").map(&:name))
      expect(listed.keys).to match_array(conn.tables)
    end

    it "sizes and counts base tables only" do
      sized = family.table_sizes(conn).map { |r| r[:name] }
      counted = family.row_estimates(conn).map { |r| r[:table] }

      expect([ sized, counted ]).to all(include("rac_server_rows"))
      expect(sized + counted).not_to include("rac_server_view")
    end
  end

  shared_examples "a MySQL-family database server" do |env|
    let(:env) { env }

    it_behaves_like "a guarded database server"

    it "bounds a WITH statement" do
      elapsed do
        expect { family.read_only(conn, "WITH t AS (SELECT id FROM rac_server_rows) SELECT id FROM t WHERE SLEEP(1) = 0", timeout: 0.5) }
          .to raise_error(described_class::TimedOut)
      end
      expect(@took).to be < 2
    end

    it "bounds a statement when the timeout is zero or under a millisecond" do
      [ 0, 0.0004 ].each do |timeout|
        expect { family.read_only(conn, "SELECT id FROM rac_server_rows WHERE SLEEP(1) = 0", timeout: timeout) }
          .to raise_error(described_class::TimedOut), timeout.to_s
      end
    end

    it "ends a read that waits on another session's table lock, and puts the session's own limits back" do
      limits = "SELECT @@SESSION.lock_wait_timeout, @@SESSION.#{conn.mariadb? ? "max_statement_time" : "max_execution_time"}"
      before = conn.select_rows(limits)
      locker = other_session(env)
      locker.execute("LOCK TABLES rac_server_rows WRITE")

      # EXPLAIN is outside what MySQL's max_execution_time covers, so lock_wait_timeout ends its wait.
      [ "SELECT id FROM rac_server_rows", "EXPLAIN SELECT id FROM rac_server_rows" ].each do |sql|
        elapsed { expect { family.bounded(conn, timeout: 0.5) { conn.select_all(sql) } }.to raise_error(described_class::TimedOut), sql }
        expect(@took).to be < 3
        elapsed { expect { family.explain(conn, "SELECT id FROM rac_server_rows", timeout: 0.5) }.to raise_error(described_class::TimedOut) }
        expect(@took).to be < 3
      end
      expect(conn.select_rows(limits)).to eq(before)
    ensure
      locker&.execute("UNLOCK TABLES")
    end

    it "reads the view definitions and generated column expressions the rule checks" do
      conn.execute("ALTER TABLE rac_server_rows ADD COLUMN twice int AS (id * 2) VIRTUAL")

      expect(family.view_definitions(conn).fetch("rac_server_view")).to match(/select .*rac_server_rows.*id/i)
      expect(family.generated_columns(conn).fetch("rac_server_rows").keys).to eq([ "twice" ])
      expect(family.generated_columns(conn).dig("rac_server_rows", "twice")).to match(/id.*\*.*2/)
    end
  end

  describe "PostgreSQL", skip: server("RAC_TEST_PG_URL") do
    before { connect("RAC_TEST_PG_URL") }

    it_behaves_like "a guarded database server"

    it "bounds a statement" do
      elapsed { expect { family.read_only(conn, "SELECT pg_sleep(3)", timeout: 0.5) }.to raise_error(described_class::TimedOut) }
      expect(@took).to be < 2
    end

    it "bounds EXPLAIN ANALYZE" do
      elapsed { expect { family.explain(conn, "SELECT pg_sleep(3)", timeout: 0.5) }.to raise_error(described_class::TimedOut) }
      expect(@took).to be < 2
    end

    it "bounds a statement when the timeout is zero or under a millisecond" do
      [ 0, 0.0004 ].each do |timeout|
        expect { family.read_only(conn, "SELECT pg_sleep(1)", timeout: timeout) }.to raise_error(described_class::TimedOut), timeout.to_s
      end
    end

    it "ends a block of reads that waits on another session's lock, at the timeout" do
      locker = other_session("RAC_TEST_PG_URL")
      locker.execute("BEGIN")
      locker.execute("LOCK TABLE rac_server_rows IN ACCESS EXCLUSIVE MODE")

      elapsed { expect { family.bounded(conn, timeout: 0.5) { conn.select_all("SELECT id FROM rac_server_rows") } }.to raise_error(described_class::TimedOut) }
      expect(@took).to be < 3
      expect(family.bounded(conn, timeout: 0.5) { family.relation_columns(conn).fetch("rac_server_rows") }).to eq(%w[id])
    ensure
      locker&.execute("ROLLBACK")
    end

    it "raises planning's SQL error" do
      expect { family.plan(conn, "SELECT nope FROM rac_server_rows", timeout: 5) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "leaves views to the plan and reads generated column expressions" do
      conn.execute("ALTER TABLE rac_server_rows ADD COLUMN twice int GENERATED ALWAYS AS (id * 2) STORED")

      expect(family.view_definitions(conn)).to be_nil
      expect(family.generated_columns(conn).fetch("rac_server_rows")).to eq("twice" => "(id * 2)")
    end

    it "plans without running" do
      expect(family.plan(conn, "SELECT id FROM rac_server_rows", timeout: 5)).to include("Node Type" => "Seq Scan")
    end

    it "traces a renamed result column to its table column" do
      sql = "SELECT 1 AS one, id AS n FROM rac_server_rows"
      expect(family.column_sources(conn, sql, plan: family.plan(conn, sql, timeout: 5)).uniq).to eq([ [ 1, "id", "rac_server_rows" ] ])
    end

    it "reports each index with its table and scan count" do
      conn.execute("CREATE INDEX rac_server_rows_id_idx ON rac_server_rows (id)")

      expect(family.index_usage(conn)).to include({ table: "rac_server_rows", index: "rac_server_rows_id_idx", scans: 0 })
    end
  end

  describe "MySQL", skip: server("RAC_TEST_MYSQL_URL") do
    before { connect("RAC_TEST_MYSQL_URL") }

    it_behaves_like "a MySQL-family database server", "RAC_TEST_MYSQL_URL"

    it "bounds EXPLAIN ANALYZE" do
      elapsed { family.read_only(conn, "EXPLAIN ANALYZE SELECT id FROM rac_server_rows WHERE SLEEP(1) = 0", timeout: 0.5) }
      expect(@took).to be < 2
    end

    it "restores the session's own max_execution_time, also after a timeout" do
      conn.execute("SET SESSION max_execution_time = 4321")
      family.read_only(conn, "SELECT 1", timeout: 5)
      expect { family.read_only(conn, "SELECT id FROM rac_server_rows WHERE SLEEP(1) = 0", timeout: 0.5) }.to raise_error(described_class::TimedOut)

      expect(conn.select_value("SELECT @@SESSION.max_execution_time").to_i).to eq(4321)
    end
  end

  describe "MariaDB", skip: server("RAC_TEST_MARIADB_URL") do
    before { connect("RAC_TEST_MARIADB_URL") }

    it_behaves_like "a MySQL-family database server", "RAC_TEST_MARIADB_URL"
  end
end
