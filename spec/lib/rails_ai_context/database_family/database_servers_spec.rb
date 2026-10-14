# frozen_string_literal: true

require "spec_helper"

# Runs each family against a real database server. Each group runs only when its URL is set,
# with the driver from gemfiles/database_servers.gemfile (see CONTRIBUTING.md).
RSpec.describe RailsAiContext::DatabaseFamily do
  def self.server(env)
    ENV[env] ? false : "set #{env} to run this family against a real database server"
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

  # Ends the first session from a second one while the block's statement runs. The dead
  # connection leaves the pool, so the cleanup after the example gets a new one.
  def dropping_the_connection(env, find_id, drop)
    id = conn.select_value(find_id)
    second_session(ENV.fetch(env)) do |other|
      dropper = Thread.new { sleep 0.5 and other.execute(format(drop, id)) }
      yield
    ensure
      dropper&.join
    end
  ensure
    RacServerSpecRecord.connection_pool.disconnect!
  end

  after do
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
      expect(listed.keys.grep_v(/\./)).to match_array(conn.tables)
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
      took = seconds do
        expect { family.read_only(conn, "WITH t AS (SELECT id FROM rac_server_rows) SELECT id FROM t WHERE SLEEP(1) = 0", timeout: 0.5) }
          .to raise_error(described_class::TimedOut)
      end
      expect(took).to be < 2
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

      second_session(ENV.fetch(env)) do |locker|
        locker.execute("LOCK TABLES rac_server_rows WRITE")
        # EXPLAIN is outside what MySQL's max_execution_time covers, so lock_wait_timeout ends its wait.
        waits = {
          "a read" => -> { family.bounded(conn, timeout: 0.5) { conn.select_all("SELECT id FROM rac_server_rows") } },
          "a bare EXPLAIN" => -> { family.bounded(conn, timeout: 0.5) { conn.select_all("EXPLAIN SELECT id FROM rac_server_rows") } },
          "the family's explain" => -> { family.explain(conn, "SELECT id FROM rac_server_rows", timeout: 0.5) }
        }
        waits.each do |name, wait|
          expect(seconds { expect(&wait).to raise_error(described_class::TimedOut), name }).to be < 3, name
        end
      end
      expect(conn.select_rows(limits)).to eq(before)
    end

    it "raises a connection the server dropped while the statement ran as itself" do
      dropping_the_connection(env, "SELECT CONNECTION_ID()", "KILL CONNECTION %d") do
        expect { family.read_only(conn, "SELECT id FROM rac_server_rows WHERE SLEEP(5) = 0", timeout: 5) }
          .to raise_error(ActiveRecord::ActiveRecordError) { |e| expect(e).not_to be_a(described_class::TimedOut) }
      end
    end

    it "sends no statement on a connection that was replaced after the session was guarded, and raises the lost connection" do
      id = conn.select_value("SELECT CONNECTION_ID()")
      sent = []
      second_session(ENV.fetch(env)) do |other|
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          sent << payload[:sql]
          other.execute("KILL CONNECTION #{id}") if payload[:sql] == "SET TRANSACTION READ ONLY"
        end
        took = seconds do
          expect { family.read_only(conn, "SELECT id FROM rac_server_rows WHERE SLEEP(3) = 0", timeout: 0.5) }
            .to raise_error(ActiveRecord::ActiveRecordError) { |e| expect(e).not_to be_a(described_class::TimedOut) }
        end
        expect(took).to be < 2
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      expect(sent.grep(/SLEEP/)).to eq([])
    ensure
      RacServerSpecRecord.connection_pool.disconnect!
    end

    it "refuses a guarded read inside a transaction that is already open, bounds a block of reads there, and leaves it open" do
      conn.transaction do
        conn.execute("INSERT INTO rac_server_rows VALUES (4)")
        expect { family.read_only(conn, "SELECT id FROM rac_server_rows", timeout: 5) }
          .to raise_error(described_class::Unsupported, /already open/)
        expect(family.bounded(conn, timeout: 5) { conn.select_value("SELECT COUNT(*) FROM rac_server_rows") }.to_i).to eq(4)
        conn.execute("INSERT INTO rac_server_rows VALUES (5)")
      end

      expect(conn.select_value("SELECT COUNT(*) FROM rac_server_rows").to_i).to eq(5)
    end

    # The server commits an open transaction when it reads a BEGIN, so none may be sent here.
    it "refuses a guarded read inside a transaction the app opened with a raw BEGIN, bounds a block of reads there, and leaves it open" do
      conn.execute("BEGIN")
      conn.execute("INSERT INTO rac_server_rows VALUES (4)")
      expect { family.read_only(conn, "SELECT id FROM rac_server_rows", timeout: 5) }
        .to raise_error(described_class::Unsupported, /already open/)
      expect(family.bounded(conn, timeout: 5) { conn.select_value("SELECT COUNT(*) FROM rac_server_rows") }.to_i).to eq(4)
      expect { family.bounded(conn, timeout: 0.5) { conn.select_all("SELECT id FROM rac_server_rows WHERE SLEEP(1) = 0") } }
        .to raise_error(described_class::TimedOut)
      conn.execute("INSERT INTO rac_server_rows VALUES (5)")
      conn.execute("ROLLBACK")

      expect(conn.select_value("SELECT COUNT(*) FROM rac_server_rows").to_i).to eq(3)
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
      took = seconds { expect { family.read_only(conn, "SELECT pg_sleep(3)", timeout: 0.5) }.to raise_error(described_class::TimedOut) }
      expect(took).to be < 2
    end

    it "bounds EXPLAIN ANALYZE" do
      took = seconds { expect { family.explain(conn, "SELECT pg_sleep(3)", timeout: 0.5) }.to raise_error(described_class::TimedOut) }
      expect(took).to be < 2
    end

    it "bounds a statement when the timeout is zero or under a millisecond" do
      [ 0, 0.0004 ].each do |timeout|
        expect { family.read_only(conn, "SELECT pg_sleep(1)", timeout: timeout) }.to raise_error(described_class::TimedOut), timeout.to_s
      end
    end

    it "ends a block of reads that waits on another session's lock, at the timeout" do
      second_session(ENV.fetch("RAC_TEST_PG_URL")) do |locker|
        locker.execute("BEGIN")
        locker.execute("LOCK TABLE rac_server_rows IN ACCESS EXCLUSIVE MODE")

        took = seconds do
          expect { family.bounded(conn, timeout: 0.5) { conn.select_all("SELECT id FROM rac_server_rows") } }.to raise_error(described_class::TimedOut)
        end
        expect(took).to be < 3
        expect(family.bounded(conn, timeout: 0.5) { family.relation_columns(conn).fetch("rac_server_rows") }).to eq(%w[id])
      end
    end

    it "raises the timeout when the trace of a result column to its table column waits on a lock" do
      sql = "SELECT * FROM (SELECT * FROM rac_server_view OFFSET 0) x"
      plan = family.plan(conn, sql, timeout: 5)
      second_session(ENV.fetch("RAC_TEST_PG_URL")) do |locker|
        locker.execute("BEGIN")
        locker.execute("LOCK TABLE rac_server_rows IN ACCESS EXCLUSIVE MODE")

        expect { family.bounded(conn, timeout: 0.3) { family.column_sources(conn, sql, plan: plan) } }.to raise_error(described_class::TimedOut)
      end
    end

    it "reads a lock wait the session's own lock_timeout ended as the timeout" do
      conn.execute("SET lock_timeout = '200ms'")
      second_session(ENV.fetch("RAC_TEST_PG_URL")) do |locker|
        locker.execute("BEGIN")
        locker.execute("LOCK TABLE rac_server_rows IN ACCESS EXCLUSIVE MODE")

        expect { family.read_only(conn, "SELECT id FROM rac_server_rows", timeout: 5) }.to raise_error(described_class::TimedOut)
      end
    end

    it "raises a connection the server dropped while the statement ran as itself" do
      dropping_the_connection("RAC_TEST_PG_URL", "SELECT pg_backend_pid()", "SELECT pg_terminate_backend(%d)") do
        expect { family.read_only(conn, "SELECT pg_sleep(5)", timeout: 5) }
          .to raise_error(ActiveRecord::ActiveRecordError) { |e| expect(e).not_to be_a(described_class::TimedOut) }
      end
    end

    it "guards a read inside a transaction that is already open, and leaves the transaction as it found it" do
      settings = "SELECT current_setting('transaction_read_only'), current_setting('statement_timeout')"
      conn.transaction do
        conn.execute("INSERT INTO rac_server_rows VALUES (4)")
        before = conn.select_rows(settings)

        expect { family.read_only(conn, "INSERT INTO rac_server_rows VALUES (9)", timeout: 5) }.to raise_error(ActiveRecord::StatementInvalid)
        expect { family.read_only(conn, "SELECT pg_sleep(3)", timeout: 0.5) }.to raise_error(described_class::TimedOut)
        expect(family.read_only(conn, "SELECT count(*) FROM rac_server_rows", timeout: 5).rows.flatten.map(&:to_i)).to eq([ 4 ])
        expect(family.bounded(conn, timeout: 5) { conn.select_value("SELECT current_setting('transaction_read_only')") }).to eq("on")

        expect(conn.select_rows(settings)).to eq(before)
        conn.execute("INSERT INTO rac_server_rows VALUES (5)")
      end

      expect(conn.select_value("SELECT count(*) FROM rac_server_rows").to_i).to eq(5)
    end

    it "guards a read inside a transaction the app opened with a raw BEGIN, and leaves it open with its writes" do
      conn.execute("BEGIN")
      conn.execute("INSERT INTO rac_server_rows VALUES (4)")

      expect { family.read_only(conn, "INSERT INTO rac_server_rows VALUES (9)", timeout: 5) }.to raise_error(ActiveRecord::StatementInvalid)
      expect { family.read_only(conn, "SELECT pg_sleep(3)", timeout: 0.5) }.to raise_error(described_class::TimedOut)
      expect(family.read_only(conn, "SELECT count(*) FROM rac_server_rows", timeout: 5).rows.flatten.map(&:to_i)).to eq([ 4 ])
      expect(family.bounded(conn, timeout: 5) { conn.select_value("SELECT current_setting('transaction_read_only')") }).to eq("on")

      expect(conn.select_rows("SELECT current_setting('transaction_read_only'), current_setting('statement_timeout')")).to eq([ %w[off 0] ])
      conn.execute("INSERT INTO rac_server_rows VALUES (5)")
      conn.execute("COMMIT")
      expect(conn.select_value("SELECT count(*) FROM rac_server_rows").to_i).to eq(5)
    end

    it "raises a statement another session canceled as the error it is, and a timeout as the timeout" do
      pid = conn.select_value("SELECT pg_backend_pid()")
      second_session(ENV.fetch("RAC_TEST_PG_URL")) do |other|
        canceler = Thread.new { sleep 0.5 and other.execute("SELECT pg_cancel_backend(#{pid})") }
        expect { family.read_only(conn, "SELECT pg_sleep(5)", timeout: 5) }
          .to raise_error(ActiveRecord::StatementInvalid, /user request/) { |e| expect(e).not_to be_a(described_class::TimedOut) }
      ensure
        canceler&.join
      end
      expect { family.read_only(conn, "SELECT pg_sleep(3)", timeout: 0.5) }.to raise_error(described_class::TimedOut)
    end

    it "raises planning's SQL error" do
      expect { family.plan(conn, "SELECT nope FROM rac_server_rows", timeout: 5) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "reads the views with the ones the plan traces named, a relation under its schema too, and generated column expressions" do
      conn.execute("ALTER TABLE rac_server_rows ADD COLUMN twice int GENERATED ALWAYS AS (id * 2) STORED")
      conn.execute("CREATE MATERIALIZED VIEW rac_server_stored AS SELECT id AS n FROM rac_server_rows")

      # Before PostgreSQL 16 pg_get_viewdef qualifies each column with its table.
      table = conn.database_version < 16_00_00 ? "rac_server_rows." : ""
      view, stored = "SELECT #{table}id FROM rac_server_rows;", "SELECT #{table}id AS n FROM rac_server_rows;"
      expect(family.view_definitions(conn).transform_values(&:squish)).to include(
        "rac_server_view" => view, "public.rac_server_view" => view, "rac_server_stored" => stored, "public.rac_server_stored" => stored
      )
      expect(family.traced_views(conn)).to include("rac_server_view")
      expect(family.traced_views(conn)).not_to include("rac_server_stored")
      expect(family.relation_columns(conn).slice("rac_server_stored", "public.rac_server_stored", "public.rac_server_rows"))
        .to eq("rac_server_stored" => %w[n], "public.rac_server_stored" => %w[n], "public.rac_server_rows" => %w[id twice])
      expect(family.generated_columns(conn).fetch("rac_server_rows")).to eq("twice" => "(id * 2)")
    ensure
      conn.execute("DROP MATERIALIZED VIEW IF EXISTS rac_server_stored")
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
      expect(seconds { family.read_only(conn, "EXPLAIN ANALYZE SELECT id FROM rac_server_rows WHERE SLEEP(1) = 0", timeout: 0.5) }).to be < 2
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
