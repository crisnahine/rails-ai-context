# frozen_string_literal: true

require "spec_helper"

# rails_query's secret column checks against a real PostgreSQL, where the plan
# checks and provenance redaction run. Runs only when RAC_TEST_PG_URL is set.
RSpec.describe RailsAiContext::Tools::Query, skip: (ENV["RAC_TEST_PG_URL"] ? false : "set RAC_TEST_PG_URL to run rails_query against PostgreSQL") do
  let(:conn) { RacPgQueryRecord.connection }

  before do
    described_class.reset_cache!
    stub_const("RacPgQueryRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RacPgQueryRecord.establish_connection(ENV.fetch("RAC_TEST_PG_URL"))
    conn.execute("DROP VIEW IF EXISTS rac_pg_renamed")
    conn.execute("DROP TABLE IF EXISTS rac_pg_accounts")
    conn.execute("CREATE TABLE rac_pg_accounts (id int, email text, salt text, api_token text, shadow text GENERATED ALWAYS AS (salt) STORED)")
    conn.execute("INSERT INTO rac_pg_accounts VALUES (1, 'a@example.com', 'salt-value', 'token-value')")
    conn.execute("CREATE VIEW rac_pg_renamed AS SELECT id, salt AS harmless FROM rac_pg_accounts")
    allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
    allow(described_class).to receive(:cached_context).and_return({})
  end

  after do
    conn.execute("DROP VIEW IF EXISTS rac_pg_renamed")
    conn.execute("DROP TABLE IF EXISTS rac_pg_accounts")
    RacPgQueryRecord.remove_connection
    RailsAiContext.configuration.query_timeout = 5
  end

  def run(sql)
    RailsAiContext::RunCache.around { described_class.call(sql: sql) }
  end

  it "refuses a statement naming a column Redaction's secret words cover" do
    response = run("SELECT upper(salt) AS s FROM rac_pg_accounts")
    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("`salt`")
  end

  it "refuses a whole-row read of a relation holding a secret column" do
    response = run("SELECT row_to_json(a.*) FROM rac_pg_accounts a")
    expect(response.error?).to be(true)
  end

  it "redacts every secret column a wildcard returns" do
    text = run("SELECT * FROM rac_pg_accounts").content.first[:text]
    expect(text).to include("a@example.com")
    expect(text).not_to include("salt-value")
    expect(text).not_to include("token-value")
  end

  it "redacts a secret column a view renamed" do
    text = run("SELECT * FROM rac_pg_renamed").content.first[:text]
    expect(text).not_to include("salt-value")
    expect(text).to include("[FILTERED]")
  end

  def refused(statements, start)
    statements.each do |sql|
      response = run(sql)
      expect(response.error?).to be(true), sql
      expect(response.content.first[:text]).to start_with(start), sql
      expect(response.content.first[:text]).not_to include("salt-value", "token-value"), sql
    end
  end

  it "refuses a column-alias list in every spelling the server reads" do
    body = "(SELECT * FROM rac_pg_accounts)"
    refused([
      "SELECT * FROM rac_pg_accounts AS t (a, b, c, d, e)", "SELECT * FROM rac_pg_accounts t (a, b, c, d, e)", "SELECT * FROM rac_pg_accounts t (a)",
      %(SELECT * FROM "rac_pg_accounts" "T" ("A", "b", c, d, e)), "SELECT * FROM public.rac_pg_accounts t (a, b, c, d, e)",
      "SELECT * FROM ONLY rac_pg_accounts t (a, b, c, d, e)", "SELECT * FROM rac_pg_accounts * t (a, b, c, d, e)",
      "SELECT * FROM #{body} AS t (a, b, c, d, e)", "SELECT * FROM #{body} t (a, b, c, d, e)", "SELECT * FROM #{body}t(a,b,c,d,e)",
      "SELECT * FROM (TABLE rac_pg_accounts) t (a, b, c, d, e)", "SELECT * FROM generate_series(1, 1) g, LATERAL #{body} t (a, b, c, d, e)",
      "SELECT * FROM (rac_pg_accounts a CROSS JOIN generate_series(1, 1) g) AS j (a, b, c, d, e, f)",
      "WITH t (a, b, c, d, e) AS #{body} SELECT * FROM t", %(WITH t ("a", "b", "c", "d", "e") AS #{body} SELECT * FROM t),
      %(WITH t (U&"a", b, c, d, e) AS #{body} SELECT * FROM t), "WITH t (\u00e9, b, c, d, e) AS #{body} SELECT * FROM t",
      "WITH t (a, b, c, d, e) AS MATERIALIZED #{body} SELECT * FROM t", "WITH t (a, b, c, d, e) AS NOT MATERIALIZED #{body} SELECT * FROM t",
      "WITH t(a,b,c,d,e)AS(SELECT*FROM rac_pg_accounts)SELECT*FROM t", "WITH RECURSIVE t (a, b, c, d, e) AS #{body} SELECT * FROM t"
    ], "Blocked: a column-alias list")
  end

  it "filters a secret column under a column-alias list the text check does not read" do
    [ "SELECT * FROM generate_series(1, 1) g, rac_pg_accounts t (a, b, c, d, e)",
      "SELECT * FROM (rac_pg_accounts a CROSS JOIN generate_series(1, 1) g) j (a, b, c, d, e, f)" ].each do |sql|
      text = run(sql).content.first[:text]
      expect(text).to include("a@example.com", "[FILTERED]"), sql
      expect(text).not_to include("salt-value", "token-value"), sql
    end
  end

  it "refuses a whole row and a compared row under a quoted alias" do
    refused([ %(SELECT row_to_json("X y") FROM rac_pg_accounts "X y"), %(SELECT "T" FROM rac_pg_accounts AS "T"),
              %(SELECT "X y"::text FROM rac_pg_accounts "X y"), %(SELECT id FROM rac_pg_accounts "X y" ORDER BY "X y") ],
            "Blocked: the query serialises a whole row of `rac_pg_accounts`")
    refused([ %(SELECT (1, 'a@example.com', 'salt-valud', 'x', 'y') < (SELECT * FROM rac_pg_accounts AS "X y") AS o) ],
            "Blocked: the query passes the secret column `salt` through")
  end

  it "filters a quoted mixed-case secret column in place, and refuses what would rename or compare it" do
    conn.execute("DROP TABLE IF EXISTS rac_pg_mixed")
    conn.execute(%(CREATE TABLE rac_pg_mixed (id int, email text, "Salt" text)))
    conn.execute("INSERT INTO rac_pg_mixed VALUES (1, 'a@example.com', 'salt-value')")

    [ "SELECT * FROM rac_pg_mixed", "SELECT m.* FROM rac_pg_mixed m", "SELECT * FROM (SELECT * FROM rac_pg_mixed OFFSET 0) x" ].each do |sql|
      response = run(sql)
      expect(response.error?).to be(false), sql
      expect(response.content.first[:text]).to include("a@example.com", "[FILTERED]"), sql
      expect(response.content.first[:text]).not_to include("salt-value"), sql
    end
    refused([ %(SELECT "Salt" AS x FROM rac_pg_mixed), "SELECT (1, 'a@example.com', 'salt-valud') < (SELECT * FROM rac_pg_mixed) AS o",
              "SELECT row_to_json(m) FROM rac_pg_mixed m", "WITH c AS MATERIALIZED (SELECT * FROM rac_pg_mixed) SELECT * FROM c" ], "Blocked: ")
  ensure
    conn.execute("DROP TABLE IF EXISTS rac_pg_mixed")
  end

  it "filters both columns of a name a join returns twice, at the top and through a subquery" do
    [ "SELECT * FROM rac_pg_accounts a JOIN rac_pg_accounts b ON true",
      "SELECT * FROM (SELECT * FROM rac_pg_accounts a JOIN rac_pg_accounts b ON true) x" ].each do |sql|
      text = run(sql).content.first[:text]
      expect(text).to include("a@example.com"), sql
      expect(text).not_to include("salt-value", "token-value"), sql
    end
  end

  it "refuses a function that returns a whole table, and the statistics and other sessions' statements, however named" do
    conn.execute("ANALYZE rac_pg_accounts")
    refused([ "SELECT table_to_xml('rac_pg_accounts', true, false, '')", "SELECT query_to_xml('select * from rac_pg_accounts', true, false, '')" ],
            "Blocked: function ")
    refused([ "SELECT * FROM pg_stats WHERE tablename = 'rac_pg_accounts'", "SELECT stavalues1 FROM pg_statistic",
              %(SELECT * FROM U&"pg\\005Fstats" WHERE tablename = 'rac_pg_accounts'), "SELECT query FROM pg_stat_activity",
              %(SELECT query FROM U&"pg\\005Fstat\\005Factivity") ], "Blocked: `")
  end

  it "reads the schema once for the whole call" do
    runtime = RailsAiContext::DatabaseFamily::PostgresqlRuntime
    allow(runtime).to receive(:relation_columns).and_call_original
    run("SELECT * FROM rac_pg_accounts")
    expect(runtime).to have_received(:relation_columns).once
  end

  it "runs a locking phrase inside a literal and refuses the clause itself" do
    expect(run("SELECT id FROM rac_pg_accounts WHERE email LIKE '%ready for update%'").error?).to be(false)
    expect(run("SELECT id FROM rac_pg_accounts FOR UPDATE").content.first[:text]).to include("FOR UPDATE/SHARE")
  end

  it "holds LIMIT ALL and LIMIT NULL to the row limit in the statement it sends" do
    sent = []
    allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:read_only).and_wrap_original { |m, c, sql, t| sent << sql; m.call(c, sql, t) }
    %w[ALL NULL].each do |no_limit|
      text = described_class.call(sql: "SELECT g FROM generate_series(1, 5) g LIMIT #{no_limit}", limit: 2).content.first[:text]
      expect(text).to include("2 rows returned").and include("2 rows shown; the query returned more")
    end
    expect(sent.grep(/\ASELECT/)).to eq([ "SELECT g FROM generate_series(1, 5) g LIMIT 3" ] * 2)
  end

  it "refuses a statement naming a generated column that reads a secret column" do
    response = run("SELECT shadow AS s FROM rac_pg_accounts")
    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("`shadow` is a generated column that reads `salt`")
  end

  it "answers a timeout as an error, for a query and for its EXPLAIN" do
    RailsAiContext.configuration.query_timeout = 1
    [ false, true ].each do |explain|
      response = described_class.call(sql: "SELECT pg_sleep(3)", explain: explain)
      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to start_with("Query exceeded 1 second timeout")
    end
  end

  # The lock holds planning past the timeout and is gone before the statement's own timeout would end.
  # It is taken after the schema read, which Rails runs with no timeout.
  it "runs nothing when another connection holds a lock on the table past the timeout" do
    RailsAiContext.configuration.query_timeout = 1
    stub_const("RacPgLockRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RacPgLockRecord.establish_connection(ENV.fetch("RAC_TEST_PG_URL"))
    locker = RacPgLockRecord.connection_pool.checkout

    [ "SELECT row_to_json(a) FROM rac_pg_accounts a", "WITH a AS (SELECT * FROM rac_pg_accounts) SELECT row_to_json(a) FROM a",
      "EXPLAIN ANALYZE SELECT row_to_json(a) FROM rac_pg_accounts a" ].each do |sql|
      response = RailsAiContext::RunCache.around do
        RailsAiContext::SecretColumns.for(conn, context: {})
        locker.execute("BEGIN")
        locker.execute("LOCK TABLE rac_pg_accounts IN ACCESS EXCLUSIVE MODE")
        release = Thread.new { sleep 1.5 and locker.execute("ROLLBACK") }
        described_class.call(sql: sql).tap { release.join }
      end

      expect(response.error?).to be(true), sql
      expect(response.content.first[:text]).to start_with("Query exceeded 1 second timeout")
      expect(response.content.first[:text]).not_to include("salt-value", "token-value")
    end
  ensure
    RacPgLockRecord.remove_connection if defined?(RacPgLockRecord)
  end

  it "answers the timeout inside twice query_timeout when the lock is held before the call starts and never let go" do
    RailsAiContext.configuration.query_timeout = 1
    stub_const("RacPgLockRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RacPgLockRecord.establish_connection(ENV.fetch("RAC_TEST_PG_URL"))
    locker = RacPgLockRecord.connection_pool.checkout
    locker.execute("BEGIN")
    locker.execute("LOCK TABLE rac_pg_accounts IN ACCESS EXCLUSIVE MODE")

    [ "SELECT id FROM rac_pg_accounts", "SELECT 1 AS one" ].each do |sql|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = run(sql)
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(response.error?).to be(true), sql
      expect(response.content.first[:text]).to start_with("Query exceeded 1 second timeout")
      expect(took).to be_between(0.9, 2.5), sql
    end
  ensure
    RacPgLockRecord.remove_connection if defined?(RacPgLockRecord)
  end

  describe "a database no connection reaches" do
    def configure(entries)
      configurations = ActiveRecord::DatabaseConfigurations.new(
        Rails.env => { "primary" => ActiveRecord::Base.connection_db_config.configuration_hash }.merge(entries)
      )
      allow(ActiveRecord::Base).to receive(:configurations).and_return(configurations)
    end

    def at_port(port, params = "")
      uri = URI(ENV.fetch("RAC_TEST_PG_URL"))
      uri.port = port
      "#{uri}#{params}"
    end

    def answer(name)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = RailsAiContext::RunCache.around { described_class.call(sql: "SELECT 1", database: name) }
      @took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(response.error?).to be(true)
      response.content.first[:text]
    end

    it "names a database at a port nothing listens on, and says to start its server" do
      configure("closed" => { "url" => at_port(1, "?connect_timeout=2") })

      expect(answer("closed")).to start_with("The closed database cannot be reached: ")
        .and end_with("Start its server, or fix its settings in config/database.yml.")
      expect(@took).to be < 4
    end

    it "names a database its server does not hold, and says to create it" do
      configure("absent" => { "url" => ENV.fetch("RAC_TEST_PG_URL").sub(%r{/[^/?]+(\?.*)?\z}, "/rac_no_such_database") })

      expect(answer("absent")).to start_with("The absent database cannot be reached: ")
        .and include("rac_no_such_database").and end_with("Run `bin/rails db:create` or `bin/rails db:prepare` to create it.")
    end

    # libpq waits two seconds at least, whatever smaller connect_timeout it is given.
    it "gives up on a server that accepts the connection and never answers, with no connect_timeout in the entry" do
      RailsAiContext.configuration.query_timeout = 1
      silent = TCPServer.new("127.0.0.1", 0)
      held = []
      accepting = Thread.new { loop { held << silent.accept } }
      configure("silent" => { "url" => at_port(silent.addr[1]) })

      expect(answer("silent")).to start_with("The silent database cannot be reached: ")
      expect(@took).to be < 8
    ensure
      accepting&.kill
      held&.each(&:close)
      silent&.close
    end
  end

  it "answers an SQL error from planning as the SQL error" do
    response = run("SELECT nope FROM rac_pg_accounts")
    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to start_with("SQL error:").and include("nope")
  end

  it "runs SHOW, which has no plan" do
    expect(run("SHOW server_version").error?).to be(false)
  end

  it "flags a failing EXPLAIN as an error" do
    expect(described_class.call(sql: "SELECT nope FROM rac_pg_accounts", explain: true).error?).to be(true)
  end
end
