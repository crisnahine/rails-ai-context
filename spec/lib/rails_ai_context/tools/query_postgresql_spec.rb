# frozen_string_literal: true

require "spec_helper"
require "socket"
require "uri"

# rails_query's secret column checks against a real PostgreSQL, where the plan
# checks and provenance redaction run. Runs only when RAC_TEST_PG_URL is set.
RSpec.describe RailsAiContext::Tools::Query, skip: (ENV["RAC_TEST_PG_URL"] ? false : "set RAC_TEST_PG_URL to run rails_query against PostgreSQL") do
  let(:conn) { RacPgQueryRecord.connection }

  before do
    described_class.reset_cache!
    stub_const("RacPgQueryRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RacPgQueryRecord.establish_connection(ENV.fetch("RAC_TEST_PG_URL"))
    conn.execute("DROP TABLE IF EXISTS rac_pg_accounts CASCADE")
    conn.execute("CREATE TABLE rac_pg_accounts (id int, email text, salt text, api_token text, shadow text GENERATED ALWAYS AS (salt) STORED)")
    conn.execute("INSERT INTO rac_pg_accounts VALUES (1, 'a@example.com', 'salt-value', 'token-value')")
    conn.execute("CREATE VIEW rac_pg_renamed AS SELECT id, salt AS harmless FROM rac_pg_accounts")
    allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
    allow(described_class).to receive(:cached_context).and_return({})
  end

  after do
    conn.execute("DROP TABLE IF EXISTS rac_pg_accounts CASCADE")
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
      expect(response.content.first[:text]).to start_with(start), "#{sql}: #{response.content.first[:text]}"
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

  it "refuses a whole row under an alias that differs from another alias by case alone" do
    conn.execute("DROP TABLE IF EXISTS rac_pg_plain")
    conn.execute("CREATE TABLE rac_pg_plain (id int)")
    conn.execute("INSERT INTO rac_pg_plain VALUES (1)")
    twins = %(FROM rac_pg_accounts t LEFT JOIN rac_pg_plain "T" ON true)

    refused([ "SELECT row_to_json(t) AS j #{twins}", "SELECT t::text AS j #{twins}", "SELECT (t.*)::text AS j #{twins}",
              %(SELECT row_to_json(rac_pg_accounts) AS j FROM rac_pg_accounts LEFT JOIN rac_pg_plain "RAC_PG_ACCOUNTS" ON true),
              "SELECT EXISTS (SELECT 1 #{twins} WHERE t::text LIKE '%token-v%') AS e",
              "SELECT j.v FROM generate_series(1, 1) g, LATERAL (SELECT row_to_json(t) AS v #{twins}) j",
              "SELECT (SELECT t::text #{twins} LIMIT 1) AS v", "SELECT t.id #{twins} WHERE t >= t", "SELECT t.id #{twins} ORDER BY t",
              "SELECT t.id #{twins} WHERE t::text LIKE '%token-v%'" ],
            "Blocked: the query serialises a whole row of `rac_pg_accounts`")
    response = run(%(SELECT row_to_json("T") AS j #{twins}))
    expect([ response.error?, response.content.first[:text].include?('{"id":1}') ]).to eq([ false, true ])
  ensure
    conn.execute("DROP TABLE IF EXISTS rac_pg_plain")
  end

  describe "an alias a statement uses twice, and a table named like a numbered alias" do
    before do
      conn.execute("DROP TABLE IF EXISTS rac_pg_plain, rac_pg_ev, rac_pg_ev_2 CASCADE")
      conn.execute("CREATE TABLE rac_pg_plain (id int)")
      conn.execute("CREATE TABLE rac_pg_ev (id int, note text)")
      conn.execute("CREATE TABLE rac_pg_ev_2 (id int, api_token text)")
      conn.execute("INSERT INTO rac_pg_plain VALUES (1)")
      conn.execute("INSERT INTO rac_pg_ev VALUES (1, 'first event')")
      conn.execute("INSERT INTO rac_pg_ev_2 VALUES (1, 'token-value')")
    end

    after { conn.execute("DROP TABLE IF EXISTS rac_pg_plain, rac_pg_ev, rac_pg_ev_2 CASCADE") }

    it "runs a whole row of the relation that holds no secret column" do
      { "SELECT row_to_json(p) AS j FROM rac_pg_plain p WHERE EXISTS (SELECT 1 FROM rac_pg_accounts p WHERE p.id = 1)" => '{"id":1}',
        "SELECT row_to_json(p) AS j, (SELECT count(*) FROM rac_pg_accounts p) AS n FROM rac_pg_plain p" => '{"id":1}',
        "SELECT row_to_json(p) AS j FROM rac_pg_plain p WHERE p.id IN (SELECT p.id FROM rac_pg_accounts p)" => '{"id":1}',
        "SELECT to_json(rac_pg_ev.*) AS j FROM rac_pg_ev JOIN rac_pg_ev_2 ON rac_pg_ev.id = rac_pg_ev_2.id" => "first event" }.each do |sql, shown|
        response = run(sql)
        expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including(shown) ]), sql
      end
    end

    it "refuses a whole row of the relation that holds one, and names that relation" do
      refused([ "SELECT (SELECT row_to_json(p) FROM rac_pg_accounts p LIMIT 1) AS j FROM rac_pg_plain p",
                "SELECT row_to_json(p) AS j FROM rac_pg_accounts p WHERE EXISTS (SELECT 1 FROM rac_pg_plain p WHERE p.id = 1)",
                "SELECT row_to_json(x) AS j FROM rac_pg_plain x_7 JOIN rac_pg_accounts x ON true",
                "SELECT row_to_json(x_7) AS j FROM rac_pg_plain x JOIN rac_pg_accounts x_7 ON true" ],
              "Blocked: the query serialises a whole row of `rac_pg_accounts`")
      refused([ "SELECT to_json(rac_pg_ev_2.*) AS j FROM rac_pg_ev JOIN rac_pg_ev_2 ON rac_pg_ev.id = rac_pg_ev_2.id" ],
              "Blocked: the query serialises a whole row of `rac_pg_ev_2`")
    end
  end

  describe "a relation outside the search path" do
    before do
      conn.execute("DROP SCHEMA IF EXISTS rac_pg_audit CASCADE")
      conn.execute("CREATE SCHEMA rac_pg_audit")
      conn.execute("CREATE TABLE rac_pg_audit.ledger (id int, email text, door_token text)")
      conn.execute("INSERT INTO rac_pg_audit.ledger VALUES (1, 'ledger@example.com', 'token-value')")
      conn.execute("CREATE VIEW rac_pg_audit.renamed AS SELECT id, door_token AS d FROM rac_pg_audit.ledger")
      conn.execute("CREATE VIEW rac_pg_reach AS SELECT id, door_token AS d FROM rac_pg_audit.ledger")
    end

    after do
      conn.execute("DROP VIEW IF EXISTS rac_pg_reach")
      conn.execute("DROP SCHEMA IF EXISTS rac_pg_audit CASCADE")
    end

    it "refuses a statement that names its secret column, as it does for a table of the search path" do
      from = "FROM rac_pg_audit.ledger"
      refused([ "SELECT upper(door_token) #{from}", "SELECT door_token AS d #{from}", "SELECT door_token || '' AS d #{from}",
                "SELECT d FROM (SELECT door_token AS d #{from}) s", "WITH c AS (SELECT door_token AS d #{from}) SELECT d FROM c",
                "SELECT id #{from} WHERE door_token LIKE 'token%'", "SELECT max(door_token) AS m #{from}", "SELECT id #{from} ORDER BY door_token",
                "SELECT (SELECT door_token #{from} LIMIT 1) AS d", %(SELECT door_token AS d FROM "rac_pg_audit" . "ledger"),
                "SELECT door_token AS d FROM RAC_PG_AUDIT.ledger" ],
              "Blocked: query references secret column `door_token`")
    end

    it "refuses its whole row and what a view or a set operation would carry past the redaction" do
      refused([ "SELECT row_to_json(l) FROM rac_pg_audit.ledger l", "SELECT l FROM rac_pg_audit.ledger l", "SELECT l::text FROM rac_pg_audit.ledger l" ],
              "Blocked: the query serialises a whole row of `ledger`")
      refused([ "WITH c AS MATERIALIZED (SELECT * FROM rac_pg_audit.renamed) SELECT * FROM c", "SELECT * FROM rac_pg_audit.renamed EXCEPT SELECT 0, ''",
                "WITH c AS MATERIALIZED (SELECT * FROM rac_pg_reach) SELECT * FROM c", "SELECT * FROM rac_pg_reach EXCEPT SELECT 0, ''" ],
              "Blocked: the query passes the secret column `door_token` through")
    end

    it "refuses a materialized view over it whatever the view's name holds: two spaces in a row, one, a tab, a newline, capitals" do
      names = [ "Rac  Far", "Rac Far", "Rac\tFar", "Rac\nFar", "RAC_pg_Far" ].map { |name| %("#{name}") }
      names.each { |name| conn.execute("CREATE MATERIALIZED VIEW #{name} AS SELECT id, door_token AS d FROM rac_pg_audit.ledger") }
      names.each { |name| refused([ "SELECT * FROM #{name}", "SELECT d FROM #{name}", "SELECT f.d FROM #{name} f" ], "Blocked: the view `") }
    ensure
      names.each { |name| conn.execute("DROP MATERIALIZED VIEW IF EXISTS #{name}") }
    end

    it "filters its secret column in place, and runs a join that reads none" do
      [ "SELECT * FROM rac_pg_audit.ledger", "SELECT * FROM rac_pg_audit.renamed", "SELECT * FROM rac_pg_reach",
        "SELECT * FROM (SELECT * FROM rac_pg_audit.ledger OFFSET 0) s" ].each do |sql|
        response = run(sql)
        expect(response.error?).to be(false), "#{sql}: #{response.content.first[:text]}"
        expect(response.content.first[:text]).to include("[FILTERED]"), sql
        expect(response.content.first[:text]).not_to include("token-value"), sql
      end
      joined = run("SELECT a.email, l.email AS other FROM rac_pg_accounts a JOIN rac_pg_audit.ledger l ON l.id = a.id")
      expect([ joined.error?, joined.content.first[:text] ]).to match([ false, a_string_including("a@example.com", "ledger@example.com") ])
    end

    it "refuses a relation whose columns cannot be read" do
      allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:relation_columns).and_wrap_original do |original, c, schemas = []|
        schemas.empty? ? original.call(c, schemas) : {}
      end
      response = run("SELECT * FROM rac_pg_reach")
      expect([ response.error?, response.content.first[:text] ]).to eq(
        [ true, "Blocked: `rac_pg_audit.ledger` is not queried: its columns could not be read, so rails_query cannot tell which of them are secret." ]
      )
    end
  end

  describe "views that lead through schemas outside the search path" do
    let(:schemas) { %w[rac_pg_c1 rac_pg_c2 rac_pg_c3 rac_pg_c4] }

    def drop
      conn.execute("DROP MATERIALIZED VIEW IF EXISTS rac_pg_far, rac_pg_near")
      conn.execute("DROP VIEW IF EXISTS rac_pg_plain_far")
      schemas.each { |schema| conn.execute("DROP SCHEMA IF EXISTS #{schema} CASCADE") }
    end

    before do
      drop
      schemas.each { |schema| conn.execute("CREATE SCHEMA #{schema}") }
      conn.execute("CREATE TABLE rac_pg_c4.t (id int, door_token text)")
      conn.execute("INSERT INTO rac_pg_c4.t VALUES (1, 'token-value')")
      conn.execute("CREATE MATERIALIZED VIEW rac_pg_c3.m AS SELECT id, door_token AS x FROM rac_pg_c4.t")
      conn.execute("CREATE MATERIALIZED VIEW rac_pg_c2.m AS SELECT id, x FROM rac_pg_c3.m")
      conn.execute("CREATE MATERIALIZED VIEW rac_pg_c1.m AS SELECT id, x FROM rac_pg_c2.m")
      conn.execute("CREATE MATERIALIZED VIEW rac_pg_far AS SELECT id, x FROM rac_pg_c1.m")
      conn.execute("CREATE MATERIALIZED VIEW rac_pg_near AS SELECT id, x FROM rac_pg_c2.m")
      conn.execute("CREATE VIEW rac_pg_c3.v AS SELECT id, door_token AS x FROM rac_pg_c4.t")
      conn.execute("CREATE VIEW rac_pg_c2.v AS SELECT id, x FROM rac_pg_c3.v")
      conn.execute("CREATE VIEW rac_pg_c1.v AS SELECT id, x FROM rac_pg_c2.v")
      conn.execute("CREATE VIEW rac_pg_plain_far AS SELECT id, x FROM rac_pg_c1.v")
    end

    after { drop }

    def sent
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "runs a statement that names none of them, after the reads of its own schema alone" do
      [ "SELECT 1 AS one", "SELECT a.id, a.email FROM rac_pg_accounts a WHERE a.id = 1" ].each do |sql|
        response = nil
        statements = sent { response = run(sql) }
        expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("| 1 ") ]), sql
        expect(statements.grep(/rac_pg_c\d/)).to be_empty, sql
      end
      expect(sent { run("SELECT id, email FROM rac_pg_accounts WHERE id = 1") }.size).to eq(24)
    end

    it "refuses a statement that names a materialized view four schemas from the rows, by the view" do
      refused([ "SELECT * FROM rac_pg_far", "SELECT x FROM rac_pg_far", "SELECT f.id FROM rac_pg_accounts a JOIN rac_pg_far f ON f.id = a.id" ],
              "The view `rac_pg_far` leads through more schemas than rails_query follows, so the secret columns it could read " \
              "cannot be told and no statement that names it runs.")
    end

    it "follows a materialized view three schemas from the rows, and refuses it for the secret column it stores" do
      refused([ "SELECT * FROM rac_pg_near", "SELECT upper(x) FROM rac_pg_near" ],
              "Blocked: the view `rac_pg_near` is not queried: it reads the view `m`: its definition names the secret column `door_token`.")
    end

    it "reads through plain views however deep, and filters the secret column the plan traces" do
      response = run("SELECT * FROM rac_pg_plain_far")
      expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("[FILTERED]") ])
      expect(response.content.first[:text]).not_to include("token-value")
    end
  end

  describe "a plain view over a materialized view, both off the search path, over a secret column in a third schema" do
    def drop
      conn.execute("DROP VIEW IF EXISTS rac_pg_over_far")
      %w[rac_pg_f1 rac_pg_f2].each { |schema| conn.execute("DROP SCHEMA IF EXISTS #{schema} CASCADE") }
    end

    before do
      drop
      %w[rac_pg_f1 rac_pg_f2].each { |schema| conn.execute("CREATE SCHEMA #{schema}") }
      conn.execute("CREATE TABLE rac_pg_f2.t (id int, door_token text)")
      conn.execute("INSERT INTO rac_pg_f2.t VALUES (1, 'token-value')")
      conn.execute("CREATE MATERIALIZED VIEW rac_pg_f1.m AS SELECT id, door_token AS x FROM rac_pg_f2.t")
      conn.execute("CREATE VIEW rac_pg_over_far AS SELECT id, x FROM rac_pg_f1.m")
    end

    after { drop }

    it "follows the materialized view the plan names into the schema its definition reads, and refuses it" do
      refused([ "SELECT * FROM rac_pg_over_far", "SELECT x FROM rac_pg_over_far" ],
              "Blocked: the view `m` is not queried: its definition names the secret column `door_token`.")
    end
  end

  describe "a table and a materialized view of one name in two schemas" do
    def drop
      conn.execute("DROP SCHEMA IF EXISTS rac_pg_audit CASCADE")
      conn.execute("DROP TABLE IF EXISTS rac_pg_summary")
    end

    before do
      drop
      conn.execute("CREATE SCHEMA rac_pg_audit")
      conn.execute("CREATE TABLE rac_pg_audit.ledger (id int, email text, door_token text)")
      conn.execute("INSERT INTO rac_pg_audit.ledger VALUES (1, 'ledger@example.com', 'token-value')")
      conn.execute("CREATE MATERIALIZED VIEW rac_pg_audit.rac_pg_summary AS SELECT id, door_token AS t FROM rac_pg_audit.ledger")
      conn.execute("CREATE TABLE rac_pg_summary (id int, label text)")
      conn.execute("INSERT INTO rac_pg_summary VALUES (1, 'public summary')")
    end

    after { drop }

    it "runs a statement over the table, with the other schema named or not, and refuses the materialized view" do
      [ "SELECT * FROM rac_pg_summary", "SELECT s.label, l.email FROM rac_pg_summary s JOIN rac_pg_audit.ledger l ON l.id = s.id",
        "SELECT s.label FROM public.rac_pg_summary s WHERE EXISTS (SELECT 1 FROM rac_pg_audit.ledger)" ].each do |sql|
        response = run(sql)
        expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("public summary") ]), sql
      end
      refused([ "SELECT * FROM rac_pg_audit.rac_pg_summary", "SELECT s.label FROM rac_pg_summary s, rac_pg_audit.rac_pg_summary m" ],
              "Blocked: the view `rac_pg_summary` is not queried: its definition names the secret column `door_token`.")
    end
  end

  describe "a temporary table" do
    before do
      conn.execute("CREATE TEMP TABLE rac_pg_scratch (id int, label text, api_token text)")
      conn.execute("INSERT INTO rac_pg_scratch VALUES (1, 'temp label', 'token-value')")
      conn.execute("CREATE TEMP TABLE rac_pg_jotted (id int, label text)")
      conn.execute("INSERT INTO rac_pg_jotted VALUES (1, 'jotted label')")
      conn.execute("CREATE TEMP VIEW rac_pg_scratched AS SELECT id, api_token AS t FROM rac_pg_scratch")
    end

    after { conn.execute("DROP TABLE IF EXISTS pg_temp.rac_pg_scratch, pg_temp.rac_pg_jotted CASCADE") }

    it "runs an ordinary statement over one, and filters its secret column like any table's" do
      { "SELECT * FROM rac_pg_jotted" => "jotted label", "SELECT row_to_json(j) FROM rac_pg_jotted j" => "jotted label",
        "SELECT id, label FROM rac_pg_scratch" => "temp label", "SELECT * FROM rac_pg_scratch" => "[FILTERED]",
        "SELECT * FROM pg_temp.rac_pg_scratch" => "[FILTERED]", "SELECT * FROM rac_pg_scratched" => "[FILTERED]" }.each do |sql, shown|
        response = run(sql)
        expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including(shown) ]), sql
        expect(response.content.first[:text]).not_to include("token-value"), sql
      end
    end

    it "refuses its whole row, and an expression over the secret column a temporary view renames" do
      refused([ "SELECT row_to_json(s) FROM rac_pg_scratch s", "SELECT s::text FROM pg_temp.rac_pg_scratch s" ],
              "Blocked: the query serialises a whole row of `rac_pg_scratch`")
      refused([ "SELECT upper(t) FROM rac_pg_scratched", "SELECT max(t) FROM rac_pg_scratched" ],
              "Blocked: the query's plan uses the secret column `api_token`")
    end
  end

  describe "a materialized view" do
    before do
      conn.execute("DROP MATERIALIZED VIEW IF EXISTS rac_pg_stored_nested, rac_pg_stored_plain, rac_pg_stored CASCADE")
      conn.execute("CREATE MATERIALIZED VIEW rac_pg_stored AS SELECT id, salt AS pd FROM rac_pg_accounts")
      conn.execute("CREATE MATERIALIZED VIEW rac_pg_stored_nested AS SELECT harmless AS h FROM rac_pg_renamed")
      conn.execute("CREATE MATERIALIZED VIEW rac_pg_stored_plain AS SELECT id, email FROM rac_pg_accounts")
      conn.execute("CREATE VIEW rac_pg_over_stored AS SELECT pd AS x FROM rac_pg_stored")
    end

    after { conn.execute("DROP MATERIALIZED VIEW IF EXISTS rac_pg_stored_nested, rac_pg_stored_plain, rac_pg_stored CASCADE") }

    it "is refused when its definition names a secret column, by the view and the column, through a view over it too" do
      refused([ "SELECT pd FROM rac_pg_stored", "SELECT * FROM rac_pg_stored", "SELECT upper(pd) FROM rac_pg_stored", "SELECT row_to_json(m) FROM rac_pg_stored m",
                "SELECT m::text FROM rac_pg_stored m", "SELECT id FROM rac_pg_stored WHERE pd LIKE 'salt%'", "SELECT * FROM rac_pg_over_stored" ],
              "Blocked: the view `rac_pg_stored` is not queried: its definition names the secret column `salt`. " \
              "A view can rename a column past the redaction on PostgreSQL, so query the tables it reads.")
      refused([ "SELECT h FROM rac_pg_stored_nested" ],
              "Blocked: the view `rac_pg_stored_nested` is not queried: it reads the view `rac_pg_renamed`: its definition names the secret column `salt`.")
    end

    it "runs when its definition names none, as a view the plan traces does" do
      [ "SELECT * FROM rac_pg_stored_plain", "SELECT * FROM rac_pg_renamed" ].each do |sql|
        response = run(sql)
        expect(response.error?).to be(false), "#{sql}: #{response.content.first[:text]}"
        expect(response.content.first[:text]).not_to include("salt-value"), sql
      end
    end
  end

  describe "a partitioned table and an inheritance parent that hold a secret column" do
    before do
      conn.execute("DROP TABLE IF EXISTS rac_pg_parts, rac_pg_parent CASCADE")
      conn.execute("CREATE TABLE rac_pg_parts (id int, email text, salt text) PARTITION BY RANGE (id)")
      conn.execute("CREATE TABLE rac_pg_parts_a PARTITION OF rac_pg_parts FOR VALUES FROM (0) TO (10)")
      conn.execute("CREATE TABLE rac_pg_parts_b PARTITION OF rac_pg_parts FOR VALUES FROM (10) TO (20)")
      conn.execute("INSERT INTO rac_pg_parts VALUES (1, 'p1@example.com', 'salt-value'), (11, 'p2@example.com', 'salt-value')")
      conn.execute("CREATE TABLE rac_pg_parent (id int, email text, salt text)")
      conn.execute("CREATE TABLE rac_pg_child (extra text) INHERITS (rac_pg_parent)")
      conn.execute("INSERT INTO rac_pg_parent VALUES (1, 'p1@example.com', 'salt-value')")
      conn.execute("INSERT INTO rac_pg_child VALUES (11, 'p2@example.com', 'salt-value', 'x')")
    end

    after { conn.execute("DROP TABLE IF EXISTS rac_pg_parts, rac_pg_parent CASCADE") }

    it "filters the secret column in place, with every partition read, with one pruned, sorted and limited" do
      { "SELECT * FROM rac_pg_parts" => 2, "SELECT * FROM rac_pg_parts WHERE id < 5" => 1, "SELECT * FROM rac_pg_parts ORDER BY id LIMIT 5" => 2,
        "SELECT x.* FROM rac_pg_parts x WHERE x.id < 15 ORDER BY 1 DESC" => 2, "SELECT * FROM (SELECT * FROM rac_pg_parts OFFSET 0) s" => 2,
        "SELECT * FROM rac_pg_parent" => 2, "SELECT * FROM rac_pg_parent ORDER BY id LIMIT 5" => 2, "SELECT * FROM ONLY rac_pg_parent" => 1 }.each do |sql, rows|
        response = run(sql)
        expect(response.error?).to be(false), "#{sql}: #{response.content.first[:text]}"
        expect(response.content.first[:text].scan("[FILTERED]").size).to eq(rows), sql
        expect(response.content.first[:text]).to include("p1@example.com"), sql
        expect(response.content.first[:text]).not_to include("salt-value"), sql
      end
    end

    it "filters the secret column in place with an expression beside the wildcard, as it does for a table with no partitions" do
      [ "SELECT *, id + 1 AS next FROM rac_pg_parts", "SELECT tableoid::regclass, * FROM rac_pg_parts", "SELECT 1 AS one, * FROM rac_pg_parts",
        "SELECT *, upper(email) AS up FROM rac_pg_parts ORDER BY id LIMIT 5", "SELECT p.*, now() > '2020-01-01' AS later FROM rac_pg_parts p",
        "SELECT *, id + 1 AS next FROM rac_pg_parent" ].each do |sql|
        response = run(sql)
        expect(response.error?).to be(false), "#{sql}: #{response.content.first[:text]}"
        expect(response.content.first[:text].scan("[FILTERED]").size).to eq(2), sql
        expect(response.content.first[:text]).to include("p1@example.com", "p2@example.com"), sql
        expect(response.content.first[:text]).not_to include("salt-value"), sql
      end
      refused([ "SELECT *, upper(salt) AS s FROM rac_pg_parts" ], "Blocked: query references secret column `salt`")
      refused([ "SELECT *, p::text AS row FROM rac_pg_parts p" ], "Blocked: the query serialises a whole row of")
    end

    it "refuses what would carry the secret column past the redaction" do
      refused([ "WITH c AS MATERIALIZED (SELECT * FROM rac_pg_parts) SELECT * FROM c", "SELECT * FROM rac_pg_parts EXCEPT SELECT 0, '', ''",
                "SELECT (1, 'p1@example.com', 'salt-valud') < (SELECT * FROM rac_pg_parts LIMIT 1) AS o",
                "WITH c AS MATERIALIZED (SELECT * FROM rac_pg_parent) SELECT * FROM c" ],
              "Blocked: the query passes the secret column `salt` through")
      refused([ "SELECT * FROM (SELECT * FROM rac_pg_parts) s (a, b, c)" ], "Blocked: a column-alias list")
      refused([ "SELECT * FROM rac_pg_parts ORDER BY 3", "SELECT * FROM rac_pg_parent ORDER BY 3" ], "Blocked: the query's plan uses the secret column `salt`")
      refused([ "SELECT row_to_json(p) FROM rac_pg_parts p", "SELECT p::text FROM rac_pg_parent p" ], "Blocked: the query serialises a whole row of")
    end

    it "refuses a whole row of the partitions under any alias" do
      refused([ "SELECT row_to_json(e) FROM rac_pg_parts e", "SELECT row_to_json(rac_pg_parts) FROM rac_pg_parts", "SELECT row_to_json(e_1) FROM rac_pg_parts e_1",
                %(SELECT row_to_json("E x") FROM rac_pg_parts "E x"), "SELECT e::text FROM rac_pg_parts e", "SELECT *, e FROM rac_pg_parts e",
                "SELECT count(*) FROM rac_pg_parts e WHERE e::text LIKE '%salt-v%'", "SELECT row_to_json(l) FROM rac_pg_accounts a, rac_pg_parts l" ],
              "Blocked: the query serialises a whole row of `rac_pg_parts_a`")
    end

    it "answers every read of a partitioned table that holds no secret column" do
      conn.execute("DROP TABLE IF EXISTS rac_pg_plain_parts CASCADE")
      conn.execute("CREATE TABLE rac_pg_plain_parts (id int, label text) PARTITION BY RANGE (id)")
      conn.execute("CREATE TABLE rac_pg_plain_parts_a PARTITION OF rac_pg_plain_parts FOR VALUES FROM (0) TO (10)")
      conn.execute("CREATE TABLE rac_pg_plain_parts_b PARTITION OF rac_pg_plain_parts FOR VALUES FROM (10) TO (20)")
      conn.execute("INSERT INTO rac_pg_plain_parts VALUES (1, 'first part'), (11, 'second part')")

      [ "SELECT * FROM rac_pg_plain_parts", "SELECT *, id + 1 AS next FROM rac_pg_plain_parts", "SELECT tableoid::regclass, * FROM rac_pg_plain_parts",
        "SELECT row_to_json(e) FROM rac_pg_plain_parts e", "SELECT *, e FROM rac_pg_plain_parts e", "SELECT e::text FROM rac_pg_plain_parts e",
        "SELECT * FROM rac_pg_plain_parts ORDER BY id LIMIT 5", "WITH c AS MATERIALIZED (SELECT * FROM rac_pg_plain_parts) SELECT * FROM c" ].each do |sql|
        response = run(sql)
        expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("first part", "second part") ]), sql
      end
    ensure
      conn.execute("DROP TABLE IF EXISTS rac_pg_plain_parts CASCADE")
    end
  end

  describe "a view over a UNION ALL of tables, one of which holds a secret column" do
    let(:tables) { %w[rac_pg_logs_2023 rac_pg_logs_2024 rac_pg_logs_2025 rac_pg_logs_a rac_pg_logs_b] }

    def drop
      conn.execute("DROP TABLE IF EXISTS #{tables.join(", ")} CASCADE")
    end

    def union(view, row, *members)
      first, *rest = members.map { |table| "SELECT id, #{format(row, table)}%s FROM #{table}" }
      conn.execute("CREATE VIEW #{view} AS #{[ format(first, " AS r"), *rest.map { |member| format(member, "") } ].join(" UNION ALL ")}")
    end

    before do
      drop
      tables.each_with_index do |table, i|
        held = %w[rac_pg_logs_2023 rac_pg_logs_a].include?(table) ? "" : ", api_token text"
        conn.execute("CREATE TABLE #{table} (id int, label text#{held})")
        conn.execute("INSERT INTO #{table} VALUES (#{i}, 'log #{i}'#{", 'token-value'" unless held.empty?})")
      end
      union("rac_pg_u_text", "%s::text", "rac_pg_logs_2023", "rac_pg_logs_2024")
      union("rac_pg_u_jsonb", "to_jsonb(%s)", "rac_pg_logs_2023", "rac_pg_logs_2024")
      union("rac_pg_u_three", "to_jsonb(%s)", "rac_pg_logs_2023", "rac_pg_logs_2024", "rac_pg_logs_2025")
      union("rac_pg_u_secret_first", "to_jsonb(%s)", "rac_pg_logs_2024", "rac_pg_logs_2023")
      union("rac_pg_u_letters", "to_jsonb(%s)", "rac_pg_logs_a", "rac_pg_logs_b")
      union("rac_pg_u_none", "to_jsonb(%s)", "rac_pg_logs_2023", "rac_pg_logs_a")
      conn.execute("CREATE VIEW rac_pg_u_columns AS SELECT * FROM rac_pg_logs_2024 UNION ALL SELECT * FROM rac_pg_logs_b")
      conn.execute("CREATE VIEW rac_pg_u_renamed AS SELECT id, label AS note FROM rac_pg_logs_2023 UNION ALL SELECT id, api_token FROM rac_pg_logs_2024")
    end

    after { drop }

    it "refuses the whole row of the table that holds it, wherever that table stands in the view and whatever the tables are named" do
      refused([ "SELECT * FROM rac_pg_u_jsonb", "SELECT * FROM rac_pg_u_text", "SELECT * FROM rac_pg_u_three", "SELECT r FROM rac_pg_u_jsonb WHERE id = 1",
                "SELECT r->>'api_token' AS t FROM rac_pg_u_jsonb", "SELECT count(*) FROM rac_pg_u_text WHERE r LIKE '%token-v%'",
                "SELECT * FROM rac_pg_u_secret_first", "SELECT * FROM rac_pg_u_jsonb ORDER BY id" ],
              "Blocked: the query serialises a whole row of `rac_pg_logs_2024`")
      refused([ "SELECT * FROM rac_pg_u_letters" ], "Blocked: the query serialises a whole row of `rac_pg_logs_b`")
    end

    it "runs the view over tables that hold none, and the columns of the others that are no whole row" do
      { "SELECT * FROM rac_pg_u_none" => "log 3", "SELECT id FROM rac_pg_u_jsonb" => "| 1  |", "SELECT id FROM rac_pg_u_letters" => "| 4  |" }.each do |sql, shown|
        response = run(sql)
        expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including(shown) ]), sql
      end
    end

    it "filters the secret column where every member hands it up in one place, and refuses a member that hands it up under another name" do
      response = run("SELECT * FROM rac_pg_u_columns")
      expect([ response.error?, response.content.first[:text].scan("[FILTERED]").size ]).to eq([ false, 2 ])
      expect(response.content.first[:text]).not_to include("token-value")
      refused([ "SELECT * FROM rac_pg_u_renamed", "SELECT note FROM rac_pg_u_renamed ORDER BY 1" ], "Blocked: the query passes the secret column `api_token` through")
    end
  end

  it "runs a subquery that reads no secret column of a table that holds one" do
    { "SELECT (SELECT count(*) FROM rac_pg_accounts) AS n" => "| 1 |", "SELECT (SELECT count(id) FROM rac_pg_accounts) AS n" => "| 1 |",
      "SELECT exists (SELECT 1 FROM rac_pg_accounts) AS n" => "| true |", "SELECT (SELECT max(id) FROM rac_pg_accounts) AS n" => "| 1 |",
      "SELECT (SELECT count(*) FROM rac_pg_renamed) AS n" => "| 1 |",
      "SELECT g, (SELECT count(*) FROM rac_pg_accounts a WHERE a.id = g) AS n FROM generate_series(1, 1) g" => "| 1 | 1 |" }.each do |sql, row|
      response = run(sql)
      expect(response.error?).to be(false), "#{sql}: #{response.content.first[:text]}"
      expect(response.content.first[:text]).to include(row), sql
    end
  end

  it "refuses a subquery that reads a secret column or a whole row" do
    body = "FROM rac_pg_accounts"
    refused([ "SELECT (SELECT max(api_token) #{body}) AS n", "SELECT (SELECT count(api_token) #{body}) AS n",
              "SELECT (SELECT string_agg(api_token, ',') #{body}) AS n" ], "Blocked: query references secret column `api_token`")
    refused([ "SELECT (SELECT row_to_json(rac_pg_accounts) #{body}) AS n", "SELECT (SELECT rac_pg_accounts #{body}) AS n",
              "SELECT (SELECT count(rac_pg_accounts) #{body}) AS n", "SELECT count(*) #{body} a GROUP BY a",
              "SELECT (SELECT count(*) #{body} WHERE (rac_pg_accounts.*)::text LIKE '%token-v%') AS n" ],
            "Blocked: the query serialises a whole row of `rac_pg_accounts`")
    guess = "(1, 'a@example.com', 'salt-valud', 'x', 'y')"
    # Which secret column a refusal names first depends on the other tables the database holds.
    { "Blocked: the query's plan uses the secret column" => [ "SELECT (SELECT max(harmless) FROM rac_pg_renamed) AS n",
                                                             "SELECT #{guess} < (SELECT * #{body} GROUP BY 1, 2, 3, 4, 5) AS o",
                                                             "SELECT (SELECT count(*) #{body} a NATURAL JOIN rac_pg_accounts b) AS n",
                                                             "SELECT (SELECT count(*) FROM (SELECT DISTINCT * #{body}) x) AS n" ],
      "Blocked: the query passes the secret column" => [ "SELECT count(*) FILTER (WHERE #{guess} < (SELECT * #{body})) AS n FROM generate_series(1, 1) g" ] }.each do |rule, statements|
      refused(statements, rule)
      statements.each { |sql| expect(run(sql).content.first[:text]).to match(/\A#{Regexp.escape(rule)} `(salt|api_token|shadow)`/), sql }
    end
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

  it "keeps refusing a column whose name differs from a configured secret one's past ASCII alone, and filters both" do
    RailsAiContext.configuration.query_redacted_columns += [ "\u00c9" ]
    conn.execute("DROP TABLE IF EXISTS rac_pg_accents")
    conn.execute(%(CREATE TABLE rac_pg_accents (id int, "\u00e9" text, "\u00c9" text)))
    conn.execute("INSERT INTO rac_pg_accents VALUES (1, 'lower', 'upper-secret')")

    refused([ %(SELECT "\u00e9" FROM rac_pg_accents), %(SELECT "\u00c9" AS x FROM rac_pg_accents), "SELECT \u00c9 FROM rac_pg_accents" ], "Blocked: ")
    expect(run("SELECT * FROM rac_pg_accents").content.first[:text]).to include("[FILTERED]").and(satisfy { |t| !t.match?(/lower|upper-secret/) })
  ensure
    RailsAiContext.configuration.query_redacted_columns -= [ "\u00c9" ]
    conn.execute("DROP TABLE IF EXISTS rac_pg_accents")
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

  it "refuses the relations that hold stored credentials, by name and through a view over them" do
    refused(%w[pg_user_mapping pg_user_mappings pg_subscription pg_authid pg_shadow pg_db_role_setting pg_foreign_server pg_hba_file_rules
               pg_ident_file_mappings information_schema.user_mapping_options].map { |name| "SELECT * FROM #{name}" }, "Blocked: `")
    refused([ "SELECT * FROM information_schema.user_mappings", "SELECT * FROM pg_stat_subscription", "SELECT * FROM information_schema.foreign_servers",
              %(SELECT * FROM U&"pg\\005Fuser\\005Fmappings") ], "Blocked: `")
  end

  it "filters a role's password hash and stored settings, refuses an expression over them, and runs the views that leave them out" do
    [ "SELECT usename, upper(passwd) AS p FROM pg_shadow", %(SELECT rolname, upper(rolpassword) AS p FROM U&"pg\\005Fauthid"),
      "SELECT rolname, array_to_string(rolconfig, ',') AS c FROM pg_roles", %(SELECT a FROM U&"pg\\005Fauthid" a) ].each do |sql|
      expect(run(sql).error?).to be(true), sql
    end
    hash = conn.select_value("SELECT rolpassword FROM pg_authid WHERE rolname = current_user")
    [ %(SELECT * FROM U&"pg\\005Fauthid"), %(SELECT * FROM (SELECT * FROM U&"pg\\005Fshadow" OFFSET 0) x) ].each do |sql|
      text = run(sql).content.first[:text]
      expect(text).to include("[FILTERED]"), sql
      expect(text).not_to include(hash), sql
    end
    expect(run("SELECT rolname, rolconfig FROM pg_roles WHERE rolname = current_user").content.first[:text]).to include("| [FILTERED] |")

    [ "SELECT rolname FROM pg_roles", "SELECT * FROM pg_roles", "SELECT count(*) FROM pg_roles", "SELECT usename FROM pg_user",
      "SELECT schema_name FROM information_schema.schemata", "SELECT d.datname, r.rolname FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba" ].each do |sql|
      response = run(sql)
      expect(response.error?).to be(false), "#{sql}: #{response.content.first[:text]}"
    end
  end

  it "refuses every way to list the settings, and the settings that can hold a password" do
    refused([ "SELECT name, setting FROM pg_settings", "SELECT * FROM pg_show_all_settings()", "SELECT * FROM pg_file_settings",
              "SELECT * FROM pg_show_all_file_settings()", %(SELECT "pg_show_all_settings"()) ], "Blocked: ")
    refused([ "SHOW ALL" ], "Blocked: SHOW ALL is not run")
    refused([ %(SHOW "work_mem"), %(SHOW U&"primary\\005Fconninfo") ], "Blocked: SHOW takes a setting's plain name")
    refused([ "SHOW primary_conninfo", %(SHOW "primary_conninfo"), "SHOW ssl_passphrase_command", "SHOW archive_command", "SELECT current_setting('primary_conninfo')",
              "SELECT current_setting('restore_command', true) AS c" ], "Blocked: the setting `")
    refused([ "SELECT current_setting('primary' || '_conninfo') AS x", "SELECT current_setting(column1) FROM (VALUES ('work_mem')) v",
              "SELECT * FROM (VALUES (current_setting('primary' || '_conninfo')), ('x')) v" ], "Blocked: current_setting runs only with")
    expect(run("SHOW server_version").content.first[:text]).to include(conn.select_value("SHOW server_version"))
    expect(run("SHOW TIME ZONE").error?).to be(false)
    expect(run("SELECT current_setting('work_mem') AS m").content.first[:text]).to include(conn.select_value("SHOW work_mem"))
  end

  it "refuses a function called by a quoted name, and one the plan prints no expression for" do
    refused([ %(SELECT "table_to_xml"('rac_pg_accounts', true, false, '')), %(SELECT U&"table\\005Fto\\005Fxml"('rac_pg_accounts', true, false, '')),
              %(SELECT U&"table!005Fto!005Fxml" UESCAPE '!' ('rac_pg_accounts', true, false, '')), %(SELECT "upper"('x')),
              %(SELECT (U&"pg\\005Fstat\\005Fget\\005Factivity"(NULL)).query),
              %(SELECT * FROM (VALUES ("table_to_xml"('rac_pg_accounts', true, false, '')), (NULL)) v) ], "Blocked: a quoted name is followed by a parenthesis")
    refused([ "SELECT * FROM (VALUES (lo_get(0)), (NULL)) v", "SELECT 1 AS one LIMIT (SELECT length(lo_get(0)))" ], "Blocked: function lo_get is VOLATILE")
    expect(run(%(SELECT count("id") AS n FROM "rac_pg_accounts" WHERE "id" IN (1, 2))).content.first[:text]).to include("| 1 |")
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

  it "answers a statement another session canceled as the error it is" do
    RailsAiContext.configuration.query_timeout = 20
    pid = conn.select_value("SELECT pg_backend_pid()")
    response = nil
    second_session(ENV.fetch("RAC_TEST_PG_URL")) do |other|
      canceler = Thread.new { sleep 1 and other.execute("SELECT pg_cancel_backend(#{pid})") }
      response = run("SELECT pg_sleep(10)")
    ensure
      canceler&.join
    end

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to start_with("SQL error: ").and include("canceling statement due to user request")
  end

  it "answers from a transaction the app opened with a raw BEGIN, and leaves it open with its writes" do
    conn.execute("BEGIN")
    conn.execute("INSERT INTO rac_pg_accounts (id, email) VALUES (99, 'mine@example.com')")

    expect(run("SELECT count(*) AS n FROM rac_pg_accounts").content.first[:text]).to include("| 2 |")
    expect(conn.raw_connection.transaction_status).to eq(PG::PQTRANS_INTRANS)
    conn.execute("COMMIT")
    expect(conn.select_value("SELECT count(*) FROM rac_pg_accounts WHERE id = 99")).to eq(1)
  end

  it "says the statement_timeout and transaction_read_only it shows are its own, and gives the session's" do
    RailsAiContext.configuration.query_timeout = 2
    conn.execute("SET statement_timeout = '50s'")
    note = "statement_timeout here is the value rails_query sets for each statement it runs. The session's own: statement_timeout 50s."
    both = "statement_timeout and transaction_read_only here are the values rails_query sets for each statement it runs. " \
      "The session's own: statement_timeout 50s, transaction_read_only off."

    expect(run("SHOW statement_timeout").content.first[:text]).to include("| 2s", note)
    expect(run("SELECT current_setting('transaction_read_only') AS ro, current_setting('statement_timeout') AS t").content.first[:text])
      .to include("| on", both)
    expect(described_class.call(sql: "SHOW statement_timeout", format: "csv").content.first[:text]).to end_with("2s\n\n#{note}")
    expect(run("SHOW lock_timeout").content.first[:text]).not_to include("rails_query sets")
  ensure
    conn.execute("RESET statement_timeout")
  end

  # The lock holds planning past the timeout and is gone before the statement's own timeout would end.
  # It is taken after the schema read, so the read that waits on it is planning.
  it "runs nothing when another connection holds a lock on the table past the timeout" do
    RailsAiContext.configuration.query_timeout = 1

    second_session(ENV.fetch("RAC_TEST_PG_URL")) do |locker|
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
        expect(response.content.first[:text]).to end_with("took the whole 1 second timeout, so the statement was not run.")
        expect(response.content.first[:text]).not_to include("salt-value", "token-value")
      end
    end
  end

  it "answers the timeout inside twice query_timeout when the lock is held before the call starts and never let go" do
    RailsAiContext.configuration.query_timeout = 1

    second_session(ENV.fetch("RAC_TEST_PG_URL")) do |locker|
      locker.execute("BEGIN")
      locker.execute("LOCK TABLE rac_pg_accounts IN ACCESS EXCLUSIVE MODE")

      [ "SELECT id FROM rac_pg_accounts", "SELECT 1 AS one" ].each do |sql|
        response = nil
        took = seconds { response = run(sql) }

        expect(response.error?).to be(true), sql
        expect(response.content.first[:text]).to end_with("took the whole 1 second timeout, so the statement was not run.")
        expect(took).to be_between(0.9, 2.5), sql
      end
    end
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
      response = nil
      @took = seconds { response = RailsAiContext::RunCache.around { described_class.call(sql: "SELECT 1", database: name) } }
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

  it "answers PostgreSQL's own error for a string prefix letter that follows a non-ASCII character" do
    [ "SELECT id FROM rac_pg_accounts WHERE email =\u00a0E'x'", "SELECT id AS idée'x' FROM rac_pg_accounts", "SELECT 1 AS 名B'1010'" ].each do |sql|
      response = run(sql)
      expect([ response.error?, response.content.first[:text] ]).to match([ true, a_string_starting_with("SQL error: PG::") ]), sql
    end
  end

  it "refuses a comparison with a row whose secret column's name holds two spaces in a row or a dotted capital I" do
    conn.execute("DROP TABLE IF EXISTS rac_pg_spaced, rac_pg_dotted")
    conn.execute(%(CREATE TABLE rac_pg_spaced (id int, "api  token" text)))
    conn.execute(%(CREATE TABLE rac_pg_dotted (id int, "apİ_key" text)))
    conn.execute("INSERT INTO rac_pg_spaced VALUES (1, 'token-value')")
    conn.execute("INSERT INTO rac_pg_dotted VALUES (1, 'token-value')")
    refused([ "SELECT (1, 'token-valud') < (SELECT * FROM rac_pg_spaced) AS o" ], "Blocked: the query passes the secret column `api token` through")
    refused([ "SELECT (1, 'token-valud') < (SELECT * FROM rac_pg_dotted) AS o" ], "Blocked: the query passes the secret column `api_key` through")
  ensure
    conn.execute("DROP TABLE IF EXISTS rac_pg_spaced, rac_pg_dotted")
  end

  describe "a foreign table that holds a secret column, behind a view that renames it" do
    def drop
      conn.execute("DROP SERVER IF EXISTS rac_pg_loop CASCADE")
      conn.execute("DROP TABLE IF EXISTS rac_pg_remote, rac_pg_remote_titles CASCADE")
      conn.execute(%(DROP SCHEMA IF EXISTS "Rac.Far" CASCADE))
    end

    before do
      drop
      url = URI.parse(ENV.fetch("RAC_TEST_PG_URL"))
      conn.execute("CREATE TABLE rac_pg_remote (id int, label text, api_token text)")
      conn.execute("INSERT INTO rac_pg_remote VALUES (1, 'far row', 'token-value')")
      begin
        conn.execute("CREATE EXTENSION IF NOT EXISTS postgres_fdw")
        conn.execute("CREATE SERVER rac_pg_loop FOREIGN DATA WRAPPER postgres_fdw " \
          "OPTIONS (dbname #{conn.quote(conn.current_database)}, port #{conn.quote(conn.select_value("SHOW port"))})")
        conn.execute("CREATE USER MAPPING FOR CURRENT_USER SERVER rac_pg_loop OPTIONS (user #{conn.quote(url.user)}, password #{conn.quote(url.password.to_s)})")
        conn.execute("CREATE FOREIGN TABLE rac_pg_foreign (id int, label text, api_token text) SERVER rac_pg_loop OPTIONS (table_name 'rac_pg_remote')")
        conn.execute("CREATE VIEW rac_pg_far AS SELECT id, label, api_token AS t FROM rac_pg_foreign")
        conn.execute("CREATE FOREIGN TABLE rac_pg_foreign_renamed (id int, api_token text OPTIONS (column_name 'label')) SERVER rac_pg_loop OPTIONS (table_name 'rac_pg_remote')")
        conn.execute("CREATE VIEW rac_pg_far_renamed AS SELECT id, api_token AS t FROM rac_pg_foreign_renamed")
        conn.select_value("SELECT count(*) FROM rac_pg_foreign")
      rescue ActiveRecord::StatementInvalid => e
        skip "postgres_fdw cannot reach this server from itself: #{e.message.lines.first}"
      end
    end

    after { drop }

    it "traces a join the remote server runs: a whole row of the table is refused and its secret column is filtered under another name" do
      conn.execute("INSERT INTO rac_pg_remote SELECT g, 'row ' || g, 'token-value-' || g FROM generate_series(2, 3000) g")
      refused([ "SELECT row_to_json(a) AS j FROM rac_pg_foreign a JOIN rac_pg_foreign b ON a.id = b.id WHERE a.id = 1",
                "SELECT a::text AS w FROM rac_pg_foreign a JOIN rac_pg_foreign b ON a.id = b.id WHERE a.id = 1" ],
              "Blocked: the query serialises a whole row of `rac_pg_foreign`")
      response = run("SELECT a.id, b.t FROM rac_pg_far a JOIN rac_pg_far b ON a.id = b.id WHERE a.id = 1")
      expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("[FILTERED]") ])
      expect(response.content.first[:text]).not_to include("token-value")
    end

    it "reads the secret columns of a table in another schema that only the remote join names" do
      [ "INSERT INTO rac_pg_remote SELECT g, 'row ' || g, 'token-value-' || g FROM generate_series(2, 3000) g",
        "CREATE TABLE rac_pg_remote_titles (id int, title text)", "INSERT INTO rac_pg_remote_titles SELECT g, 'title ' || g FROM generate_series(1, 3000) g",
        "CREATE FOREIGN TABLE rac_pg_titles (id int, title text) SERVER rac_pg_loop OPTIONS (table_name 'rac_pg_remote_titles')",
        %(CREATE SCHEMA "Rac.Far"),
        %(CREATE FOREIGN TABLE "Rac.Far"."In (it)" (id int, label text, api_token text) SERVER rac_pg_loop OPTIONS (schema_name 'public', table_name 'rac_pg_remote')),
        %(CREATE VIEW rac_pg_whole AS SELECT x FROM "Rac.Far"."In (it)" x) ].each { |sql| conn.execute(sql) }

      refused([ "SELECT b.x::text AS j FROM rac_pg_titles a JOIN rac_pg_whole b ON a.id = (b.x).id WHERE a.id = 1",
                "SELECT b.x FROM rac_pg_titles a JOIN rac_pg_whole b ON a.id = (b.x).id WHERE a.id = 1" ], "Blocked: ")
    end

    it "refuses a condition, a sort and a group on the secret column that the scan sends to the remote server" do
      refused([ "SELECT id FROM rac_pg_far WHERE t LIKE 'token-v%'", "SELECT id FROM rac_pg_far WHERE t IS NOT NULL", "SELECT id FROM rac_pg_far ORDER BY t",
                "SELECT id FROM rac_pg_far ORDER BY t LIMIT 1", "SELECT count(*) FROM rac_pg_far WHERE t LIKE 'token-v%'", "SELECT count(*) FROM rac_pg_far GROUP BY t" ],
              "Blocked: the query's plan uses the secret column `api_token`")
    end

    it "refuses a condition on a secret column that carries another name on the remote server" do
      refused([ "SELECT id FROM rac_pg_far_renamed WHERE t LIKE 'far%'", "SELECT id FROM rac_pg_far_renamed ORDER BY t" ],
              "Blocked: the query's plan uses the secret column `api_token`")
      response = run("SELECT * FROM rac_pg_far_renamed WHERE id = 1")
      expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("[FILTERED]") ])
      expect(response.content.first[:text]).not_to include("far row")
    end

    it "filters the secret column in place, and runs a condition and a sort on the other columns" do
      { "SELECT * FROM rac_pg_far" => "[FILTERED]", "SELECT * FROM rac_pg_foreign WHERE label = 'far row' ORDER BY id LIMIT 3" => "[FILTERED]",
        "SELECT id, label FROM rac_pg_far WHERE label <> 'api_token' ORDER BY label" => "far row", "SELECT count(*) AS n, label FROM rac_pg_far GROUP BY label" => "far row" }.each do |sql, shown|
        response = run(sql)
        expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including(shown) ]), sql
        expect(response.content.first[:text]).not_to include("token-value"), sql
      end
    end
  end

  it "runs a statement with a block comment inside a block comment, and nothing the comment holds" do
    { "SELECT 41 /* a /* b */ c */ AS n" => "41", "SELECT email /* /* */ , salt AS s */ FROM rac_pg_accounts" => "a@example.com",
      "SELECT 41 AS n /* /* */ */ -- */ , (SELECT salt FROM rac_pg_accounts)" => "41" }.each do |sql, shown|
      [ {}, { explain: true } ].each do |options|
        response = RailsAiContext::RunCache.around { described_class.call(sql: sql, **options) }
        expect(response.error?).to be(false), "#{sql}: #{response.content.first[:text]}"
        expect(response.content.first[:text]).not_to include("salt-value"), sql
        expect(response.content.first[:text]).to include(shown), sql if options.empty?
      end
    end
  end

  it "reads a sequence like a table that holds no secret column" do
    conn.execute("DROP SEQUENCE IF EXISTS rac_pg_seq")
    conn.execute("CREATE SEQUENCE rac_pg_seq START 41")
    [ "SELECT last_value FROM rac_pg_seq", "SELECT * FROM rac_pg_seq", "SELECT s.last_value + 0 AS same FROM rac_pg_seq s" ].each do |sql|
      response = run(sql)
      expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("41") ]), sql
    end
    refused([ "SELECT nextval('rac_pg_seq') AS n" ], "Blocked: function nextval is VOLATILE")
  ensure
    conn.execute("DROP SEQUENCE IF EXISTS rac_pg_seq")
  end

  it "reads the pg_sequences view, and still refuses the calls that move or read a sequence's session value" do
    conn.execute("DROP SEQUENCE IF EXISTS rac_pg_seq")
    conn.execute("CREATE SEQUENCE rac_pg_seq START 41")
    conn.execute("SELECT nextval('rac_pg_seq')")
    [ "SELECT sequencename, last_value FROM pg_sequences WHERE sequencename = 'rac_pg_seq'", "SELECT * FROM pg_sequences",
      "SELECT pg_sequence_last_value('rac_pg_seq') AS v" ].each do |sql|
      response = run(sql)
      expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("41") ]), sql
    end
    [ [ "nextval", "SELECT nextval('rac_pg_seq') AS n" ], [ "setval", "SELECT setval('rac_pg_seq', 1) AS n" ],
      [ "currval", "SELECT currval('rac_pg_seq') AS n" ], [ "lastval", "SELECT lastval() AS n" ],
      [ "nextval", "SELECT last_value FROM pg_sequences WHERE nextval('rac_pg_seq') > 0" ] ].each do |function, sql|
      refused([ sql ], "Blocked: function #{function} is VOLATILE")
    end
    expect(conn.select_value("SELECT last_value FROM rac_pg_seq").to_i).to eq(41)
  ensure
    conn.execute("DROP SEQUENCE IF EXISTS rac_pg_seq")
  end

  describe "TABLESAMPLE" do
    before do
      conn.execute("CREATE OR REPLACE FUNCTION public.bernoulli(int) RETURNS int VOLATILE LANGUAGE sql AS 'SELECT $1'")
      conn.execute("CREATE OR REPLACE FUNCTION public.system(int) RETURNS int VOLATILE LANGUAGE sql AS 'SELECT $1'")
    end

    after { conn.execute("DROP FUNCTION IF EXISTS public.bernoulli(int), public.system(int)") }

    it "runs a sampled read, whose sampling method the statement never calls" do
      [ "SELECT id, email FROM rac_pg_accounts TABLESAMPLE BERNOULLI (100) ORDER BY id LIMIT 2",
        "SELECT id, email FROM rac_pg_accounts TABLESAMPLE SYSTEM (100)", "SELECT id, email FROM rac_pg_accounts tablesample system(100) REPEATABLE (1)",
        "SELECT id, email FROM rac_pg_accounts a TABLESAMPLE pg_catalog.bernoulli (100) WHERE a.id = 1" ].each do |sql|
        response = run(sql)
        expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("a@example.com") ]), sql
      end
      text = run("SELECT * FROM rac_pg_accounts TABLESAMPLE SYSTEM (100)").content.first[:text]
      expect(text).to include("a@example.com", "[FILTERED]")
      expect(text).not_to include("salt-value", "token-value")
    end

    it "refuses a VOLATILE function named like a sampling method wherever the statement calls it" do
      { "bernoulli" => [ "SELECT bernoulli(1) AS b", "SELECT id FROM rac_pg_accounts TABLESAMPLE BERNOULLI (100) WHERE bernoulli(1) = 1",
                         "SELECT id FROM rac_pg_accounts TABLESAMPLE SYSTEM (bernoulli(100))",
                         "SELECT id FROM rac_pg_accounts TABLESAMPLE SYSTEM (100) REPEATABLE (bernoulli(1))",
                         "SELECT 1 AS one LIMIT (SELECT bernoulli(1))", "SELECT * FROM (VALUES (bernoulli(1)), (2)) v" ],
        "system" => [ "SELECT system(1) AS s", "SELECT id FROM rac_pg_accounts TABLESAMPLE SYSTEM (100) LIMIT (SELECT system(1))" ] }.each do |function, statements|
        refused(statements, "Blocked: function #{function} is VOLATILE")
      end
    end
  end

  it "runs a nested uncorrelated EXISTS over a table with a secret column, and still refuses each shape that passes one through" do
    conn.execute("DROP TABLE IF EXISTS rac_pg_plain")
    conn.execute("CREATE TABLE rac_pg_plain (id int)")
    conn.execute("INSERT INTO rac_pg_plain VALUES (7)")
    gate = "EXISTS (SELECT 1 FROM rac_pg_accounts r WHERE r.id = 1)"
    [ "SELECT q.id FROM rac_pg_plain q WHERE EXISTS (SELECT 1 FROM rac_pg_accounts p WHERE #{gate})",
      "SELECT q.id FROM rac_pg_plain q WHERE EXISTS (SELECT 1 FROM rac_pg_accounts p WHERE EXISTS (SELECT 1 FROM rac_pg_accounts r WHERE #{gate}))",
      "SELECT q.id, (SELECT count(*) FROM rac_pg_accounts p WHERE #{gate}) AS n FROM rac_pg_plain q",
      "SELECT q.id FROM rac_pg_plain q WHERE EXISTS (SELECT 1 FROM rac_pg_accounts p WHERE #{gate} OFFSET 0)",
      "SELECT p.id + 6 AS id FROM rac_pg_accounts p WHERE #{gate}" ].each do |sql|
      response = run(sql)
      expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("7") ]), sql
    end
    [ "SELECT * FROM rac_pg_accounts p WHERE #{gate}", "SELECT x.* FROM rac_pg_plain q, LATERAL (SELECT * FROM rac_pg_accounts p WHERE #{gate} OFFSET 0) x" ].each do |sql|
      text = run(sql).content.first[:text]
      expect(text).to include("a@example.com", "[FILTERED]"), sql
      expect(text).not_to include("salt-value", "token-value"), sql
    end
    expect(run("SELECT max(x.email) AS m FROM (SELECT * FROM rac_pg_accounts p WHERE #{gate} OFFSET 0) x").content.first[:text]).to include("a@example.com")

    guess = "(1, 'a@example.com', 'salt-valud', 'x', 'y')"
    refused([ "SELECT #{guess} < (SELECT * FROM rac_pg_accounts p WHERE #{gate}) AS o",
              "SELECT q.id FROM rac_pg_plain q WHERE #{guess} < (SELECT * FROM rac_pg_accounts p WHERE #{gate})",
              "SELECT q.id FROM rac_pg_plain q WHERE #{guess} < ANY (SELECT * FROM rac_pg_accounts p WHERE #{gate})",
              "SELECT q.id FROM rac_pg_plain q WHERE EXISTS (SELECT 1 FROM rac_pg_accounts p WHERE #{gate} AND #{guess} < (SELECT * FROM rac_pg_accounts))",
              "SELECT id FROM (SELECT * FROM rac_pg_accounts p WHERE #{gate} EXCEPT SELECT * FROM rac_pg_accounts WHERE false) s",
              "WITH c AS MATERIALIZED (SELECT * FROM rac_pg_accounts p WHERE #{gate}) SELECT id, email FROM c",
              "SELECT * FROM rac_pg_accounts p WHERE #{gate} ORDER BY 3", "SELECT id FROM rac_pg_accounts p WHERE #{gate} AND p::text LIKE '%salt-v%'" ],
            "Blocked: the query")
  ensure
    conn.execute("DROP TABLE IF EXISTS rac_pg_plain")
  end

  it "refuses a set operation over a secret column in every plan shape, and runs one over the other columns" do
    conn.execute("CREATE VIEW rac_pg_fenced AS SELECT id, salt AS d FROM rac_pg_accounts OFFSET 0")
    guess = "SELECT 1, 'a@example.com', 'salt-value', 'token-value', 'salt-value'"
    refused([ "SELECT * FROM rac_pg_accounts EXCEPT #{guess}", "SELECT * FROM rac_pg_accounts EXCEPT ALL #{guess}",
              "SELECT * FROM rac_pg_accounts INTERSECT #{guess}", "#{guess} INTERSECT ALL SELECT * FROM rac_pg_accounts",
              "SELECT * FROM rac_pg_renamed EXCEPT SELECT 1, 'salt-value'", "SELECT count(*) AS n FROM (SELECT * FROM rac_pg_renamed EXCEPT SELECT 1, 'salt-value') s",
              "SELECT * FROM rac_pg_fenced EXCEPT SELECT 1, 'salt-value'", "SELECT 1, 'salt-value' INTERSECT SELECT * FROM rac_pg_fenced" ],
            "Blocked: the query passes the secret column")
    refused([ "SELECT * FROM rac_pg_accounts a WHERE a.id = 1 EXCEPT SELECT * FROM rac_pg_accounts b WHERE b.id = 2" ], "Blocked: the query")
    response = run("SELECT id, email FROM rac_pg_accounts EXCEPT SELECT 2, 'x'")
    expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("a@example.com") ])
  end

  it "plans an EXPLAIN (GENERIC_PLAN) as the server does, and still refuses what its statement would leak" do
    [ "EXPLAIN (GENERIC_PLAN) SELECT id FROM rac_pg_accounts WHERE id = $1", "explain (verbose, generic_plan true) SELECT id FROM rac_pg_accounts WHERE id = $1",
      "EXPLAIN (GENERIC_PLAN on, COSTS off) SELECT id, email FROM rac_pg_accounts WHERE id = $1 AND email = $2" ].each do |sql|
      response = run(sql)
      expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("$1") ]), sql
    end
    expect(run("EXPLAIN (GENERIC_PLAN false) SELECT id FROM rac_pg_accounts WHERE id = $1").content.first[:text]).to include("there is no parameter $1")

    refused([ "EXPLAIN (GENERIC_PLAN) SELECT row_to_json(a) FROM rac_pg_accounts a WHERE id = $1",
              "EXPLAIN (GENERIC_PLAN) SELECT * FROM rac_pg_accounts WHERE id = $1 ORDER BY 3",
              "EXPLAIN (GENERIC_PLAN) SELECT id FROM rac_pg_accounts WHERE salt = $1",
              "EXPLAIN (GENERIC_PLAN) SELECT lo_get($1::oid) AS v" ], "Blocked: ")
  end

  it "runs SHOW, which has no plan" do
    expect(run("SHOW server_version").error?).to be(false)
  end

  it "flags a failing EXPLAIN as an error" do
    expect(described_class.call(sql: "SELECT nope FROM rac_pg_accounts", explain: true).error?).to be(true)
  end
end
