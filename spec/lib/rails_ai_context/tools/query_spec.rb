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

    it "blocks UNION SELECT injection" do
      valid, error = described_class.validate_sql("SELECT name FROM users UNION SELECT password FROM users")
      expect(valid).to be false
      expect(error).to include("SQL injection pattern")
    end

    it "blocks UNION ALL SELECT injection" do
      valid, error = described_class.validate_sql("SELECT 1 UNION ALL SELECT 2")
      expect(valid).to be false
      expect(error).to include("SQL injection pattern")
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
      # apply_row_limit uses [limit, HARD_ROW_CAP].min, so effective_limit = 1000
      expect(result).to include("LIMIT 1000")
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
      # controls via aliases and expressions — trivially bypassable by
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
        # so this should pass. `description` contains "script" — fine.
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

      it "blocks SQLite load_extension" do
        valid, error = described_class.validate_sql("SELECT load_extension('/tmp/lib.so')")
        expect(valid).to be false
        expect(error).to include("load_extension")
      end

      it "blocks SELECT INTO OUTFILE (MySQL)" do
        valid, error = described_class.validate_sql("SELECT 1 INTO OUTFILE '/tmp/leak.txt'")
        expect(valid).to be false
        expect(error).to match(/OUTFILE|SELECT INTO/)
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

    it "executes queries successfully without progress handler support" do
      raw = ActiveRecord::Base.connection.raw_connection

      # sqlite3 gem 2.x removed set_progress_handler; verify the timeout
      # enforcement path degrades gracefully (query still runs, no error)
      expect(raw.respond_to?(:set_progress_handler)).to be false
      response = described_class.call(sql: "SELECT 1 AS test")
      expect(response).to be_a(MCP::Tool::Response)
      expect(response.content.first[:text]).to include("test")
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
      expect(described_class.strip_sql_comments("# full line comment\nSELECT 1")).to eq("SELECT 1")
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
  end

  describe "SQL validation with hash in string literals" do
    it "blocks destructive SQL hidden after hash in string literal" do
      valid, error = described_class.validate_sql("SELECT '#'; DROP TABLE users")
      expect(valid).to be false
      expect(error).to include("Blocked")
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
end
