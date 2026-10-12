# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::SqlGate do
  let(:families) do
    { sqlite: RailsAiContext::DatabaseFamily::SQLITE, mysql: RailsAiContext::DatabaseFamily::MYSQL,
      postgresql: RailsAiContext::DatabaseFamily::POSTGRESQL }
  end
  let(:relations) { {} }
  let(:views) { nil }
  let(:generated) { {} }
  let(:encrypted) { [] }
  let(:connection) { double("connection", quote: nil, select_values: []) }
  let(:plan) { { "Node Type" => "Result" } }

  before do
    RailsAiContext.configuration.query_redacted_columns = %w[
      password_digest encrypted_password password_hash
      reset_password_token confirmation_token unlock_token
      otp_secret session_data secret_key
      api_key api_secret access_token refresh_token jti
    ]
    RailsAiContext.configuration.query_allowed_columns = []
    allow(connection).to receive(:quote) { |name| "'#{name}'" }
    allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:plan) { plan }
  end

  after { RailsAiContext.configuration.query_allowed_columns = [] }

  def check(sql, family = :sqlite)
    secrets = RailsAiContext::SecretColumns.new(relations: relations, views: views, generated: generated, encrypted: encrypted)
    described_class.new(family: families.fetch(family), secrets: secrets, connection: connection, timeout: 5).check(sql)
  end

  def refusal(sql, family = :sqlite)
    check(sql, family).refusal
  end

  def runs?(sql, family = :sqlite)
    !check(sql, family).refused?
  end

  describe "a statement it runs" do
    it "answers the text to run" do
      verdict = check("SELECT 1 AS test")
      expect(verdict.refused?).to be(false)
      expect(verdict.sql).to eq("SELECT 1 AS test")
    end

    it "runs a CTE, EXPLAIN, DESCRIBE, INTERSECT and EXCEPT" do
      [
        "WITH active AS (SELECT * FROM users WHERE active = 1) SELECT * FROM active",
        "EXPLAIN SELECT * FROM users", "DESCRIBE users",
        "SELECT id FROM posts INTERSECT SELECT id FROM posts", "SELECT id FROM posts EXCEPT SELECT id FROM posts",
        "SELECT * FROM users WHERE active = true OR admin = true"
      ].each { |sql| expect(runs?(sql)).to be(true), sql }
    end
  end

  describe "refusals" do
    it "refuses no statement at all" do
      expect(refusal(nil)).to include("required")
      expect(refusal("  ")).to include("required")
    end

    %w[INSERT UPDATE DELETE DROP ALTER TRUNCATE CREATE GRANT].each do |keyword|
      it "refuses #{keyword}" do
        sql = {
          "INSERT" => "INSERT INTO users (email) VALUES ('x')", "UPDATE" => "UPDATE users SET email = 'x'",
          "DELETE" => "DELETE FROM users", "DROP" => "DROP TABLE users", "ALTER" => "ALTER TABLE users ADD COLUMN age INTEGER",
          "TRUNCATE" => "TRUNCATE users", "CREATE" => "CREATE TABLE evil (id INTEGER)", "GRANT" => "GRANT ALL ON users TO evil"
        }.fetch(keyword)
        expect(refusal(sql)).to include("Blocked").and include(keyword)
      end
    end

    it "refuses a statement that starts with anything but a read" do
      expect(refusal("VACUUM users")).to include("Only SELECT, WITH, SHOW, EXPLAIN, DESCRIBE allowed")
    end

    it "refuses a second statement, also one after a literal holding a comment marker or a hash" do
      [ "SELECT 1; DROP TABLE users", "SELECT '--' AS m; SELECT 2 AS hidden", "SELECT '#'; DROP TABLE users",
        "SELECT $$a$$ AS v; DROP TABLE users" ].each do |sql|
        expect(refusal(sql)).to include("multiple statements"), sql
      end
    end

    it "refuses a DO block as a statement it does not run, not as multiple statements" do
      expect(refusal("DO $$ BEGIN PERFORM 1; END $$", :postgresql)).to include("Only SELECT")
    end

    it "refuses SELECT INTO and a disk write" do
      expect(refusal("SELECT * INTO new_table FROM users")).to include("SELECT INTO creates a table")
      expect(refusal("SELECT 1 INTO OUTFILE '/tmp/leak.txt'")).to eq("Blocked: SELECT INTO OUTFILE / DUMPFILE writes to disk")
      expect(refusal("SELECT id FROM orders INTO OUTFILE '/tmp/x'", :mysql)).to include("OUTFILE")
    end

    it "refuses a sensitive SHOW and every SHOW CREATE but a table or view" do
      expect(refusal("SHOW GRANTS FOR 'root'")).to include("sensitive SHOW command")
      expect(refusal("SHOW CREATE USER 'rt'@'%'", :mysql)).to include("CREATE")
      expect(refusal("SHOW CREATE DATABASE app", :mysql)).to include("CREATE")
      expect(runs?("SHOW CREATE TABLE orders", :mysql)).to be(true)
      expect(runs?("SHOW CREATE VIEW order_totals", :mysql)).to be(true)
    end

    it "reads a write keyword or INTO inside a literal as data, and the replace() function as a function" do
      expect(runs?("SELECT count(*) FROM orders WHERE notes LIKE '%update%'")).to be(true)
      expect(runs?("SELECT count(*) FROM orders WHERE notes = 'put into box'")).to be(true)
      expect(runs?("SELECT replace(name, 'Product ', 'P-') AS short FROM products")).to be(true)
      expect(refusal("REPLACE INTO products VALUES (1)")).to include("REPLACE")
      expect(refusal("WITH x AS (DELETE FROM orders RETURNING id) SELECT * FROM x")).to include("DELETE")
    end

    %w[pg_read_file pg_read_binary_file pg_ls_dir pg_stat_file lo_import load_extension].each do |fn|
      it "refuses the file function #{fn}" do
        expect(refusal("SELECT #{fn}('/etc/passwd')")).to include("dangerous function #{fn}")
      end
    end

    it "refuses dblink, LOAD_FILE and LOAD DATA" do
      expect(refusal("SELECT * FROM dblink('host=evil.com', 'SELECT 1') AS t(a int)")).to include("dblink")
      expect(refusal("SELECT LOAD_FILE('/etc/passwd')")).to match(/load_file/i)
      expect(refusal("LOAD DATA INFILE '/etc/passwd' INTO TABLE users")).to match(/LOAD.*DATA/i)
      expect(refusal("LOAD DATA LOCAL INFILE '/etc/passwd' INTO TABLE users")).to match(/LOAD.*DATA/i)
    end

    it "refuses a file function inside a MySQL executable comment" do
      [ "SELECT /*!50000 LOAD_FILE('/etc/passwd') */ AS x", "SELECT /*! pg_read_file('/etc/passwd') */ AS x",
        "SELECT /*!80000 dblink('host=evil', 'SELECT * FROM users') */ 1" ].each do |sql|
        %i[sqlite mysql].each { |family| expect(refusal(sql, family)).to start_with("Blocked"), "#{family}: #{sql}" }
      end
    end

    %w[
      pg_terminate_backend pg_cancel_backend pg_reload_conf pg_stat_reset
      pg_create_restore_point pg_logical_emit_message pg_advisory_lock
      pg_notify set_config txid_current pg_switch_wal pg_promote
      pg_drop_replication_slot pg_replication_origin_create
    ].each do |fn|
      it "refuses the PostgreSQL administrative function #{fn}" do
        expect(refusal("SELECT #{fn}(1)")).to include("administrative function #{fn}")
      end
    end

    %w[GET_LOCK RELEASE_LOCK RELEASE_ALL_LOCKS IS_FREE_LOCK IS_USED_LOCK].each do |fn|
      it "refuses the MySQL session function #{fn}" do
        expect(refusal("SELECT #{fn}('x')")).to include("session function #{fn}")
      end
    end

    it "does not trip on a name that merely contains a refused function's name" do
      expect(runs?("SELECT lock_version, set_configuration FROM widgets")).to be(true)
    end

    [
      "SELECT name FROM users UNION SELECT password FROM users",
      "SELECT 1 UNION ALL SELECT 2",
      "SELECT *, 1, 2 FROM posts UNION DISTINCT SELECT * FROM users",
      "SELECT *, 1, 2 FROM posts UNION (SELECT * FROM users)",
      "SELECT *, 1, 2 FROM posts\nunion\n\tall (SELECT * FROM users)",
      "WITH RECURSIVE r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT n FROM r"
    ].each do |sql|
      it "refuses a UNION on every family: #{sql.lines.first.strip[0, 60]}" do
        %i[mysql sqlite postgresql].each do |family|
          expect(refusal(sql, family)).to start_with("Blocked: UNION is not run."), family.to_s
        end
      end
    end

    it "reads a union inside a string literal as data on PostgreSQL alone" do
      sql = "SELECT id FROM posts WHERE title = 'European Union'"
      expect(runs?(sql, :postgresql)).to be(true)
      expect(runs?(sql, :mysql)).to be(false)
    end
  end

  describe "locking clauses" do
    %w[UPDATE SHARE].push("NO KEY UPDATE").each do |lock|
      it "refuses FOR #{lock} on every family" do
        %i[sqlite mysql postgresql].each do |family|
          expect(refusal("SELECT * FROM users FOR #{lock}", family)).to include("FOR UPDATE/SHARE"), family.to_s
        end
      end
    end

    it "refuses every other spelling of a locking read on every family" do
      [ "LOCK IN SHARE MODE", "lock  in\nshare mode", "LOCK IN SHARE MODE NOWAIT", "LOCK IN SHARE MODE WAIT 1", "FOR UPDATE NOWAIT",
        "FOR UPDATE SKIP LOCKED", "FOR SHARE OF users", "FOR UPDATE WAIT 1", "FOR KEY SHARE" ].each do |lock|
        %i[sqlite mysql postgresql].each do |family|
          expect(refusal("SELECT id FROM users LIMIT 5 #{lock}", family)).to include("FOR UPDATE/SHARE"), "#{lock} on #{family}"
        end
      end
    end

    it "reads one inside a literal as data on PostgreSQL, whose read-only transaction refuses locking reads" do
      expect(runs?("SELECT id FROM orders WHERE notes LIKE '%ready for update%'", :postgresql)).to be(true)
      expect(runs?("SELECT id FROM orders WHERE notes LIKE '%lock in share mode%'", :postgresql)).to be(true)
    end

    it "reads the raw text on MySQL, whose read-only transaction allows FOR SHARE and LOCK IN SHARE MODE" do
      expect(refusal("SELECT id FROM orders WHERE notes LIKE '%ready for share%'", :mysql)).to include("FOR UPDATE/SHARE")
      expect(refusal("SELECT id FROM orders WHERE notes LIKE '%lock in share mode%'", :mysql)).to include("FOR UPDATE/SHARE")
    end
  end

  describe "literals that read like injection" do
    it "runs OR 1=1 inside a literal and as written: the caller writes the whole statement" do
      expect(runs?("SELECT id FROM posts WHERE body LIKE '%OR 1=1%'")).to be(true)
      expect(runs?("SELECT * FROM users WHERE active = false OR true")).to be(true)
    end
  end

  describe "column-alias lists" do
    it "refuses one that renames a table's columns" do
      [
        "WITH t(a,b,c) AS (SELECT * FROM users) SELECT * FROM t",
        "SELECT * FROM users AS u(a,b,c,d,e)",
        "SELECT * FROM (SELECT * FROM users) AS t(a,b,c)",
        "SELECT * FROM users u(a,b,c,d)",
        "WITH t(a, b) AS (SELECT id, email FROM users) SELECT * FROM t"
      ].each { |sql| expect(refusal(sql)).to include("column-alias list"), sql }
    end

    it "runs a type modifier, a function call, a typed record list, a single alias and a VALUES body" do
      [
        "SELECT CAST(amount AS numeric(10,2)) AS a FROM orders",
        "SELECT id::varchar(255) AS v FROM users",
        "SELECT coalesce(first_name, last_name) AS nm FROM users",
        "SELECT * FROM json_to_recordset('[]') AS t(a int, b text)",
        "SELECT * FROM generate_series(1,5) AS g(n)",
        "SELECT * FROM (VALUES (1,'a'),(2,'b')) AS v(id, name)",
        "WITH v(id, name) AS (VALUES (1,'a'),(2,'b')) SELECT * FROM v",
        "SELECT * FROM (VALUES ('x)y', 1),('z', 2)) AS v(a, b)"
      ].each { |sql| expect(runs?(sql)).to be(true), sql }
    end

    it "still refuses a secret name inside a VALUES body" do
      expect(refusal("SELECT * FROM (VALUES (password_digest)) AS v(a, b)")).to include("sensitive column `password_digest`")
    end
  end

  describe "secret columns named in the text" do
    it "refuses a secret name however the statement uses it" do
      [
        "SELECT id, email, password_digest FROM users", "SELECT password_digest AS x FROM users LIMIT 50",
        "SELECT substring(password_digest, 1, 60) FROM users", "SELECT v FROM (SELECT password_digest AS v FROM users) sub",
        "SELECT CASE WHEN id > 0 THEN password_digest END FROM users"
      ].each { |sql| expect(refusal(sql)).to include("sensitive column `password_digest`"), sql }
      expect(refusal("SELECT md5(session_data) FROM sessions")).to include("session_data")
    end

    it "refuses one that follows a comment marker in a string literal" do
      expect(refusal("SELECT '--' AS m, api_key AS x FROM (SELECT 'leak' AS api_key) t")).to include("sensitive column `api_key`")
    end

    it "lets the app exempt a name, case-insensitively, and only that name" do
      RailsAiContext.configuration.query_allowed_columns = %w[API_SECRET]
      expect(runs?("SELECT api_secret FROM oauth_applications")).to be(true)
      expect(refusal("SELECT password_digest FROM users")).to include("password_digest")
    end

    it "refuses a configured query_redacted_columns name" do
      RailsAiContext.configuration.query_redacted_columns = %w[custom_secret_field]
      expect(refusal("SELECT custom_secret_field AS y FROM tenants")).to include("custom_secret_field")
    end

    it "matches word-bounded" do
      expect(runs?("SELECT id, keyword, description FROM tags")).to be(true)
    end

    context "with a schema whose columns the heuristic flags" do
      let(:relations) { { "users" => %w[id email name api_token auth_token] } }

      it "refuses them through an alias, an expression and a subquery" do
        expect(refusal("SELECT api_token AS c FROM users")).to include("api_token")
        expect(refusal("SELECT upper(auth_token) FROM users")).to include("auth_token")
        expect(refusal("SELECT (SELECT api_token FROM users LIMIT 1) AS leaked")).to include("api_token")
        expect(runs?("SELECT id, email, name FROM users")).to be(true)
        expect(runs?("SELECT t.id FROM tokens t WHERE t.id > 0")).to be(true)
      end
    end

    it "refuses a name inside a literal off PostgreSQL" do
      expect(refusal("SELECT id FROM posts WHERE body LIKE '%secret%'")).to include("secret")
    end

    context "on PostgreSQL" do
      let(:sql) { "SELECT id FROM posts WHERE body LIKE '%secret%'" }

      it "runs a name inside a literal when the plan vouches" do
        expect(runs?(sql, :postgresql)).to be(true)
        expect(runs?("SELECT id FROM posts WHERE body = E'\\'api_key'", :postgresql)).to be(true)
        expect(runs?("SELECT $t$ api_key $t$ AS v", :postgresql)).to be(true)
      end

      it "refuses it in a statement that has no plan" do
        expect(refusal("SHOW 'api_key'", :postgresql)).to include("the plan could not be obtained")
      end

      it "still refuses a real identifier beside a literal, a quoted identifier and a positional parameter" do
        expect(refusal("SELECT 'x' || api_secret AS y FROM t", :postgresql)).to include("api_secret")
        expect(refusal('SELECT "api_key" FROM t', :postgresql)).to include("api_key")
        expect(refusal(%(SELECT 1 AS "a'b", upper(api_key), 'x' FROM users), :postgresql)).to include("api_key")
        expect(refusal("SELECT id FROM t WHERE id = $1 AND api_key = $1", :postgresql)).to include("api_key")
      end
    end
  end

  describe "a view the database cannot redact" do
    let(:relations) { { "users" => %w[id email passwd] } }
    let(:views) { { "people" => "SELECT id, passwd AS p1 FROM users", "emails" => "SELECT id, email FROM users" } }

    it "refuses a statement that names it, by the view and the column, and points at the tables" do
      %i[sqlite mysql].each do |family|
        text = refusal("SELECT * FROM people", family)
        expect(text).to start_with("Blocked: the view `people` is not queried: its definition names the sensitive column `passwd`."), family.to_s
        expect(text).to include("A view can rename a column past the redaction on #{families.fetch(family).name}", "query the tables it reads")
      end
    end

    it "refuses it in a join, a subquery and an EXPLAIN, and reads a literal as the raw text" do
      [ "SELECT e.id FROM emails e JOIN people p ON p.id = e.id", "SELECT (SELECT p1 FROM people LIMIT 1) AS x",
        "EXPLAIN SELECT * FROM people", "SELECT 'people' AS x" ].each { |sql| expect(refusal(sql)).to include("the view `people`"), sql }
    end

    it "runs a view that names no secret column, and the definition of a refused one" do
      expect(runs?("SELECT * FROM emails")).to be(true)
      expect(runs?("SHOW CREATE VIEW people", :mysql)).to be(true)
    end
  end

  describe "a generated column that reads a secret column" do
    let(:relations) { { "users" => %w[id email passwd tax_number] } }
    let(:generated) { { "users" => { "shadow" => "`passwd`", "taxed" => "`tax_number`" } } }
    let(:encrypted) { %w[tax_number] }

    it "refuses a statement naming it and says how to release it" do
      text = refusal("SELECT shadow FROM users")
      expect(text).to include("sensitive column `shadow`", "`shadow` is a generated column that reads `passwd`")
      expect(text).to include('add "shadow" to config.query_allowed_columns')
    end

    it "says one that reads an encrypts column is not released" do
      expect(refusal("SELECT taxed FROM users"))
        .to include("`taxed` is a generated column that reads `tax_number`", "config.query_allowed_columns does not release it")
    end
  end

  describe "the text to run" do
    def text(sql, family = :sqlite)
      check(sql, family).sql
    end

    it "takes comments out and keeps everything else as written" do
      expect(text("SELECT /* DROP */ 1 AS test")).to eq("SELECT   1 AS test")
      expect(text("SELECT 7 AS n /* a */ -- why")).to eq("SELECT 7 AS n")
      expect(text("SELECT 1 /* open")).to eq("SELECT 1")
      expect(text("SELECT 'a  b' AS v")).to eq("SELECT 'a  b' AS v")
    end

    it "keeps a comment marker inside a literal, a quoted identifier or a dollar quote" do
      [
        "SELECT 'it''s -- fine' AS v", %(SELECT "a--b", `c/*d*/e` FROM t), "SELECT 'see /* draft */ end' AS v",
        "SELECT $tag$a -- b$tag$ AS v", "SELECT $$a /* b */ c$$ AS v", "SELECT $é$a -- b$é$ AS v",
        "SELECT E'\\'', 'x /* y */ z'", "SELECT data\n  #>> '{a,b}' AS v FROM t"
      ].each { |sql| expect(text(sql)).to eq(sql) }
    end

    it "does not read a dollar inside an identifier as a quote" do
      expect(text("SELECT a$b$ -- x $b$\nFROM t")).to eq("SELECT a$b$  \nFROM t")
    end

    it "takes a version comment out whole off MySQL, and keeps what it holds on MySQL" do
      expect(text("SELECT 1 /*!50000 , 2 */")).to eq("SELECT 1")
      expect(text("SELECT 1 /*!50000 , 2 */", :mysql)).to eq("SELECT 1   , 2")
    end

    it "reads a hash comment and a dash-dash needing a space on MySQL alone" do
      expect(text("SELECT 7 AS n # why")).to eq("SELECT 7 AS n # why")
      expect(text("SELECT 7 AS n # why", :mysql)).to eq("SELECT 7 AS n")
      expect(text("SELECT 1 # note\nFROM t", :mysql)).to eq("SELECT 1  \nFROM t")
      expect(text("SELECT 5--3 AS v", :mysql)).to eq("SELECT 5--3 AS v")
      expect(text("SELECT 'it\\'s -- fine' AS v", :mysql)).to eq("SELECT 'it\\'s -- fine' AS v")
    end
  end

  describe "PostgreSQL plan checks" do
    let(:relations) { { "users" => %w[id email password_digest api_token], "posts" => %w[id title] } }

    def plan_refusal(top)
      allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:plan).and_return(top)
      refusal("SELECT * FROM users", :postgresql)
    end

    def scan(output, extra = {})
      { "Node Type" => "Seq Scan", "Relation Name" => "users", "Alias" => "u", "Output" => output }.merge(extra)
    end

    it "refuses a whole row of a relation holding a secret column" do
      expect(plan_refusal(scan([ "row_to_json(u.*)" ]))).to include("whole row of `users`")
    end

    it "runs a whole row of a relation with none" do
      expect(plan_refusal(scan([ "row_to_json(p.*)" ], "Relation Name" => "posts", "Alias" => "p"))).to be_nil
    end

    it "refuses a secret column the planner expanded into a ROW()" do
      expect(plan_refusal(scan([ "ROW(id, email, password_digest, api_token)" ]))).to include("plan uses the sensitive column `password_digest`")
    end

    it "runs a secret column as a plain pass-through output, for redaction to filter" do
      expect(plan_refusal(scan([ "id", "email", "password_digest", "u.api_token" ]))).to be_nil
    end

    it "refuses a secret column used as a filter, and ignores a secret word inside a plan literal" do
      expect(plan_refusal(scan([ "u.id" ], "Filter" => [ "(u.api_token = 'x'::text)" ]))).to include("`api_token`")
      expect(plan_refusal(scan([ "u.id" ], "Filter" => [ "(body ~~ '%api_token%'::text)", "x ~~ 'it''s a secret'::text" ]))).to be_nil
    end

    it "refuses a secret column a child passes through that the top node does not expose" do
      top = { "Node Type" => "CTE Scan", "Output" => [ "c.id", "c.t" ],
              "Plans" => [ { "Node Type" => "Seq Scan", "Relation Name" => "users", "Alias" => "users",
                             "Output" => [ "users.id", "users.api_token" ] } ] }
      expect(plan_refusal(top)).to include("through a CTE, subquery or set operation")
    end

    it "refuses an unlisted VOLATILE function as VOLATILE" do
      allow(connection).to receive(:select_values).and_return([ "nextval" ])
      expect(plan_refusal({ "Node Type" => "Result", "Output" => [ "nextval('s'::regclass)" ] }))
        .to include("function nextval is VOLATILE (pg_proc.provolatile = 'v')")
        .and include("not on rails_query's list of read-only VOLATILE functions")
    end

    it "asks pg_proc nothing when every function named only reads" do
      top = { "Node Type" => "Result", "Output" => [ "pg_total_relation_size('orders')", "pg_database_size('app')", "pg_is_in_recovery()" ] }
      expect(plan_refusal(top)).to be_nil
      expect(connection).not_to have_received(:select_values)
    end

    it "plans the statement a leading EXPLAIN ANALYZE would run" do
      refusal("EXPLAIN ANALYZE SELECT 1 AS x", :postgresql)
      expect(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to have_received(:plan).with(connection, "SELECT 1 AS x", 5)
    end

    it "plans nothing off PostgreSQL" do
      check("SELECT 1 AS x", :mysql)
      expect(RailsAiContext::DatabaseFamily::PostgresqlRuntime).not_to have_received(:plan)
    end

    it "answers the plan with the verdict" do
      expect(check("SELECT 1 AS x", :postgresql).plan).to eq(plan)
    end

    describe "a plan that cannot be read" do
      let(:runtime) { RailsAiContext::DatabaseFamily::PostgresqlRuntime }

      it "refuses the statement when planning answers no plan" do
        allow(runtime).to receive(:plan).and_return(nil)
        [ "SELECT * FROM users", "WITH u AS (SELECT * FROM users) SELECT * FROM u", "EXPLAIN ANALYZE SELECT * FROM users" ].each do |sql|
          expect(refusal(sql, :postgresql)).to include("its plan could not be read"), sql
        end
      end

      it "raises planning's timeout and planning's SQL error for the caller to answer" do
        allow(runtime).to receive(:plan).and_raise(RailsAiContext::DatabaseFamily::TimedOut, "stopped")
        expect { check("SELECT row_to_json(u) FROM users u", :postgresql) }.to raise_error(RailsAiContext::DatabaseFamily::TimedOut)

        allow(runtime).to receive(:plan).and_raise(ActiveRecord::StatementInvalid, "boom")
        expect { check("SELECT nope FROM users", :postgresql) }.to raise_error(ActiveRecord::StatementInvalid)
      end

      it "raises an error from a plan check" do
        allow(connection).to receive(:select_values).and_raise(ActiveRecord::StatementInvalid, "pg_proc unreadable")
        allow(runtime).to receive(:plan).and_return({ "Node Type" => "Result", "Output" => [ "nextval('s'::regclass)" ] })
        expect { check("SELECT nextval('s')", :postgresql) }.to raise_error(ActiveRecord::StatementInvalid)
      end

      it "plans whatever a leading EXPLAIN would run, in either spelling of its options" do
        [ "EXPLAIN VALUES (1)", "EXPLAIN (ANALYZE, VERBOSE) VALUES (1)", "EXPLAIN ANALYZE VERBOSE VALUES (1)" ].each { |sql| check(sql, :postgresql) }
        expect(runtime).to have_received(:plan).with(connection, "VALUES (1)", 5).exactly(3).times

        check("EXPLAIN (ANALYZE) (SELECT 1)", :postgresql)
        expect(runtime).to have_received(:plan).with(connection, "(SELECT 1)", 5)
      end

      # SHOW reads a setting and PostgreSQL has no DESCRIBE, so neither has a plan to read.
      it "runs SHOW, DESCRIBE and DESC with no plan" do
        [ "SHOW server_version", "DESCRIBE users", "DESC users" ].each do |sql|
          verdict = check(sql, :postgresql)
          expect([ verdict.refused?, verdict.plan ]).to eq([ false, nil ]), sql
        end
        expect(runtime).not_to have_received(:plan)
      end
    end
  end
end
