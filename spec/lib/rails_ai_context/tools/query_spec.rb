# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::Query do
  before do
    described_class.reset_cache!
    # Ensure default config for each test
    RailsAiContext.configuration.allow_query_in_production = false
    RailsAiContext.configuration.query_timeout = 5
    RailsAiContext.configuration.query_row_limit = 100
    RailsAiContext.configuration.query_redacted_columns = %w[
      password_digest encrypted_password password_hash
      reset_password_token confirmation_token unlock_token
      otp_secret session_data secret_key
      api_key api_secret access_token refresh_token jti
    ]
    # Reset the allow-list too, so an example that exempts a name cannot leak
    # that exemption into a later example under a random run order.
    RailsAiContext.configuration.query_allowed_columns = []
  end

  describe ".validate_sql" do
    it "allows a valid SELECT" do
      valid, error = described_class.validate_sql("SELECT 1 AS test")
      expect(valid).to be true
      expect(error).to be_nil
    end

    it "blocks INSERT" do
      valid, error = described_class.validate_sql("INSERT INTO users (email) VALUES ('x')")
      expect(valid).to be false
      expect(error).to include("Blocked")
      expect(error).to include("INSERT")
    end

    it "blocks UPDATE" do
      valid, error = described_class.validate_sql("UPDATE users SET email = 'x'")
      expect(valid).to be false
      expect(error).to include("Blocked")
      expect(error).to include("UPDATE")
    end

    it "blocks DELETE" do
      valid, error = described_class.validate_sql("DELETE FROM users")
      expect(valid).to be false
      expect(error).to include("Blocked")
      expect(error).to include("DELETE")
    end

    it "blocks DROP TABLE" do
      valid, error = described_class.validate_sql("DROP TABLE users")
      expect(valid).to be false
      expect(error).to include("Blocked")
      expect(error).to include("DROP")
    end

    it "blocks multi-statement injection" do
      valid, error = described_class.validate_sql("SELECT 1; DROP TABLE users")
      expect(valid).to be false
      expect(error).to include("multiple statements")
    end

    it "blocks FOR UPDATE locking clause" do
      valid, error = described_class.validate_sql("SELECT * FROM users FOR UPDATE")
      expect(valid).to be false
      expect(error).to include("FOR UPDATE/SHARE")
    end

    it "blocks SELECT INTO" do
      valid, error = described_class.validate_sql("SELECT * INTO new_table FROM users")
      expect(valid).to be false
      expect(error).to include("SELECT INTO")
    end

    it "allows WITH...SELECT (CTE)" do
      sql = "WITH active AS (SELECT * FROM users WHERE active = 1) SELECT * FROM active"
      valid, error = described_class.validate_sql(sql)
      expect(valid).to be true
      expect(error).to be_nil
    end

    it "allows EXPLAIN SELECT" do
      valid, error = described_class.validate_sql("EXPLAIN SELECT * FROM users")
      expect(valid).to be true
      expect(error).to be_nil
    end

    it "blocks SHOW GRANTS" do
      valid, error = described_class.validate_sql("SHOW GRANTS FOR 'root'")
      expect(valid).to be false
      expect(error).to include("sensitive SHOW command")
    end

    it "strips SQL comments before validation" do
      # The word DROP inside a comment should be stripped, leaving valid SELECT
      valid, error = described_class.validate_sql("SELECT /* DROP */ 1 AS test")
      expect(valid).to be true
      expect(error).to be_nil
    end

    it "strips line comments before validation" do
      valid, error = described_class.validate_sql("SELECT 1 AS test -- DROP TABLE users")
      expect(valid).to be true
      expect(error).to be_nil
    end

    it "returns error for empty SQL" do
      valid, error = described_class.validate_sql("")
      expect(valid).to be false
      expect(error).to include("required")
    end

    it "blocks OR 1=1 tautology injection" do
      valid, error = described_class.validate_sql("SELECT * FROM users WHERE email = '' OR 1=1 --")
      expect(valid).to be false
      expect(error).to include("SQL injection pattern")
    end

    it "blocks OR true tautology injection" do
      valid, error = described_class.validate_sql("SELECT * FROM users WHERE active = false OR true")
      expect(valid).to be false
      expect(error).to include("SQL injection pattern")
    end

    # A UNION's rows of another table come out under its first SELECT's
    # column names, past redaction by name. MySQL and MariaDB also take
    # `UNION DISTINCT` and a parenthesised branch, which the old pattern missed.
    [
      "SELECT name FROM users UNION SELECT password FROM users",
      "SELECT 1 UNION ALL SELECT 2",
      "SELECT *, 1, 2 FROM posts UNION DISTINCT SELECT * FROM users",
      "SELECT *, 1, 2 FROM posts UNION (SELECT * FROM users)",
      "SELECT *, 1, 2 FROM posts\nunion\n\tall (SELECT * FROM users)",
      "WITH RECURSIVE r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT n FROM r"
    ].each do |sql|
      it "refuses a UNION in every spelling: #{sql.lines.first.strip[0, 60]}" do
        [ { mysql: true }, {}, { postgres: true } ].each do |dialect|
          valid, error = described_class.validate_sql(sql, **dialect)
          expect(valid).to be(false), "#{dialect}: #{error}"
          expect(error).to start_with("Blocked: UNION is not run.")
        end
      end
    end

    it "reads a union inside a string literal as data on PostgreSQL alone" do
      sql = "SELECT id FROM posts WHERE title = 'European Union'"
      expect(described_class.validate_sql(sql, postgres: true)).to eq([ true, nil ])
      expect(described_class.validate_sql(sql, mysql: true).first).to be(false)
    end

    it "keeps INTERSECT and EXCEPT, which return only their first SELECT's rows" do
      expect(described_class.validate_sql("SELECT id FROM posts INTERSECT SELECT id FROM posts").first).to be(true)
      expect(described_class.validate_sql("SELECT id FROM posts EXCEPT SELECT id FROM posts").first).to be(true)
    end

    it "blocks OR with string tautology" do
      valid, error = described_class.validate_sql("SELECT * FROM users WHERE name = 'x' OR 'a'='a'")
      expect(valid).to be false
      expect(error).to include("SQL injection pattern")
    end

    it "allows legitimate OR conditions with column references" do
      valid, error = described_class.validate_sql("SELECT * FROM users WHERE active = true OR admin = true")
      expect(valid).to be true
      expect(error).to be_nil
    end

    it "returns error for nil SQL" do
      valid, error = described_class.validate_sql(nil)
      expect(valid).to be false
      expect(error).to include("required")
    end

    it "blocks ALTER TABLE" do
      valid, error = described_class.validate_sql("ALTER TABLE users ADD COLUMN age INTEGER")
      expect(valid).to be false
      expect(error).to include("ALTER")
    end

    it "blocks TRUNCATE" do
      valid, error = described_class.validate_sql("TRUNCATE users")
      expect(valid).to be false
      expect(error).to include("TRUNCATE")
    end

    it "blocks CREATE" do
      valid, error = described_class.validate_sql("CREATE TABLE evil (id INTEGER)")
      expect(valid).to be false
      expect(error).to include("CREATE")
    end

    it "blocks GRANT" do
      valid, error = described_class.validate_sql("GRANT ALL ON users TO evil")
      expect(valid).to be false
      expect(error).to include("GRANT")
    end

    it "blocks FOR SHARE" do
      valid, error = described_class.validate_sql("SELECT * FROM users FOR SHARE")
      expect(valid).to be false
      expect(error).to include("FOR UPDATE/SHARE")
    end

    it "blocks FOR NO KEY UPDATE" do
      valid, error = described_class.validate_sql("SELECT * FROM users FOR NO KEY UPDATE")
      expect(valid).to be false
      expect(error).to include("FOR UPDATE/SHARE")
    end

    it "allows DESCRIBE" do
      valid, error = described_class.validate_sql("DESCRIBE users")
      expect(valid).to be true
      expect(error).to be_nil
    end

    it "rejects non-allowed prefix" do
      valid, error = described_class.validate_sql("VACUUM users")
      expect(valid).to be false
      expect(error).to include("Only SELECT, WITH, SHOW, EXPLAIN, DESCRIBE allowed")
    end
  end

  describe ".apply_row_limit" do
    it "caps an existing LIMIT above the effective limit" do
      result = described_class.send(:apply_row_limit, "SELECT * FROM users LIMIT 5000", 100)
      expect(result).to include("LIMIT 100")
      expect(result).not_to include("5000")
    end

    it "keeps an existing LIMIT below the effective limit" do
      result = described_class.send(:apply_row_limit, "SELECT * FROM users LIMIT 10", 100)
      expect(result).to include("LIMIT 10")
    end

    it "appends LIMIT when none exists" do
      result = described_class.send(:apply_row_limit, "SELECT * FROM users", 100)
      expect(result).to end_with("LIMIT 100")
    end

    it "strips trailing semicolons when appending LIMIT" do
      result = described_class.send(:apply_row_limit, "SELECT * FROM users;", 100)
      expect(result).to end_with("LIMIT 100")
      expect(result).not_to include(";")
    end

    it "caps FETCH FIRST above the effective limit" do
      result = described_class.send(:apply_row_limit, "SELECT * FROM users FETCH FIRST 5000 ROWS ONLY", 100)
      expect(result).to include("FETCH FIRST 100")
    end

    it "enforces hard cap of 1000" do
      result = described_class.send(:apply_row_limit, "SELECT * FROM users LIMIT 9999", 2000)
      # The cap is [limit, HARD_ROW_CAP].min, so 1000 here
      expect(result).to include("LIMIT 1000")
    end

    # SHOW/DESCRIBE/EXPLAIN are inherently bounded and don't accept a LIMIT
    # clause - appending one turns a valid, explicitly-allowed statement into
    # a syntax error on MySQL/Postgres.
    it "does not append LIMIT to SHOW" do
      result = described_class.send(:apply_row_limit, "SHOW TABLES", 100)
      expect(result).to eq("SHOW TABLES")
    end

    it "does not append LIMIT to DESCRIBE" do
      result = described_class.send(:apply_row_limit, "DESCRIBE products", 100)
      expect(result).to eq("DESCRIBE products")
    end

    it "does not append LIMIT to DESC (DESCRIBE alias)" do
      result = described_class.send(:apply_row_limit, "DESC products", 100)
      expect(result).to eq("DESC products")
    end

    it "does not append LIMIT to EXPLAIN" do
      result = described_class.send(:apply_row_limit, "EXPLAIN SELECT * FROM users", 100)
      expect(result).to eq("EXPLAIN SELECT * FROM users")
    end

    it "matches SHOW/DESCRIBE/EXPLAIN case-insensitively with leading whitespace" do
      result = described_class.send(:apply_row_limit, "  show tables", 100)
      expect(result).to eq("  show tables")
    end
  end

  describe ".call" do
    context "with valid SELECT queries against the Combustion test DB" do
      it "executes SELECT 1 and returns a result" do
        result = described_class.call(sql: "SELECT 1 AS test")
        text = result.content.first[:text]
        expect(text).to include("test")
        expect(text).to include("1")
        expect(text).to include("1 row")
      end

      it "executes multi-column SELECT with expressions" do
        result = described_class.call(sql: "SELECT 42 AS answer, 'hello' AS greeting, 1 + 2 AS sum")
        text = result.content.first[:text]
        expect(text).to include("answer")
        expect(text).to include("42")
        expect(text).to include("greeting")
        expect(text).to include("hello")
        expect(text).to include("sum")
        expect(text).to include("3")
      end

      it "returns markdown table format by default" do
        result = described_class.call(sql: "SELECT 1 AS a, 2 AS b")
        text = result.content.first[:text]
        # Markdown table has pipes and separator row with dashes
        expect(text).to include("|")
        expect(text).to include("| -")
        expect(text).to include("1 row")
      end

      it "returns CSV format when requested" do
        result = described_class.call(sql: "SELECT 1 AS a, 2 AS b", format: "csv")
        text = result.content.first[:text]
        expect(text).to include("a,b")
        expect(text).to include("1,2")
      end

      it "handles NULL values in results" do
        result = described_class.call(sql: "SELECT NULL AS empty_col")
        text = result.content.first[:text]
        expect(text).to include("_NULL_")
      end
    end

    context "with blocked SQL" do
      it "blocks INSERT via .call" do
        result = described_class.call(sql: "INSERT INTO users (email) VALUES ('x@x.com')")
        text = result.content.first[:text]
        expect(text).to include("Blocked")
      end

      it "blocks UPDATE via .call" do
        result = described_class.call(sql: "UPDATE users SET email = 'hacked'")
        text = result.content.first[:text]
        expect(text).to include("Blocked")
      end

      it "blocks DELETE via .call" do
        result = described_class.call(sql: "DELETE FROM users WHERE id = 1")
        text = result.content.first[:text]
        expect(text).to include("Blocked")
      end

      it "blocks DROP TABLE via .call" do
        result = described_class.call(sql: "DROP TABLE users")
        text = result.content.first[:text]
        expect(text).to include("Blocked")
      end

      it "blocks multi-statement via .call" do
        result = described_class.call(sql: "SELECT 1; DROP TABLE users")
        text = result.content.first[:text]
        expect(text).to include("multiple statements")
      end
    end

    context "error flagging" do
      # Postgres words a missing column, a missing table and a missing
      # database the same way, so "does not exist" answered a real SQL error
      # with `bin/rails db:create` advice and exit 0.
      it "flags a Postgres missing column as an error, not a missing database" do
        allow(described_class).to receive(:execute_sqlite)
          .and_raise(ActiveRecord::StatementInvalid,
                     %(PG::UndefinedColumn: ERROR:  column "key_digest" does not exist))

        result = described_class.call(sql: "SELECT key_digest FROM users LIMIT 1")

        expect(result.error?).to be true
        expect(result.content.first[:text]).to include("SQL error:")
        expect(result.content.first[:text]).not_to include("Database not found")
      end

it "reads MySQL's MAX_EXECUTION_TIME interruption as the timeout" do
  allow(described_class).to receive(:execute_sqlite)
    .and_raise(ActiveRecord::StatementInvalid,
               "Mysql2::Error: Query execution was interrupted, maximum statement execution time exceeded")

  result = described_class.call(sql: "SELECT SLEEP(60) FROM tags")

  expect(result.content.first[:text]).to start_with("Query exceeded 5 second timeout")
end

it "still explains a database that does not exist" do
        allow(described_class).to receive(:execute_sqlite)
          .and_raise(ActiveRecord::StatementInvalid,
                     %(PG::UndefinedDatabase: ERROR:  database "racfix_nope" does not exist))

        result = described_class.call(sql: "SELECT 1")

        expect(result.content.first[:text]).to include("Database not found")
        expect(result.error?).to be false
      end

      it "flags genuine SQL execution errors as error results" do
        result = described_class.call(sql: "SELECT definitely_not_a_column FROM users")
        text = result.content.first[:text]
        expect(text).to include("SQL error:")
        expect(result.error?).to be true
      end

      # The same contract every path-taking tool keeps: a refusal on policy is
      # a question left unanswered, so a script reading the exit status can
      # tell it from a result.
      it "flags a policy block as an error result" do
        result = described_class.call(sql: "UPDATE users SET email = 'x'")
        text = result.content.first[:text]
        expect(text).to include("Blocked")
        expect(result.error?).to be true
      end

      it "keeps successful queries unflagged" do
        result = described_class.call(sql: "SELECT 1 AS test")
        expect(result.error?).to be false
      end
    end

    context "with empty or nil SQL" do
      it "returns error for nil sql" do
        result = described_class.call(sql: nil)
        text = result.content.first[:text]
        expect(text).to include("required")
      end

      it "returns error for empty sql" do
        result = described_class.call(sql: "")
        text = result.content.first[:text]
        expect(text).to include("required")
      end
    end

    context "production environment guard" do
      it "blocks in production by default" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        result = described_class.call(sql: "SELECT 1")
        text = result.content.first[:text]
        expect(text).to include("disabled in production")
      end

      it "allows in production when config overrides" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        RailsAiContext.configuration.allow_query_in_production = true
        result = described_class.call(sql: "SELECT 1 AS test")
        text = result.content.first[:text]
        expect(text).to include("test")
        expect(text).to include("1")
      end
    end

    context "sensitive column reference rejection (pre-execution)" do
      # v5.8.1 replaced post-execution redaction with pre-execution rejection.
      # Post-execution redaction runs on `result.columns`, which the caller
      # controls via aliases and expressions - trivially bypassable by
      # `SELECT password_digest AS x FROM users`. Reject at validate_sql instead.

      it "rejects a direct reference to a sensitive column" do
        valid, error = described_class.validate_sql("SELECT id, email, password_digest FROM users")
        expect(valid).to be false
        expect(error).to include("sensitive column")
        expect(error).to include("password_digest")
      end

      it "rejects an aliased reference (SELECT password_digest AS x)" do
        valid, error = described_class.validate_sql("SELECT password_digest AS x FROM users LIMIT 50")
        expect(valid).to be false
        expect(error).to include("password_digest")
      end

      it "rejects a function-wrapped reference (substring)" do
        valid, error = described_class.validate_sql("SELECT substring(password_digest, 1, 60) FROM users")
        expect(valid).to be false
        expect(error).to include("password_digest")
      end

      it "rejects an md5() reference on encrypted/session data" do
        valid, error = described_class.validate_sql("SELECT md5(session_data) FROM sessions")
        expect(valid).to be false
        expect(error).to include("session_data")
      end

      it "rejects a subquery that projects the sensitive column" do
        valid, error = described_class.validate_sql("SELECT v FROM (SELECT password_digest AS v FROM users) sub")
        expect(valid).to be false
        expect(error).to include("password_digest")
      end

      it "rejects CASE expressions that project the sensitive column" do
        valid, error = described_class.validate_sql("SELECT CASE WHEN id > 0 THEN password_digest END FROM users")
        expect(valid).to be false
        expect(error).to include("password_digest")
      end

      it "allows a built-in sensitive name that the app exempts" do
        RailsAiContext.configuration.query_allowed_columns = %w[api_secret]
        valid, error = described_class.validate_sql("SELECT api_secret FROM oauth_applications")
        expect(error).to be_nil
        expect(valid).to be true
      end

      it "keeps blocking the names the app did not exempt" do
        RailsAiContext.configuration.query_allowed_columns = %w[api_secret]
        valid, error = described_class.validate_sql("SELECT password_digest FROM users")
        expect(valid).to be false
        expect(error).to include("password_digest")
      end

      it "exempts case-insensitively" do
        RailsAiContext.configuration.query_allowed_columns = %w[API_SECRET]
        valid, = described_class.validate_sql("SELECT api_secret FROM oauth_applications")
        expect(valid).to be true
      end

      it "rejects references to configured query_redacted_columns" do
        RailsAiContext.configuration.query_redacted_columns = %w[custom_secret_field]
        valid, error = described_class.validate_sql("SELECT custom_secret_field AS y FROM tenants")
        expect(valid).to be false
        expect(error).to include("custom_secret_field")
      ensure
        RailsAiContext.configuration.query_redacted_columns = %w[
          password_digest encrypted_password password_hash
          reset_password_token confirmation_token unlock_token
          otp_secret session_data secret_key
          api_key api_secret access_token refresh_token jti
        ]
      end

      it "does not false-positive on unrelated columns containing a substring" do
        # `keyword` contains "key" as a substring but the match is word-bounded
        # so this should pass. `description` contains "script" - fine.
        valid, error = described_class.validate_sql("SELECT id, keyword, description FROM tags")
        expect(valid).to be true
        expect(error).to be_nil
      end
    end

    context "blocked dangerous functions (filesystem/network primitives)" do
      it "blocks pg_read_file" do
        valid, error = described_class.validate_sql("SELECT pg_read_file('/etc/passwd')")
        expect(valid).to be false
        expect(error).to include("pg_read_file")
      end

      it "blocks pg_read_binary_file" do
        valid, error = described_class.validate_sql("SELECT pg_read_binary_file('/etc/shadow')")
        expect(valid).to be false
        expect(error).to include("pg_read_binary_file")
      end

      it "blocks pg_ls_dir" do
        valid, error = described_class.validate_sql("SELECT pg_ls_dir('/home/dev/.ssh')")
        expect(valid).to be false
        expect(error).to include("pg_ls_dir")
      end

      it "blocks pg_stat_file" do
        valid, error = described_class.validate_sql("SELECT pg_stat_file('/etc/passwd')")
        expect(valid).to be false
        expect(error).to include("pg_stat_file")
      end

      it "blocks lo_import" do
        valid, error = described_class.validate_sql("SELECT lo_import('/etc/passwd')")
        expect(valid).to be false
        expect(error).to include("lo_import")
      end

      it "blocks dblink" do
        valid, error = described_class.validate_sql("SELECT * FROM dblink('host=evil.com', 'SELECT 1') AS t(a int)")
        expect(valid).to be false
        expect(error).to include("dblink")
      end

      it "blocks MySQL LOAD_FILE" do
        valid, error = described_class.validate_sql("SELECT LOAD_FILE('/etc/passwd')")
        expect(valid).to be false
        expect(error).to match(/load_file/i)
      end

      it "blocks MySQL LOAD DATA INFILE" do
        valid, error = described_class.validate_sql("LOAD DATA INFILE '/etc/passwd' INTO TABLE users")
        expect(valid).to be false
        expect(error).to match(/LOAD.*DATA/i)
      end

      it "blocks MySQL LOAD DATA LOCAL INFILE" do
        valid, error = described_class.validate_sql("LOAD DATA LOCAL INFILE '/etc/passwd' INTO TABLE users")
        expect(valid).to be false
        expect(error).to match(/LOAD.*DATA/i)
      end

      it "blocks SQLite load_extension" do
        valid, error = described_class.validate_sql("SELECT load_extension('/tmp/lib.so')")
        expect(valid).to be false
        expect(error).to include("load_extension")
      end

      it "blocks SELECT INTO OUTFILE (MySQL)" do
        valid, error = described_class.validate_sql("SELECT 1 INTO OUTFILE '/tmp/leak.txt'")
        expect(valid).to be false
        expect(error).to eq("Blocked: SELECT INTO OUTFILE / DUMPFILE writes to disk")
      end
    end

    context "row limit enforcement via .call" do
      it "caps row limit at hard cap 1000" do
        # Pass limit higher than hard cap
        result = described_class.call(sql: "SELECT 1 AS test", limit: 5000)
        text = result.content.first[:text]
        # Should succeed (just a single row), but the LIMIT was capped
        expect(text).to include("test")
      end
    end
  end

  describe "SQLite PRAGMA query_only enforcement" do
    it "blocks real writes at the database level" do
      conn = ActiveRecord::Base.connection

      # Create a temp table to test against
      conn.execute("CREATE TABLE IF NOT EXISTS _query_tool_test (val TEXT)")

      begin
        # Enable PRAGMA query_only and verify writes are blocked
        conn.execute("PRAGMA query_only = ON")
        expect {
          conn.execute("INSERT INTO _query_tool_test (val) VALUES ('should_fail')")
        }.to raise_error(ActiveRecord::StatementInvalid, /attempt to write a readonly database/)
      ensure
        conn.execute("PRAGMA query_only = OFF")
        conn.execute("DROP TABLE IF EXISTS _query_tool_test")
      end
    end

    it "says an in-memory database runs without a time limit" do
      text = described_class.call(sql: "SELECT 1 AS test").content.first[:text]
      expect(text).to include("| 1")
      expect(text).to include("without a time limit")
    end

    it "says so for EXPLAIN too, and keeps CSV free of it" do
      explain = described_class.call(sql: "SELECT 1 AS test", explain: true).content.first[:text]
      csv = described_class.call(sql: "SELECT 1 AS test", format: "csv").content.first[:text]

      expect(explain).to include("EXPLAIN Analysis")
      expect(explain).to include("without a time limit")
      expect(csv).not_to include("without a time limit")
    end

    it "resets PRAGMA query_only after query execution" do
      conn = ActiveRecord::Base.connection

      # Create a temp table
      conn.execute("CREATE TABLE IF NOT EXISTS _query_tool_reset_test (val TEXT)")

      begin
        # Run a query through the tool (uses PRAGMA internally)
        described_class.call(sql: "SELECT 1 AS test")

        # After the tool runs, writes should work again (PRAGMA was reset)
        expect {
          conn.execute("INSERT INTO _query_tool_reset_test (val) VALUES ('should_succeed')")
        }.not_to raise_error
      ensure
        conn.execute("DROP TABLE IF EXISTS _query_tool_reset_test")
      end
    end
  end

  describe "SQLite timeout on a file-backed database" do
    let(:dir) { Dir.mktmpdir }
    let(:conn) do
      stub_const("QueryTimeoutSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      QueryTimeoutSpecRecord.establish_connection(adapter: "sqlite3", database: File.join(dir, "t.sqlite3"))
      QueryTimeoutSpecRecord.connection.tap do |c|
        c.execute("CREATE TABLE nums (n INTEGER)")
        c.execute("INSERT INTO nums VALUES (1), (2), (3)")
        c.execute("CREATE TABLE big (n INTEGER)")
        c.execute("INSERT INTO big WITH RECURSIVE r(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM r WHERE x < 2000) SELECT x FROM r")
      end
    end
    let(:slow_sql) do
      "SELECT count(*) AS n FROM big a, big b, (SELECT * FROM big LIMIT 100) c"
    end

    before { allow(ActiveRecord::Base).to receive(:connection).and_return(conn) }

    after do
      QueryTimeoutSpecRecord.remove_connection
      FileUtils.rm_rf(dir)
    end

    it "stops a long query at query_timeout with the timeout message" do
      RailsAiContext.configuration.query_timeout = 1
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      text = described_class.call(sql: slow_sql).content.first[:text]

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      expect(text).to start_with("Query exceeded 1 second timeout")
    end

    it "returns the same rows as the in-process connection" do
      sql = "SELECT n, n * 2 AS twice FROM nums ORDER BY n"
      result = described_class.send(:execute_sqlite, conn, sql, 5)

      expect(result.columns).to eq(conn.select_all(sql).columns)
      expect(result.rows).to eq(conn.select_all(sql).rows)
    end

    it "returns rows under the UTF-8 default_internal a Rails app sets" do
      internal = Encoding.default_internal
      Encoding.default_internal = Encoding::UTF_8
      result = described_class.send(:execute_sqlite, conn, "SELECT count(*) AS n FROM big", 5)
      expect(result.rows).to eq([ [ 2000 ] ])
    ensure
      Encoding.default_internal = internal
    end

    it "refuses a write" do
      expect {
        described_class.send(:execute_sqlite, conn, "INSERT INTO nums VALUES (4)", 5)
      }.to raise_error(ActiveRecord::StatementInvalid, /readonly/)
      expect(conn.select_value("SELECT count(*) FROM nums")).to eq(3)
    end

    it "reports a SQL error the way the in-process path does" do
      expect {
        described_class.send(:execute_sqlite, conn, "SELECT nope FROM nums", 5)
      }.to raise_error(ActiveRecord::StatementInvalid, /\ASQLite3::SQLException: no such column: nope/)
    end

    it "does not say the query is unbounded" do
      text = described_class.call(sql: "SELECT n FROM nums").content.first[:text]
      expect(text).not_to include("without a time limit")
    end

    def elapsed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    it "kills the child when the parent fails while waiting" do
      pids = []
      allow(Process).to receive(:wait).and_wrap_original { |m, pid| pids << pid; m.call(pid) }
      allow(IO).to receive(:select).and_raise(IOError, "stream closed")

      took = elapsed do
        expect { described_class.send(:execute_sqlite, conn, slow_sql, 5) }.to raise_error(IOError)
      end

      expect(took).to be < 3
      expect { Process.kill(0, pids.first) }.to raise_error(Errno::ESRCH)
    end

    it "reads an impossible length prefix as a missing result" do
      calls = 0
      allow(described_class).to receive(:read_before).and_wrap_original do |m, *args|
        calls += 1
        calls == 1 ? [ 1 << 62 ].pack("Q>") : m.call(*args)
      end

      expect {
        described_class.send(:execute_sqlite, conn, "SELECT n FROM nums", 5)
      }.to raise_error(ActiveRecord::StatementInvalid, /exited without a result/)
    end

    it "reads a garbled result as a missing result" do
      allow(Marshal).to receive(:load).and_raise(ArgumentError, "marshal data too short")
      expect {
        described_class.send(:execute_sqlite, conn, "SELECT n FROM nums", 5)
      }.to raise_error(ActiveRecord::StatementInvalid, /exited without a result/)
    end

    it "waits on another process's write lock as the app connection would" do
      conn.execute("PRAGMA journal_mode = DELETE")
      writer = IO.popen([ RbConfig.ruby, "-rsqlite3", "-e", <<~RUBY, File.join(dir, "t.sqlite3") ])
        db = SQLite3::Database.new(ARGV[0])
        db.execute("BEGIN EXCLUSIVE")
        db.execute("INSERT INTO nums VALUES (9)")
        $stdout.puts "locked"
        $stdout.flush
        sleep 0.5
        db.execute("COMMIT")
      RUBY
      expect(writer.gets).to eq("locked\n")

      result = described_class.send(:execute_sqlite, conn, "SELECT count(*) AS n FROM nums", 5)
      expect(result.rows).to eq([ [ 4 ] ])
    ensure
      writer&.close
    end

    it "reruns in-process, without a time limit, what only the app connection can answer" do
      conn.raw_connection.create_function("rac_twice", 1) { |func, x| func.result = x * 2 }
      text = described_class.call(sql: "SELECT rac_twice(n) AS t FROM nums ORDER BY n").content.first[:text]

      expect(text).to include("| 6")
      expect(text).to include("without a time limit")
    end

    it "loads the extensions database.yml names into the child" do
      if Gem::Version.new(SQLite3::VERSION) < Gem::Version.new("2.4")
        skip "sqlite3 #{SQLite3::VERSION} ignores extensions:, in the child as in the app's own connection"
      end

      missing = File.join(dir, "rac_missing_ext")
      allow(conn.pool.db_config).to receive(:configuration_hash)
        .and_return(conn.pool.db_config.configuration_hash.merge(extensions: [ missing ]))

      expect {
        described_class.send(:execute_sqlite, conn, "SELECT n FROM nums", 5)
      }.to raise_error(ActiveRecord::StatementInvalid, /rac_missing_ext/)
    end

    it "ends a child whose fork hooks raise instead of letting it run on" do
      spec_pid = Process.pid
      marker = File.join(dir, "child_ran_on")
      allow(Process).to receive(:kill)
      hook = ActiveSupport::ForkTracker.after_fork { raise "fork hook failed" }
      begin
        expect {
          described_class.send(:execute_sqlite, conn, "SELECT n FROM nums", 5)
        }.to raise_error(ActiveRecord::StatementInvalid, /exited without a result/)
      ensure
        if Process.pid != spec_pid
          File.write(marker, "")
          exit!(2)
        end
        ActiveSupport::ForkTracker.unregister(hook)
      end
      expect(File.exist?(marker)).to be false
    end

    context "when another process inherits the query's pipe" do
      let(:sleepers) { [] }

      before do
        allow(IO).to receive(:pipe).and_wrap_original do |m|
          pipe = m.call
          sleepers << Process.fork do
            sleep 4
            exit!(0)
          end
          pipe
        end
      end

      after do
        sleepers.each do |pid|
          Process.kill(:KILL, pid)
          Process.wait(pid)
        end
      end

      it "returns a fast result without waiting for that process" do
        result = nil
        took = elapsed { result = described_class.send(:execute_sqlite, conn, "SELECT n FROM nums ORDER BY n", 5) }

        expect(result.rows).to eq([ [ 1 ], [ 2 ], [ 3 ] ])
        expect(took).to be < 2
      end

      it "still stops a slow query at the deadline" do
        took = elapsed do
          expect { described_class.send(:execute_sqlite, conn, slow_sql, 1) }
            .to raise_error(ActiveRecord::StatementInvalid, /timeout/)
        end
        expect(took).to be < 2
      end
    end

    it "does not hand one query's pipe to another query's child" do
      RailsAiContext.configuration.query_timeout = 2
      first = true
      allow(IO).to receive(:pipe).and_wrap_original do |m|
        pipe = m.call
        if first
          first = false
          sleep 0.3
        end
        pipe
      end

      fast = Thread.new { elapsed { described_class.send(:execute_sqlite, conn, "SELECT n FROM nums", 2) } }
      sleep 0.1
      slow = Thread.new do
        described_class.send(:execute_sqlite, conn, slow_sql, 2)
      rescue ActiveRecord::StatementInvalid
        nil
      end

      expect(fast.value).to be < 1.5
      slow.join
    end
  end

  describe "query_allowed_columns in result redaction" do
    before { RailsAiContext.configuration.query_allowed_columns = %w[secret api_secret] }
    after { RailsAiContext.configuration.query_allowed_columns = [] }

    it "returns an allowed column that the name heuristic would redact" do
      text = described_class.call(sql: "SELECT 7 AS secret").content.first[:text]
      expect(text).to include("| 7")
      expect(text).not_to include("[FILTERED]")
    end

    it "returns an allowed column that query_redacted_columns lists" do
      text = described_class.call(sql: "SELECT 7 AS api_secret").content.first[:text]
      expect(text).not_to include("[FILTERED]")
    end

    it "still redacts an allowed column declared with encrypts" do
      allow(described_class).to receive(:cached_context).and_return(models: { "Thing" => { encrypts: %w[secret] } })
      text = described_class.call(sql: "SELECT 7 AS secret").content.first[:text]
      expect(text).to include("[FILTERED]")
    end
  end

  describe ".strip_sql_comments" do
    it "strips block comments" do
      expect(described_class.strip_sql_comments("SELECT /* evil */ 1")).to eq("SELECT 1")
    end

    it "strips line comments" do
      expect(described_class.strip_sql_comments("SELECT 1 -- evil")).to eq("SELECT 1")
    end

    it "strips multiline block comments" do
      sql = "SELECT /* this\nis\nmultiline */ 1"
      expect(described_class.strip_sql_comments(sql)).to eq("SELECT 1")
    end

    it "strips MySQL-style hash comments at line start" do
      expect(described_class.strip_sql_comments("# full line comment\nSELECT 1", mysql: true)).to eq("SELECT 1")
    end

    it "preserves hash characters inside SQL strings" do
      sql = "SELECT '#'; DROP TABLE users"
      result = described_class.strip_sql_comments(sql)
      expect(result).to include("DROP TABLE")
    end

    it "preserves PostgreSQL JSONB operators" do
      sql = "SELECT data #>> '{key}' FROM records"
      result = described_class.strip_sql_comments(sql)
      expect(result).to include("#>>")
    end

    it "unwraps MySQL version-conditional comments so their content is visible to validation" do
      # MySQL executes /*!version ... */ content even though it looks like a comment.
      # strip_sql_comments must expose the inside or BLOCKED_FUNCTIONS will miss it.
      sql = "SELECT /*!50000 LOAD_FILE('/etc/passwd') */ AS x"
      result = described_class.strip_sql_comments(sql, mysql: true)
      expect(result).to include("LOAD_FILE")
    end

    it "unwraps bare executable comments without version digits" do
      sql = "SELECT /*! pg_read_file('foo') */ 1"
      result = described_class.strip_sql_comments(sql, mysql: true)
      expect(result).to include("pg_read_file")
    end
  end

  describe "the text that runs is the text that was validated" do
    def answer(sql, **opts)
      described_class.call(sql: sql, **opts).content.first[:text]
    end

    it "refuses a sensitive column that follows a comment marker in a string literal" do
      text = answer("SELECT '--' AS m, api_key AS x FROM (SELECT 'leak' AS api_key) t")

      expect(text).to include("sensitive column `api_key`")
      expect(text).not_to include("leak")
    end

    it "refuses a second statement that follows a comment marker in a string literal" do
      expect(answer("SELECT '--' AS m; SELECT 2 AS hidden")).to include("multiple statements")
    end

    it "still answers a query that carries an ordinary comment" do
      expect(answer("SELECT 7 AS n -- why")).to include("7")
    end

    def sent_to_the_database(sql)
      sent = nil
      allow(described_class).to receive(:run_guarded) { |_conn, _adapter, text, _timeout|
        sent = text
        ActiveRecord::Result.new(%w[n], [ [ 1 ] ])
      }
      described_class.call(sql: sql)
      sent
    end

    it "sends the database the text without its comments, the limit on a line of its own" do
      expect(sent_to_the_database("SELECT 7 AS n /* a */ -- why")).to eq("SELECT 7 AS n\nLIMIT 100")
    end

    it "reads a hash comment on a MySQL connection and nowhere else" do
      sql = "SELECT 7 AS n # why"

      expect(sent_to_the_database(sql)).to eq("SELECT 7 AS n # why\nLIMIT 100")

      allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(double(adapter: "trilogy"))
      expect(sent_to_the_database(sql)).to eq("SELECT 7 AS n\nLIMIT 100")
    end

    # A comment marker inside quotes is data. Taking it out changed the answer
    # without an error, which is worse than refusing the query.
    it "leaves a block comment marker inside a string literal alone" do
      expect(answer("SELECT 'see /* draft */ end' AS v")).to include("see /* draft */ end")
    end

    it "leaves glob patterns that hold both halves of a block comment alone" do
      text = answer("SELECT 'src/app.rb' GLOB 'src/*' AS a, 'x' GLOB '*/x' AS b")

      expect(text).to match(/\| a +\| b +\|/)
    end

    it "leaves a line comment marker inside a string literal alone" do
      expect(answer("SELECT 'x -- y' AS v")).to include("x -- y")
    end

    it "leaves the spacing inside a string literal alone" do
      expect(answer("SELECT 'a  b' AS v")).to include("a  b")
    end
  end

  describe ".comment_free" do
    it "keeps an escaped quote inside a string literal" do
      sql = "SELECT 'it''s -- fine' AS v"

      expect(described_class.comment_free(sql)).to eq(sql)
    end

    it "keeps a quoted identifier that holds a comment marker" do
      sql = %(SELECT "a--b", `c/*d*/e` FROM t)

      expect(described_class.comment_free(sql)).to eq(sql)
    end

    it "ends an unterminated block comment at the end of the text" do
      expect(described_class.comment_free("SELECT 1 /* open")).to eq("SELECT 1")
    end

    # PostgreSQL has no hash comment, and a hash starts four of its operators.
    it "keeps a line that starts with a hash operator" do
      sql = "SELECT data\n  #>> '{a,b}' AS v FROM t"

      expect(described_class.comment_free(sql)).to eq(sql)
    end

    it "keeps a dollar-quoted string that holds a comment marker" do
      [ "SELECT $tag$a -- b$tag$ AS v", "SELECT $$a /* b */ c$$ AS v", "SELECT $é$a -- b$é$ AS v" ].each do |sql|
        expect(described_class.comment_free(sql)).to eq(sql)
      end
    end

    it "does not read a dollar inside an identifier as a quote" do
      expect(described_class.comment_free("SELECT a$b$ -- x $b$\nFROM t")).to eq("SELECT a$b$  \nFROM t")
    end

    it "reads a backslash as an escape in a PostgreSQL E string" do
      sql = "SELECT E'\\'', 'x /* y */ z'"

      expect(described_class.comment_free(sql)).to eq(sql)
    end

    # Only MySQL runs what it holds; anywhere else it is a comment.
    it "takes a version comment out whole" do
      expect(described_class.comment_free("SELECT 1 /*!50000 , 2 */")).to eq("SELECT 1")
    end

    context "for MySQL" do
      it "keeps what a version comment holds, for the checks to read" do
        expect(described_class.comment_free("SELECT 1 /*!50000 , 2 */", mysql: true)).to eq("SELECT 1   , 2")
      end

      it "takes a hash comment out wherever it starts" do
        expect(described_class.comment_free("SELECT 1 # note\nFROM t", mysql: true)).to eq("SELECT 1  \nFROM t")
      end

      it "reads two dashes with nothing after them as an expression" do
        expect(described_class.comment_free("SELECT 5--3 AS v", mysql: true)).to eq("SELECT 5--3 AS v")
      end

      it "keeps a backslash-escaped quote inside a string literal" do
        sql = "SELECT 'it\\'s -- fine' AS v"

        expect(described_class.comment_free(sql, mysql: true)).to eq(sql)
      end
    end
  end

  describe "the row limit" do
    def rows(sql, limit:)
      described_class.call(sql: sql, limit: limit).content.first[:text][/(\d+) rows? returned/, 1].to_i
    end

    let(:three) { "(VALUES (1),(2),(3)) v" }

    it "holds when the query ends in a line comment" do
      expect(rows("SELECT * FROM #{three} -- trailing note", limit: 2)).to eq(2)
    end

    it "holds when the only LIMIT is inside a comment" do
      expect(rows("SELECT * FROM #{three} /* LIMIT 3 */", limit: 2)).to eq(2)
    end

    it "holds when the query ends in a block comment nobody closed" do
      expect(rows("SELECT * FROM #{three} /*", limit: 2)).to eq(2)
    end

    it "holds when a string literal holds the word LIMIT, and leaves the literal as written" do
      text = described_class.call(sql: "SELECT 'LIMIT 5' AS note, column1 FROM #{three}", limit: 2).content.first[:text]

      expect(text).to include("2 rows returned")
      expect(text).to include("LIMIT 5")
    end

    it "holds when only a subquery has a LIMIT" do
      expect(rows("SELECT column1 FROM #{three} WHERE column1 IN (SELECT 1 LIMIT 1) OR column1 > 0", limit: 2)).to eq(2)
    end

    it "leaves a subquery's own LIMIT as written" do
      sql = described_class.send(:apply_row_limit, "SELECT * FROM (SELECT id FROM t LIMIT 500) q", 100)

      expect(sql).to include("LIMIT 500")
      expect(sql).to end_with("LIMIT 100")
    end

    it "caps the count of a MySQL offset-and-count LIMIT, not the offset" do
      expect(described_class.send(:apply_row_limit, "SELECT * FROM t LIMIT 10, 5000", 100)).to end_with("LIMIT 10, 100")
    end

    it "caps FETCH NEXT as it does FETCH FIRST" do
      sql = "SELECT * FROM t OFFSET 5 ROWS FETCH NEXT 5000 ROWS ONLY"

      expect(described_class.send(:apply_row_limit, sql, 100)).to end_with("FETCH NEXT 100 ROWS ONLY")
    end

    # A second LIMIT would be a syntax error on a query that ran before.
    it "sends a limit it cannot rewrite as written" do
      [ "SELECT * FROM t LIMIT 1+1", "SELECT * FROM t LIMIT (2)", "SELECT * FROM t FETCH FIRST 5 ROWS WITH TIES" ].each do |sql|
        expect(described_class.send(:apply_row_limit, sql, 100)).to eq(sql)
      end
    end

    it "still answers a query whose limit is an expression" do
      expect(rows("SELECT * FROM #{three} LIMIT 1+1", limit: 5)).to eq(2)
    end

    it "caps a LIMIT that an OFFSET follows" do
      expect(described_class.send(:apply_row_limit, "SELECT * FROM t LIMIT 5000 OFFSET 20", 100)).to end_with("LIMIT 100 OFFSET 20")
    end

    # Whatever the text says, the answer never carries more rows than asked for.
    it "drops rows the database returned past the limit" do
      allow(described_class).to receive(:run_guarded).and_return(ActiveRecord::Result.new(%w[n], [ [ 1 ], [ 2 ], [ 3 ] ]))

      expect(rows("SELECT n FROM t", limit: 2)).to eq(2)
    end
  end

  describe "SQL validation with hash in string literals" do
    it "blocks destructive SQL hidden after hash in string literal" do
      valid, error = described_class.validate_sql("SELECT '#'; DROP TABLE users")
      expect(valid).to be false
      expect(error).to include("Blocked")
    end
  end

  describe "MySQL executable-comment bypass defense" do
    it "blocks LOAD_FILE hidden inside /*!50000 ... */" do
      valid, error = described_class.validate_sql("SELECT /*!50000 LOAD_FILE('/etc/passwd') */ AS x")
      expect(valid).to be false
      expect(error).to include("Blocked").and include("load_file").or include("LOAD_FILE")
    end

    it "blocks pg_read_file hidden inside /*! ... */" do
      valid, error = described_class.validate_sql("SELECT /*! pg_read_file('/etc/passwd') */ AS x")
      expect(valid).to be false
      expect(error).to include("Blocked")
    end

    it "blocks dblink hidden inside /*!80000 ... */" do
      valid, error = described_class.validate_sql("SELECT /*!80000 dblink('host=evil', 'SELECT * FROM users') */ 1")
      expect(valid).to be false
      expect(error).to include("Blocked")
    end

    it "allows normal queries that happen to contain /* ... */ comments" do
      valid, _error = described_class.validate_sql("SELECT /* author: alice */ 1 AS x")
      expect(valid).to be true
    end
  end

  describe "EXPLAIN mode" do
    it "returns EXPLAIN QUERY PLAN output for SELECT" do
      result = described_class.call(sql: "SELECT 1 AS test", explain: true)
      text = result.content.first[:text]
      expect(text).to include("EXPLAIN Analysis")
      expect(text).to include("Raw Plan")
    end

    it "returns EXPLAIN for a real table query" do
      result = described_class.call(sql: "SELECT name FROM sqlite_master", explain: true)
      text = result.content.first[:text]
      expect(text).to include("EXPLAIN Analysis")
      expect(text).to include("SCAN")
    end

    it "detects full table scan" do
      result = described_class.call(sql: "SELECT name FROM sqlite_master", explain: true)
      text = result.content.first[:text]
      expect(text).to include("full table scan").or include("SCAN")
    end

    it "rejects non-SELECT queries with explain" do
      result = described_class.call(sql: "SHOW tables", explain: true)
      text = result.content.first[:text]
      expect(text).to include("EXPLAIN only supports SELECT")
    end

    it "does not apply row limit to EXPLAIN output" do
      result = described_class.call(sql: "SELECT 1 AS test", explain: true)
      text = result.content.first[:text]
      expect(text).not_to include("LIMIT")
    end

    it "shows query in the output" do
      result = described_class.call(sql: "SELECT name FROM sqlite_master WHERE type = 'table'", explain: true)
      text = result.content.first[:text]
      expect(text).to include("SELECT name FROM sqlite_master")
    end

    it "standard query is unaffected when explain is false" do
      result = described_class.call(sql: "SELECT 1 AS test", explain: false)
      text = result.content.first[:text]
      expect(text).to include("test")
      expect(text).to include("1 row")
      expect(text).not_to include("EXPLAIN Analysis")
    end

    it "routes through the adapter safety wrapper (READ ONLY + timeout)" do
      # Load-bearing: PostgreSQL `EXPLAIN (FORMAT JSON, ANALYZE) ...` actually
      # executes the query plan. Without routing through execute_postgresql /
      # execute_mysql / execute_sqlite, EXPLAIN bypasses SET TRANSACTION READ
      # ONLY + statement_timeout / PRAGMA query_only. This spy confirms the
      # adapter wrapper is called on the SQLite test connection - for PG/MySQL
      # the same routing logic applies via the `case adapter` branch.
      expect(described_class).to receive(:execute_sqlite).once.and_call_original
      described_class.call(sql: "SELECT 1 AS test", explain: true)
    end

    it "parses SQLite EXPLAIN QUERY PLAN scan types" do
      result = described_class.call(sql: "SELECT name FROM sqlite_master WHERE type = 'table'", explain: true)
      text = result.content.first[:text]
      expect(text).to include("Scan Summary").or include("Raw Plan")
    end

    it "handles WITH (CTE) query in explain mode" do
      result = described_class.call(sql: "WITH t AS (SELECT 1 AS x) SELECT * FROM t", explain: true)
      text = result.content.first[:text]
      expect(text).to include("EXPLAIN Analysis")
    end

    it "rejects blocked SQL even with explain" do
      result = described_class.call(sql: "INSERT INTO users (email) VALUES ('x')", explain: true)
      text = result.content.first[:text]
      expect(text).to include("Blocked")
    end
  end

  describe "Trilogy adapter dispatch" do
    # Rails 8's default MySQL adapter reports adapter_name "Trilogy", not
    # "Mysql2". Every place that dispatches on adapter name must match both,
    # or Trilogy apps silently skip the READ ONLY transaction + statement
    # timeout and fall through to the unsafe "unknown adapter" path.
    before do
      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("Trilogy")
    end

    it "routes regular queries through the MySQL safety wrapper, not the unknown-adapter fallback" do
      fake_result = ActiveRecord::Result.new(%w[x], [ [ 1 ] ])
      expect(described_class).to receive(:execute_mysql).and_return(fake_result)

      result = described_class.call(sql: "SELECT 1 AS x")
      expect(result.content.first[:text]).to include("1")
    end

    it "issues EXPLAIN FORMAT=TRADITIONAL (not the bare EXPLAIN MySQL 8.3+/9.x would render as TREE)" do
      explain_result = ActiveRecord::Result.new(
        %w[id select_type table type possible_keys key key_len ref rows filtered Extra],
        [ [ 1, "SIMPLE", "products", "ALL", nil, nil, nil, nil, 5, 100.0, "" ] ]
      )
      expect(described_class).to receive(:execute_mysql)
        .with(anything, a_string_matching(/\AEXPLAIN FORMAT=TRADITIONAL SELECT/), anything)
        .and_return(explain_result)

      result = described_class.call(sql: "SELECT * FROM products WHERE sku = 'x'", explain: true)
      text = result.content.first[:text]
      expect(text).to include("EXPLAIN Analysis")
      expect(text).to include("full table scan")
    end
  end

  describe "PostGIS adapter dispatch" do
    # activerecord-postgis-adapter reports adapter_name "PostGIS" for a PostgreSQL
    # connection, which gets the same READ ONLY transaction and statement timeout.
    before do
      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("PostGIS")
    end

    it "routes regular queries through the PostgreSQL safety wrapper" do
      expect(described_class).to receive(:execute_postgresql).and_return(ActiveRecord::Result.new(%w[x], [ [ 1 ] ]))

      expect(described_class.call(sql: "SELECT 1 AS x").content.first[:text]).to include("1")
    end

    it "asks PostgreSQL for its JSON plan" do
      expect(described_class).to receive(:execute_postgresql)
        .with(anything, a_string_matching(/\AEXPLAIN \(FORMAT JSON, ANALYZE\) SELECT/), anything)
        .and_return(ActiveRecord::Result.new(%w[QUERY\ PLAN], [ [ "[]" ] ]))

      described_class.call(sql: "SELECT 1 AS x", explain: true)
    end
  end

  describe "redaction skip for schema-metadata statements" do
    # MySQL's DESCRIBE returns a literal column named "Key" (PRI/UNI/MUL) -
    # not actual secret data, but it matches the generic sensitive-suffix
    # heuristic (ends_with "key") used to redact real query results, so
    # DESCRIBE/SHOW/EXPLAIN output must skip column-name-based redaction
    # entirely.
    it "does not redact DESCRIBE's Key column" do
      fake_result = ActiveRecord::Result.new(
        %w[Field Type Null Key Default Extra],
        [ [ "id", "bigint", "NO", "PRI", nil, "auto_increment" ] ]
      )
      expect(described_class).to receive(:execute_sqlite).and_return(fake_result)

      result = described_class.call(sql: "DESCRIBE products")
      text = result.content.first[:text]
      expect(text).to include("PRI")
      expect(text).not_to include("[FILTERED]")
    end

    it "still redacts sensitive columns for plain SELECT queries" do
      # "cache_key" ends with the generic sensitive suffix "key" but isn't in
      # the pre-execution textual blocklist, so it reaches post-execution
      # redaction rather than being rejected outright - unlike DESCRIBE's
      # "Key" column, this one really is a data column and must be redacted.
      fake_result = ActiveRecord::Result.new(%w[id cache_key], [ [ 1, "sekret" ] ])
      expect(described_class).to receive(:execute_sqlite).and_return(fake_result)

      result = described_class.call(sql: "SELECT id, cache_key FROM users")
      text = result.content.first[:text]
      expect(text).to include("[FILTERED]")
      expect(text).not_to include("sekret")
    end
  end

  describe "MySQL execution (execute_mysql)" do
    # The Combustion test app runs on SQLite, so execute_mysql is exercised
    # against a fake connection that enforces MySQL's rule: transaction
    # characteristics cannot change once a transaction is in progress
    # (error 1568, ER_CANT_CHANGE_TX_CHARACTERISTICS). Rails materializes
    # the lazy BEGIN before the first in-block statement reaches the server,
    # so a SET TRANSACTION issued inside `conn.transaction` always arrives
    # mid-transaction and fails. Regression coverage for #89.
    let(:query_result) { ActiveRecord::Result.new(%w[x], [ [ 1 ] ]) }

    let(:fake_mysql_conn_class) do
      Class.new do
        attr_reader :statements

        def initialize(result)
          @result = result
          @statements = []
          @in_transaction = false
        end

        def execute(sql)
          if @in_transaction && sql.match?(/\ASET\s+TRANSACTION/i)
            raise ActiveRecord::StatementInvalid,
              "Mysql2::Error: Transaction characteristics can't be changed " \
              "while a transaction is in progress"
          end
          @statements << sql
        end

        def transaction
          @statements << "BEGIN"
          @in_transaction = true
          yield
          @statements << "COMMIT"
        rescue ActiveRecord::Rollback
          @statements << "ROLLBACK"
        ensure
          @in_transaction = false
        end

        def select_all(sql)
          @statements << sql
          @result
        end
      end
    end

    let(:conn) { fake_mysql_conn_class.new(query_result) }

    it "issues SET TRANSACTION READ ONLY before the transaction opens" do
      result = described_class.send(:execute_mysql, conn, "SELECT 1 AS x", 5)

      expect(result).to eq(query_result)
      set_index = conn.statements.index { |s| s.match?(/\ASET\s+TRANSACTION READ ONLY/i) }
      begin_index = conn.statements.index("BEGIN")
      expect(set_index).not_to be_nil
      expect(begin_index).not_to be_nil
      expect(set_index).to be < begin_index
    end

    it "injects the MAX_EXECUTION_TIME hint for the per-query timeout" do
      described_class.send(:execute_mysql, conn, "SELECT 1 AS x", 5)

      select = conn.statements.find { |s| s.match?(/\ASELECT/i) }
      expect(select).to include("MAX_EXECUTION_TIME(5000)")
    end

    it "rolls the transaction back instead of committing" do
      described_class.send(:execute_mysql, conn, "SELECT 1 AS x", 5)

      expect(conn.statements).to include("ROLLBACK")
      expect(conn.statements).not_to include("COMMIT")
    end
  end

  describe "MariaDB statement timeout (execute_mysql)" do
    # MariaDB ignores MySQL's MAX_EXECUTION_TIME hint, so a long query would run
    # unbounded and hold the connection. It is bounded with MariaDB's own
    # `SET STATEMENT max_statement_time = <seconds> FOR <query>`, which scopes the
    # limit to the one statement (no session setting to restore on the pool).
    let(:query_result) { ActiveRecord::Result.new(%w[x], [ [ 1 ] ]) }
    let(:conn) do
      Class.new do
        attr_reader :statements
        def initialize(result)
          @result = result
          @statements = []
        end

        def mariadb? = true
        def execute(sql) = @statements << sql

        def transaction
          @statements << "BEGIN"
          yield
        rescue ActiveRecord::Rollback
          @statements << "ROLLBACK"
        end

        def select_all(sql)
          @statements << sql
          @result
        end
      end.new(query_result)
    end

    it "bounds the query with SET STATEMENT max_statement_time, not the MySQL hint" do
      described_class.send(:execute_mysql, conn, "SELECT 1 AS x\nLIMIT 100", 5)

      select = conn.statements.find { |s| s.include?("SELECT 1 AS x") }
      expect(select).to start_with("SET STATEMENT max_statement_time=5.0 FOR ")
      expect(select).not_to include("MAX_EXECUTION_TIME")
    end

    it "still issues SET TRANSACTION READ ONLY before the transaction and rolls back" do
      described_class.send(:execute_mysql, conn, "SELECT 1 AS x", 5)

      set_index = conn.statements.index { |s| s.match?(/\ASET TRANSACTION READ ONLY/i) }
      expect(set_index).to be < conn.statements.index("BEGIN")
      expect(conn.statements).to include("ROLLBACK")
    end

    it "reads MariaDB's max_statement_time interruption as the timeout" do
      allow(described_class).to receive(:execute_sqlite)
        .and_raise(ActiveRecord::StatementInvalid,
                   "Mysql2::Error: Query execution was interrupted (max_statement_time exceeded)")

      text = described_class.call(sql: "SELECT SLEEP(8)").content.first[:text]
      expect(text).to start_with("Query exceeded 5 second timeout")
    end
  end

  describe "CSV format" do
    it "escapes newlines in cell values" do
      columns = %w[id note]
      rows = [ [ 1, "line1\nline2" ] ]
      mock_result = ActiveRecord::Result.new(columns, rows)

      allow(ActiveRecord::Base.connection).to receive(:select_all).and_return(mock_result)
      allow(ActiveRecord::Base.connection).to receive(:execute)

      result = described_class.call(sql: "SELECT id, note FROM notes", format: "csv")
      text = result.content.first[:text]
      # Newline-containing value should be quoted
      expect(text).to include('"line1')
    end
  end

  describe "graceful degradation when ActiveRecord is not loaded" do
    # Simulates `rails new --api --skip-active-record` where Ruby cannot
    # resolve `ActiveRecord::*` rescue constants at raise time, causing a
    # NameError unless the tool guards the entry point. See the edge-case
    # verification report from v5.8.0 pre-release E2E.
    it "returns a friendly message instead of crashing with NameError" do
      result = with_activerecord_hidden { described_class.call(sql: "SELECT 1") }
      text = result.content.first[:text]
      expect(text).to include("Database queries are unavailable")
      expect(text).to include("ActiveRecord is not loaded")
      expect(text).to include("--skip-active-record")
    end

    # Temporarily hides the top-level `ActiveRecord` constant so
    # `defined?(ActiveRecord::Base)` returns nil inside the block. Restores
    # it in an ensure regardless of exceptions raised by the block.
    def with_activerecord_hidden
      saved = Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
      yield
    ensure
      Object.const_set(:ActiveRecord, saved) if saved
    end
  end

  # ── Security hardening (rails_query bypass classes) ───────────────
  describe "session-effecting / administrative functions" do
    # These run under SET TRANSACTION READ ONLY and keep their effect on the
    # pooled connection. The name blocklist is the first layer; PostgreSQL's
    # VOLATILE-function plan check is the robust one (proven against a live DB).
    %w[
      pg_terminate_backend pg_cancel_backend pg_reload_conf pg_stat_reset
      pg_create_restore_point pg_logical_emit_message pg_advisory_lock
      pg_notify set_config txid_current pg_switch_wal pg_promote
      pg_drop_replication_slot pg_replication_origin_create
    ].each do |fn|
      it "blocks PostgreSQL admin function #{fn}" do
        valid, error = described_class.validate_sql("SELECT #{fn}(1)")
        expect(valid).to be false
        expect(error).to include("administrative function #{fn}")
      end
    end

    %w[GET_LOCK RELEASE_LOCK RELEASE_ALL_LOCKS IS_FREE_LOCK IS_USED_LOCK].each do |fn|
      it "blocks MySQL session function #{fn}" do
        valid, error = described_class.validate_sql("SELECT #{fn}('x')")
        expect(valid).to be false
        expect(error).to include("session function #{fn}")
      end
    end

    it "does not trip on a table or column that merely contains a blocked name" do
      # `set_configuration` is not `set_config(`, `lock_version` is not GET_LOCK(.
      valid, = described_class.validate_sql("SELECT lock_version, set_configuration FROM widgets")
      expect(valid).to be true
    end
  end

  describe "column-alias list rejection" do
    it "blocks a CTE column list" do
      valid, error = described_class.validate_sql("WITH t(a,b,c) AS (SELECT * FROM users) SELECT * FROM t")
      expect(valid).to be false
      expect(error).to include("column-alias list")
    end

    it "blocks a table-alias column list" do
      valid, error = described_class.validate_sql("SELECT * FROM users AS u(a,b,c,d,e)")
      expect(valid).to be false
      expect(error).to include("column-alias list")
    end

    it "blocks a derived-table column list" do
      valid, error = described_class.validate_sql("SELECT * FROM (SELECT * FROM users) AS t(a,b,c)")
      expect(valid).to be false
      expect(error).to include("column-alias list")
    end

    it "blocks a table alias column list without AS" do
      valid, error = described_class.validate_sql("SELECT * FROM users u(a,b,c,d)")
      expect(valid).to be false
      expect(error).to include("column-alias list")
    end

    # A type modifier is digits, a record-function list carries types, a
    # function call is followed by AS-name not AS-(, a single alias is not a
    # rename of several columns - none is a column-alias list.
    it "allows a CAST with a parameterised type" do
      valid, = described_class.validate_sql("SELECT CAST(amount AS numeric(10,2)) AS a FROM orders")
      expect(valid).to be true
    end

    it "allows a varchar length modifier" do
      valid, = described_class.validate_sql("SELECT id::varchar(255) AS v FROM users")
      expect(valid).to be true
    end

    it "allows a multi-argument function call aliased with AS" do
      valid, = described_class.validate_sql("SELECT coalesce(first_name, last_name) AS nm FROM users")
      expect(valid).to be true
    end

    it "allows a record-returning function with a typed column list" do
      valid, = described_class.validate_sql("SELECT * FROM json_to_recordset('[]') AS t(a int, b text)")
      expect(valid).to be true
    end

    it "allows a single-column set-returning-function alias" do
      valid, = described_class.validate_sql("SELECT * FROM generate_series(1,5) AS g(n)")
      expect(valid).to be true
    end
  end

  describe "schema-aware sensitive column rejection" do
    # The combustion users table has no sensitive columns, so the real column
    # set is stubbed to one an app would have - the heuristic catches api_token
    # / auth_token, which the fixed name list does not.
    before do
      allow(described_class).to receive(:real_column_names)
        .and_return(Set.new(%w[id email name api_token auth_token]))
    end

    it "blocks a schema column caught only by the heuristic, through an alias" do
      valid, error = described_class.validate_sql("SELECT api_token AS c FROM users")
      expect(valid).to be false
      expect(error).to include("api_token")
    end

    it "blocks it through an expression" do
      valid, error = described_class.validate_sql("SELECT upper(auth_token) FROM users")
      expect(valid).to be false
      expect(error).to include("auth_token")
    end

    it "blocks it in a subquery projection" do
      valid, error = described_class.validate_sql("SELECT (SELECT api_token FROM users LIMIT 1) AS leaked")
      expect(valid).to be false
      expect(error).to include("api_token")
    end

    it "does not trip on a non-sensitive real column" do
      valid, = described_class.validate_sql("SELECT id, email, name FROM users")
      expect(valid).to be true
    end

    it "exempts a schema column the app allows by name" do
      RailsAiContext.configuration.query_allowed_columns = %w[api_token]
      valid, = described_class.validate_sql("SELECT api_token FROM users")
      expect(valid).to be true
    ensure
      RailsAiContext.configuration.query_allowed_columns = []
    end
  end

  describe "a table or alias that merely contains a sensitive word" do
    before do
      allow(described_class).to receive(:real_column_names)
        .and_return(Set.new(%w[id name api_token]))
    end

    it "is not a sensitive column reference" do
      # `tokens` the table, `secrets` the alias - neither is a real column name.
      valid, = described_class.validate_sql("SELECT t.id FROM tokens t WHERE t.id > 0")
      expect(valid).to be true
    end
  end

  describe ".sensitive_column?" do
    it "flags names the heuristic catches" do
      %w[password_digest api_token auth_token remember_token user_secret signing_key sha_hash].each do |c|
        expect(described_class.sensitive_column?(c)).to be(true), "expected #{c} sensitive"
      end
    end

    it "does not flag ordinary columns" do
      %w[id email name status ssn created_at user_id lock_version].each do |c|
        expect(described_class.sensitive_column?(c)).to be(false), "expected #{c} not sensitive"
      end
    end

    it "exempts an allowed name" do
      RailsAiContext.configuration.query_allowed_columns = %w[api_token]
      expect(described_class.sensitive_column?("api_token")).to be false
    ensure
      RailsAiContext.configuration.query_allowed_columns = []
    end
  end

  describe "Rails bookkeeping tables are never sensitive" do
    # ar_internal_metadata.key ends in "key"; leaving it in the sensitive set
    # refused every query whose text held the word "key" (a column, a JSON key,
    # a LIKE pattern). These tables are excluded on every adapter.
    before do
      allow(described_class).to receive(:columns_from_connection).and_return(nil)
      allow(described_class).to receive(:cached_context).and_return(
        schema: { tables: {
          "ar_internal_metadata" => { columns: [ { name: "key" }, { name: "value" } ] },
          "schema_migrations" => { columns: [ { name: "version" } ] },
          "widgets" => { columns: [ { name: "id" }, { name: "api_token" } ] }
        } }
      )
    end

    it "leaves their columns out of the real column set" do
      cols = described_class.send(:real_column_names)
      expect(cols).to include("api_token")
      expect(cols).not_to include("key")
      expect(cols).not_to include("version")
    end

    it "does not refuse a query naming a bookkeeping column" do
      valid, = described_class.validate_sql("SELECT key, value FROM ar_internal_metadata")
      expect(valid).to be true
    end

    it "leaves them out of the per-relation map the plan check reads" do
      expect(described_class.send(:relation_sensitive_columns)).not_to have_key("ar_internal_metadata")
    end
  end

  describe "a sensitive name inside a string literal" do
    describe ".mask_sql_literals (textual, PostgreSQL)" do
      it "blanks single-quoted, E, U& and dollar-quoted literals" do
        expect(described_class.mask_sql_literals("WHERE b LIKE '%secret%'")).not_to include("secret")
        expect(described_class.mask_sql_literals("x = E'\\'api_token'")).not_to include("api_token")
        expect(described_class.mask_sql_literals("$$ api_token $$")).not_to include("api_token")
        expect(described_class.mask_sql_literals("$t$ api_token $t$")).not_to include("api_token")
      end

      it "leaves a double-quoted identifier alone" do
        expect(described_class.mask_sql_literals('SELECT "api_token"')).to include("api_token")
      end

      # A quote inside an identifier opened a "literal" that ran to the next
      # quote and hid the column between them.
      it "does not open a literal at a quote inside a double-quoted identifier" do
        masked = described_class.mask_sql_literals(%(SELECT 1 AS "a'b", upper(api_token), 'x' FROM users))
        expect(masked).to eq(%(SELECT 1 AS "a'b", upper(api_token), '' FROM users))
      end

      it "takes no dollar quote from a positional parameter" do
        expect(described_class.mask_sql_literals("WHERE id = $1 AND api_token = $1")).to include("api_token")
      end
    end

    describe ".mask_plan_literals (plan expressions)" do
      it "blanks a quote-doubled constant and keeps identifiers" do
        expect(described_class.send(:mask_plan_literals, "(body ~~ '%api_token%'::text)")).not_to include("api_token")
        expect(described_class.send(:mask_plan_literals, "x ~~ 'it''s a secret'::text")).not_to include("secret")
        expect(described_class.send(:mask_plan_literals, "users.api_token")).to include("api_token")
      end
    end

    it "validate_sql(postgres: true) passes a sensitive name that is only inside a literal" do
      valid, = described_class.validate_sql("SELECT id FROM posts WHERE body LIKE '%secret%'", postgres: true)
      expect(valid).to be true
    end

    it "validate_sql (default, non-postgres) still refuses the same literal" do
      valid, error = described_class.validate_sql("SELECT id FROM posts WHERE body LIKE '%secret%'")
      expect(valid).to be false
      expect(error).to include("secret")
    end

    it "validate_sql(postgres: true) still refuses a real identifier beside a literal" do
      valid, error = described_class.validate_sql("SELECT 'x' || api_secret AS y FROM t", postgres: true)
      expect(valid).to be false
      expect(error).to include("api_secret")
    end

    it "the plan check ignores a sensitive word inside a plan literal" do
      allow(described_class).to receive(:schema_sensitive_columns).and_return(%w[api_token])
      exprs = described_class.send(:plan_expressions, [ { "Filter" => [ "(body ~~ '%api_token%'::text)" ] } ])
      expect(described_class.send(:sensitive_column_in_plan, exprs)).to be_nil
    end
  end

  describe ".unvouched_literal_refusal (plan vouch)" do
    let(:sql) { "SELECT id FROM posts WHERE body LIKE '%secret%'" }

    it "allows a literal-only sensitive name when the plan was obtained" do
      allow(described_class).to receive(:pg_plan).and_return("Node Type" => "Result")
      expect(described_class.send(:unvouched_literal_refusal, sql, true)).to be_nil
    end

    it "refuses a literal-only sensitive name when the plan could not be obtained" do
      allow(described_class).to receive(:pg_plan).and_return(nil)
      expect(described_class.send(:unvouched_literal_refusal, sql, true)).to include("secret")
    end

    it "is a no-op on a non-postgres adapter" do
      expect(described_class.send(:unvouched_literal_refusal, "SELECT 'x' AS a WHERE b LIKE '%secret%'", false)).to be_nil
    end

    it "is a no-op when no sensitive name is present at all" do
      expect(described_class.send(:unvouched_literal_refusal, "SELECT id FROM posts", true)).to be_nil
    end
  end

  describe "PostgreSQL plan analysis helpers" do
    # Unit-level coverage of the plan walk; the live-database behaviour is
    # proven end-to-end against a real PostgreSQL 16 in the F2a report.
    let(:aliases) { { "u" => "users", "p" => "posts" } }

    before do
      allow(described_class).to receive(:relation_sensitive_columns)
        .and_return("users" => %w[password_digest api_token])
      allow(described_class).to receive(:schema_sensitive_columns)
        .and_return(%w[password_digest api_token])
    end

    it "flags a whole-row reference to a sensitive relation" do
      exprs = { all: [ "row_to_json(u.*)" ], outputs: [ "row_to_json(u.*)" ], conds: [] }
      expect(described_class.send(:whole_row_leak, exprs, aliases)).to eq("users")
    end

    it "allows a whole-row reference to a non-sensitive relation" do
      exprs = { all: [ "row_to_json(p.*)" ], outputs: [ "row_to_json(p.*)" ], conds: [] }
      expect(described_class.send(:whole_row_leak, exprs, aliases)).to be_nil
    end

    it "flags a sensitive column the planner expanded into a ROW()" do
      exprs = { all: [], outputs: [ "ROW(id, email, password_digest, api_token)" ], conds: [] }
      expect(described_class.send(:sensitive_column_in_plan, exprs)).to eq("password_digest")
    end

    it "allows a sensitive column as a plain pass-through output" do
      exprs = { all: [], outputs: [ "id", "email", "password_digest", "users.api_token" ], conds: [] }
      expect(described_class.send(:sensitive_column_in_plan, exprs)).to be_nil
    end

    it "flags a sensitive column used as a filter oracle" do
      exprs = { all: [], outputs: [ "id" ], conds: [ "(users.api_token = 'x'::text)" ] }
      expect(described_class.send(:sensitive_column_in_plan, exprs)).to eq("api_token")
    end

    it "returns nil for a non-postgres adapter" do
      expect(described_class.send(:postgresql_plan_refusal, "SELECT * FROM users", 5)).to be_nil
    end
  end

  describe "renamed sensitive column (view / CTE / subquery)" do
    # A view that renames a sensitive column defeats name redaction; EXPLAIN
    # VERBOSE expands the view, so the base column is visible in the plan. The
    # live PostgreSQL behaviour (real views via psql) is in the F2a report.
    let(:aliases) { { "users" => "users", "u" => "users", "p" => "posts" } }

    before do
      allow(described_class).to receive(:relation_sensitive_columns)
        .and_return("users" => %w[api_token password_digest])
    end

    describe ".base_var" do
      it "resolves a qualified Var to its base relation and column" do
        expect(described_class.send(:base_var, "users.api_token", aliases)).to eq([ "users", "api_token" ])
      end

      it "ignores a set-operation's quoted, spaced alias" do
        expect(described_class.send(:base_var, '"*SELECT* 1".t', aliases)).to be_nil
      end

      it "ignores a bare column (handled by name redaction) and an expression" do
        expect(described_class.send(:base_var, "api_token", aliases)).to be_nil
        expect(described_class.send(:base_var, "upper(users.api_token)", aliases)).to be_nil
      end
    end

    describe ".plan_output_sensitive_indices" do
      before do
        allow(described_class).to receive(:postgres_adapter?).and_return(true)
        allow(described_class).to receive(:plan_alias_map)
          .and_return("users" => "users", "u" => "users", "p" => "posts", "posts" => "posts")
      end

      def indices(output, columns)
        allow(described_class).to receive(:pg_plan).and_return("Output" => output)
        result = ActiveRecord::Result.new(columns, [])
        described_class.send(:plan_output_sensitive_indices, "SELECT ...", result)
      end

      it "redacts the result column whose top Output position is a sensitive base Var" do
        expect(indices([ "users.id", "users.api_token" ], %w[id t])).to eq([ 1 ])
      end

      it "maps a join's renamed column by position" do
        expect(indices([ "p.title", "users.api_token" ], %w[title t])).to eq([ 1 ])
      end

      it "ignores trailing sort keys past the result width" do
        expect(indices([ "users.api_token", "users.id" ], %w[t])).to eq([ 0 ])
      end

      it "does not redact a non-sensitive relation's view column" do
        expect(indices([ "posts.id", "posts.title" ], %w[id heading])).to eq([])
      end
    end

    describe ".laundered_sensitive_column" do
      it "flags a sensitive base Var in a child that the top node does not expose" do
        plan = {
          "Node Type" => "CTE Scan", "Output" => [ "c.id", "c.t" ],
          "Plans" => [ { "Node Type" => "Seq Scan", "Relation Name" => "users",
                        "Alias" => "users", "Output" => [ "users.id", "users.api_token" ] } ]
        }
        nodes = []
        described_class.send(:collect_plan_nodes, plan, nodes)
        a = described_class.send(:plan_alias_map, nodes)
        expect(described_class.send(:laundered_sensitive_column, plan, nodes, a)).to eq("api_token")
      end

      it "does not flag a sensitive base Var the top node exposes (redacted instead)" do
        plan = {
          "Node Type" => "Seq Scan", "Relation Name" => "users", "Alias" => "users",
          "Output" => [ "users.id", "users.api_token" ]
        }
        nodes = []
        described_class.send(:collect_plan_nodes, plan, nodes)
        a = described_class.send(:plan_alias_map, nodes)
        expect(described_class.send(:laundered_sensitive_column, plan, nodes, a)).to be_nil
      end
    end
  end

  describe "silent-truncation note" do
    def answer(sql, **opts)
      described_class.call(sql: sql, **opts).content.first[:text]
    end

    before do
      allow(described_class).to receive(:run_guarded)
        .and_return(ActiveRecord::Result.new(%w[n], (1..150).map { |i| [ i ] }))
    end

    it "says rows were held back in the table format" do
      text = answer("SELECT n FROM big", limit: 100)
      expect(text).to include("100 rows shown; the query returned at least this many")
      expect(text).to include("pass limit: up to 1000")
    end

    it "says so in the CSV format, after a blank line outside the block" do
      text = answer("SELECT n FROM big", limit: 100, format: "csv")
      expect(text).to match(/\n\n100 rows shown; the query returned at least this many/)
    end

    it "names the hard cap when the cap is 1000" do
      allow(described_class).to receive(:run_guarded)
        .and_return(ActiveRecord::Result.new(%w[n], (1..1000).map { |i| [ i ] }))
      expect(answer("SELECT n FROM big", limit: 5000)).to include("the 1000-row hard cap")
    end

    it "does not add the note when the result is under the limit" do
      allow(described_class).to receive(:run_guarded)
        .and_return(ActiveRecord::Result.new(%w[n], [ [ 1 ], [ 2 ] ]))
      expect(answer("SELECT n FROM big", limit: 100)).not_to include("rows shown; the query returned")
    end
  end

  describe "result redaction by provenance" do
    it "redacts an output column flagged by provenance whatever its name" do
      result = ActiveRecord::Result.new(%w[a b c], [ [ 1, "secret-value", 3 ] ])
      redacted = described_class.send(:redact_results, result, [ 1 ])
      expect(redacted.rows.first).to eq([ 1, RailsAiContext::Redaction::FILTERED, 3 ])
    end
  end

  describe "a DO block is refused for the right reason" do
    it "is refused as a disallowed statement, not as multiple statements" do
      valid, error = described_class.validate_sql("DO $$ BEGIN PERFORM 1; END $$")
      expect(valid).to be false
      expect(error).not_to include("multiple statements")
      expect(error).to include("Only SELECT")
    end

    it "still blocks a genuine second statement after a dollar-quoted literal" do
      valid, error = described_class.validate_sql("SELECT $$a$$ AS v; DROP TABLE users")
      expect(valid).to be false
      expect(error).to include("multiple statements")
    end
  end

  describe ".mask_quoted" do
    it "blanks a dollar-quoted body so its semicolon is not a separator" do
      masked = described_class.mask_quoted("DO $$ BEGIN PERFORM 1; END $$")
      expect(masked).not_to include(";")
      expect(masked).to start_with("DO ")
    end

    it "keeps a semicolon that really separates statements" do
      masked = described_class.mask_quoted("SELECT '--' AS m; SELECT 2")
      expect(masked).to include(";")
    end
  end
end
