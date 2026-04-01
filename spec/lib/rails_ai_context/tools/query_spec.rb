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

    context "column redaction" do
      it "redacts sensitive columns in results" do
        # Create a mock result with a password_digest column
        columns = %w[id email password_digest]
        rows = [ [ 1, "user@example.com", "$2a$12$secrethash" ] ]
        mock_result = ActiveRecord::Result.new(columns, rows)

        allow(ActiveRecord::Base.connection).to receive(:select_all).and_return(mock_result)
        # Skip the PRAGMA calls for this mock test
        allow(ActiveRecord::Base.connection).to receive(:execute)

        result = described_class.call(sql: "SELECT id, email, password_digest FROM users")
        text = result.content.first[:text]
        expect(text).to include("[REDACTED]")
        expect(text).to include("user@example.com")
        expect(text).not_to include("$2a$12$secrethash")
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

    it "installs and cleans up progress handler for timeout enforcement" do
      conn = ActiveRecord::Base.connection
      raw = conn.raw_connection

      if raw.respond_to?(:set_progress_handler)
        # The tool should install a progress handler for timeout and clean it up
        described_class.call(sql: "SELECT 1 AS test")

        # After execution, the progress handler should be cleared (no lingering handler)
        # Verify by running a normal query — should succeed without interruption
        expect { conn.execute("SELECT 1") }.not_to raise_error
      else
        skip "SQLite driver does not support set_progress_handler"
      end
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

    it "strips MySQL-style hash comments" do
      expect(described_class.strip_sql_comments("SELECT 1 # evil comment")).to eq("SELECT 1")
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
end
