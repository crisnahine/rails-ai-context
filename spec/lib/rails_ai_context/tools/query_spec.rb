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

  # The text asks for one row past the cap, so a result the cap cut can be
  # told from one that fit; the extra row is dropped.
  describe "the row limit in the text sent to the database" do
    def sent(sql, limit: 100)
      text = nil
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only) { |_conn, sent_sql, _timeout|
        text = sent_sql
        ActiveRecord::Result.new(%w[n], [ [ 1 ] ])
      }
      described_class.call(sql: sql, limit: limit)
      text
    end

    it "caps a LIMIT above the limit one row past it, and keeps one at or below it" do
      expect(sent("SELECT * FROM users LIMIT 5000")).to eq("SELECT * FROM users LIMIT 101")
      expect(sent("SELECT * FROM users LIMIT 10")).to eq("SELECT * FROM users LIMIT 10")
      expect(sent("SELECT * FROM users LIMIT 100")).to eq("SELECT * FROM users LIMIT 100")
    end

    it "appends a LIMIT on a line of its own when none exists, after any trailing semicolon" do
      expect(sent("SELECT * FROM users")).to eq("SELECT * FROM users\nLIMIT 101")
      expect(sent("SELECT * FROM users;")).to eq("SELECT * FROM users\nLIMIT 101")
    end

    it "caps FETCH FIRST and FETCH NEXT" do
      expect(sent("SELECT * FROM users FETCH FIRST 5000 ROWS ONLY")).to end_with("FETCH FIRST 101 ROWS ONLY")
      expect(sent("SELECT * FROM t OFFSET 5 ROWS FETCH NEXT 5000 ROWS ONLY")).to end_with("FETCH NEXT 101 ROWS ONLY")
    end

    it "holds the 1000-row hard cap" do
      expect(sent("SELECT * FROM users LIMIT 9999", limit: 2000)).to end_with("LIMIT 1001")
    end

    it "caps the count of a MySQL offset-and-count LIMIT, and a LIMIT an OFFSET follows" do
      expect(sent("SELECT * FROM t LIMIT 10, 5000")).to end_with("LIMIT 10, 101")
      expect(sent("SELECT * FROM t LIMIT 5000 OFFSET 20")).to end_with("LIMIT 101 OFFSET 20")
    end

    it "leaves a subquery's own LIMIT as written" do
      expect(sent("SELECT * FROM (SELECT id FROM t LIMIT 500) q")).to eq("SELECT * FROM (SELECT id FROM t LIMIT 500) q\nLIMIT 101")
    end

    # A second LIMIT would be a syntax error on a query that ran before.
    it "sends a limit it cannot rewrite as written" do
      [ "SELECT * FROM t LIMIT 1+1", "SELECT * FROM t LIMIT (2)", "SELECT * FROM t FETCH FIRST 5 ROWS WITH TIES" ].each do |sql|
        expect(sent(sql)).to eq(sql)
      end
    end

    it "holds LIMIT ALL, LIMIT NULL and a negative limit to the cap, as no limit of the query's own" do
      expect(sent("SELECT * FROM t LIMIT ALL")).to eq("SELECT * FROM t LIMIT 101")
      expect(sent("SELECT * FROM t LIMIT null")).to eq("SELECT * FROM t LIMIT 101")
      expect(sent("SELECT * FROM t LIMIT -1")).to eq("SELECT * FROM t LIMIT 101")
      expect(sent("SELECT * FROM t LIMIT ALL OFFSET 5")).to eq("SELECT * FROM t LIMIT 101 OFFSET 5")
      expect(sent("SELECT * FROM t LIMIT 5, -1")).to eq("SELECT * FROM t LIMIT 5, 101")
    end

    it "adds no LIMIT to SHOW, DESCRIBE, DESC or EXPLAIN" do
      [ "SHOW TABLES", "DESCRIBE products", "DESC products", "EXPLAIN SELECT * FROM users", "  show tables" ].each do |sql|
        expect(sent(sql)).to eq(sql.strip)
      end
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
        allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
          .and_raise(ActiveRecord::StatementInvalid,
                     %(PG::UndefinedColumn: ERROR:  column "key_digest" does not exist))

        result = described_class.call(sql: "SELECT key_digest FROM users LIMIT 1")

        expect(result.error?).to be true
        expect(result.content.first[:text]).to include("SQL error:")
        expect(result.content.first[:text]).not_to include("Database not found")
      end

      it "answers the family's timeout as the timeout" do
        allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_raise(RailsAiContext::DatabaseFamily::TimedOut, "stopped")

        result = described_class.call(sql: "SELECT SLEEP(60) FROM tags")

        expect(result.content.first[:text]).to start_with("Query exceeded 5 second timeout")
        expect(result.error?).to be false
      end

      it "flags an SQL error that mentions a timeout as an error, not a timeout" do
        allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
          .and_raise(ActiveRecord::StatementInvalid, "Mysql2::Error: Unknown column 'timeout' (maximum statement execution time exceeded)")

        result = described_class.call(sql: "SELECT timeout FROM tags")

        expect(result.content.first[:text]).to start_with("SQL error:")
        expect(result.error?).to be true
      end

      it "refuses an adapter with no family by its adapter's name and sends no statement" do
        conn = ActiveRecord::Base.connection
        allow(conn).to receive(:adapter_name).and_return("SQLServer")
        %i[execute select_all select_value select_rows exec_query columns tables transaction].each do |sent|
          allow(conn).to receive(sent).and_raise("#{sent} reached the database")
        end

        result = described_class.call(sql: "SELECT 1 AS x")

        expect(result.error?).to be true
        expect(result.content.first[:text]).to include("refuses the SQLServer adapter")
      end

      it "still explains a database that does not exist" do
        allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
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

  # The timeout runs the query in a forked child it can kill. Windows has no
  # fork, so there the query runs in this process, unbounded: the example
  # below this group says so on every platform.
  describe "SQLite timeout on a file-backed database",
           skip: (Process.respond_to?(:fork) ? false : "the SQLite timeout runs the query in a forked child, and this platform has no fork") do
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
      result = RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, sql, timeout: 5)

      expect(result.columns).to eq(conn.select_all(sql).columns)
      expect(result.rows).to eq(conn.select_all(sql).rows)
    end

    it "returns rows under the UTF-8 default_internal a Rails app sets" do
      internal = Encoding.default_internal
      Encoding.default_internal = Encoding::UTF_8
      result = RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT count(*) AS n FROM big", timeout: 5)
      expect(result.rows).to eq([ [ 2000 ] ])
    ensure
      Encoding.default_internal = internal
    end

    it "refuses a write" do
      expect {
        RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "INSERT INTO nums VALUES (4)", timeout: 5)
      }.to raise_error(ActiveRecord::StatementInvalid, /readonly/)
      expect(conn.select_value("SELECT count(*) FROM nums")).to eq(3)
    end

    it "reports a SQL error the way the in-process path does" do
      expect {
        RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT nope FROM nums", timeout: 5)
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
        expect { RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, slow_sql, timeout: 5) }.to raise_error(IOError)
      end

      expect(took).to be < 3
      expect { Process.kill(0, pids.first) }.to raise_error(Errno::ESRCH)
    end

    it "reads an impossible length prefix as a missing result" do
      calls = 0
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_before).and_wrap_original do |m, *args|
        calls += 1
        calls == 1 ? [ 1 << 62 ].pack("Q>") : m.call(*args)
      end

      expect {
        RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT n FROM nums", timeout: 5)
      }.to raise_error(ActiveRecord::StatementInvalid, /exited without a result/)
    end

    it "reads a garbled result as a missing result" do
      allow(Marshal).to receive(:load).and_raise(ArgumentError, "marshal data too short")
      expect {
        RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT n FROM nums", timeout: 5)
      }.to raise_error(ActiveRecord::StatementInvalid, /exited without a result/)
    end

    it "waits on another process's write lock as the app connection would" do
      conn.execute("PRAGMA journal_mode = DELETE")
      # The bundle first, so the writer has the sqlite3 this process has,
      # whatever newer one is installed beside it.
      writer = IO.popen([ RbConfig.ruby, "-rbundler/setup", "-rsqlite3", "-e", <<~RUBY, File.join(dir, "t.sqlite3") ])
        db = SQLite3::Database.new(ARGV[0])
        db.execute("BEGIN EXCLUSIVE")
        db.execute("INSERT INTO nums VALUES (9)")
        $stdout.puts "locked"
        $stdout.flush
        sleep 0.5
        db.execute("COMMIT")
      RUBY
      expect(writer.gets).to eq("locked\n")

      result = RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT count(*) AS n FROM nums", timeout: 5)
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
        RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT n FROM nums", timeout: 5)
      }.to raise_error(ActiveRecord::StatementInvalid, /rac_missing_ext/)
    end

    it "ends a child whose fork hooks raise instead of letting it run on" do
      spec_pid = Process.pid
      marker = File.join(dir, "child_ran_on")
      allow(Process).to receive(:kill)
      hook = ActiveSupport::ForkTracker.after_fork { raise "fork hook failed" }
      begin
        expect {
          RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT n FROM nums", timeout: 5)
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
        took = elapsed { result = RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT n FROM nums ORDER BY n", timeout: 5) }

        expect(result.rows).to eq([ [ 1 ], [ 2 ], [ 3 ] ])
        expect(took).to be < 2
      end

      it "still stops a slow query at the deadline" do
        took = elapsed do
          expect { RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, slow_sql, timeout: 1) }
            .to raise_error(RailsAiContext::DatabaseFamily::TimedOut)
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

      fast = Thread.new { elapsed { RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT n FROM nums", timeout: 2) } }
      sleep 0.1
      slow = Thread.new do
        RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, slow_sql, timeout: 2)
      rescue RailsAiContext::DatabaseFamily::TimedOut
        nil
      end

      expect(fast.value).to be < 1.5
      slow.join
    end
  end

  # Where there is no fork (Windows), a file-backed database gets no
  # timeout: the query runs in this process, and the answer says so.
  describe "SQLite on a file-backed database where the platform has no fork" do
    let(:dir) { Dir.mktmpdir }
    let(:conn) do
      stub_const("QueryNoForkSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      QueryNoForkSpecRecord.establish_connection(adapter: "sqlite3", database: File.join(dir, "t.sqlite3"))
      QueryNoForkSpecRecord.connection.tap do |c|
        c.execute("CREATE TABLE nums (n INTEGER)")
        c.execute("INSERT INTO nums VALUES (1), (2), (3)")
      end
    end

    before do
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
      allow(Process).to receive(:respond_to?).and_call_original
      allow(Process).to receive(:respond_to?).with(:fork).and_return(false)
    end

    after do
      QueryNoForkSpecRecord.remove_connection
      FileUtils.rm_rf(dir)
    end

    it "answers in this process and says the query ran without a time limit" do
      text = described_class.call(sql: "SELECT n FROM nums ORDER BY n").content.first[:text]

      expect(text).to include("| 3 |")
      expect(text).to include("without a time limit")
    end
  end

  describe "names Redaction's secret words cover" do
    it "redacts a result column named by one" do
      text = described_class.call(sql: "SELECT 1 AS passwd, 2 AS salt, 3 AS credentials, 4 AS pepper, 5 AS n").content.first[:text]
      expect(text.scan("[FILTERED]").size).to eq(4)
      expect(text).to include("| 5")
    end

    it "refuses a statement naming a real column one covers" do
      conn = ActiveRecord::Base.connection
      conn.create_table(:rac_signing_keys, force: true) { |t| t.string :salt }
      response = described_class.call(sql: "SELECT upper(salt) AS s FROM rac_signing_keys")
      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to include("`salt`")
    ensure
      conn.drop_table(:rac_signing_keys, if_exists: true)
    end

    it "reads the schema once for the whole call" do
      allow(described_class).to receive(:cached_context).and_return({})
      allow(ActiveRecord::Base.connection).to receive(:tables).and_call_original
      RailsAiContext::RunCache.around { described_class.call(sql: "SELECT 1 AS n") }
      expect(ActiveRecord::Base.connection).to have_received(:tables).once
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

    it "refuses a statement naming an allowed column declared with encrypts, under any alias" do
      allow(described_class).to receive(:cached_context).and_return(models: { "Thing" => { encrypts: %w[secret] } })
      [ "SELECT 7 AS secret", "SELECT secret AS s FROM (SELECT 7 AS secret) t" ].each do |sql|
        response = described_class.call(sql: sql)
        text = response.content.first[:text]
        expect(response.error?).to be(true), sql
        expect(text).to include("sensitive column `secret`", "config.query_allowed_columns does not release it")
        expect(text).not_to include("| 7", "add \"secret\"")
      end
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
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only) { |_conn, text, _timeout|
        sent = text
        ActiveRecord::Result.new(%w[n], [ [ 1 ] ])
      }
      described_class.call(sql: sql)
      sent
    end

    it "sends the database the text without its comments, the limit on a line of its own" do
      expect(sent_to_the_database("SELECT 7 AS n /* a */ -- why")).to eq("SELECT 7 AS n\nLIMIT 101")
    end

    it "reads a hash comment on a MySQL connection and nowhere else" do
      sql = "SELECT 7 AS n # why"

      expect(sent_to_the_database(sql)).to eq("SELECT 7 AS n # why\nLIMIT 101")

      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("Trilogy")
      sent = nil
      allow(RailsAiContext::DatabaseFamily::MysqlRuntime).to receive(:read_only) { |_conn, text, _timeout|
        sent = text
        ActiveRecord::Result.new(%w[n], [ [ 7 ] ])
      }
      described_class.call(sql: sql)
      expect(sent).to eq("SELECT 7 AS n\nLIMIT 101")
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

    it "still answers a query whose limit is an expression" do
      expect(rows("SELECT * FROM #{three} LIMIT 1+1", limit: 5)).to eq(2)
    end


    # Whatever the text says, the answer never carries more rows than asked for.
    it "drops rows the database returned past the limit" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_return(ActiveRecord::Result.new(%w[n], [ [ 1 ], [ 2 ], [ 3 ] ]))

      expect(rows("SELECT n FROM t", limit: 2)).to eq(2)
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

    # EXPLAIN ANALYZE runs the plan, so it must get the read-only transaction and the timeout.
    it "runs EXPLAIN through the family's guarded read" do
      expect(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).once.and_call_original
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
    before do
      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("Trilogy")
    end

    it "runs regular queries through the MySQL family" do
      expect(RailsAiContext::DatabaseFamily::MysqlRuntime).to receive(:read_only).and_return(ActiveRecord::Result.new(%w[x], [ [ 1 ] ]))

      expect(described_class.call(sql: "SELECT 1 AS x").content.first[:text]).to include("1")
    end

    it "issues EXPLAIN FORMAT=TRADITIONAL (not the bare EXPLAIN MySQL 8.3+/9.x would render as TREE)" do
      allow(RailsAiContext::DatabaseFamily::MysqlRuntime).to receive(:mariadb?).and_return(false)
      explain_result = ActiveRecord::Result.new(
        %w[id select_type table type possible_keys key key_len ref rows filtered Extra],
        [ [ 1, "SIMPLE", "products", "ALL", nil, nil, nil, nil, 5, 100.0, "" ] ]
      )
      expect(RailsAiContext::DatabaseFamily::MysqlRuntime).to receive(:read_only)
        .with(anything, a_string_matching(/\AEXPLAIN FORMAT=TRADITIONAL SELECT/), anything)
        .and_return(explain_result)

      text = described_class.call(sql: "SELECT * FROM products WHERE sku = 'x'", explain: true).content.first[:text]
      expect(text).to include("EXPLAIN Analysis")
      expect(text).to include("full table scan")
    end
  end

  describe "PostGIS adapter dispatch" do
    let(:runtime) { RailsAiContext::DatabaseFamily::PostgresqlRuntime }

    before do
      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("PostGIS")
      allow(runtime).to receive(:read_only).and_return(ActiveRecord::Result.new(%w[x], [ [ "[]" ] ]))
    end

    it "runs regular queries through the PostgreSQL family" do
      expect(described_class.call(sql: "SELECT 1 AS x").content.first[:text]).to include("[]")
      expect(runtime).to have_received(:read_only).with(anything, a_string_matching(/\ASELECT 1 AS x/), anything)
    end

    it "asks PostgreSQL for its JSON plan" do
      described_class.call(sql: "SELECT 1 AS x", explain: true)

      expect(runtime).to have_received(:read_only).with(anything, a_string_matching(/\AEXPLAIN \(FORMAT JSON, ANALYZE\) SELECT/), anything)
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
      expect(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_return(fake_result)

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
      expect(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_return(fake_result)

      result = described_class.call(sql: "SELECT id, cache_key FROM users")
      text = result.content.first[:text]
      expect(text).to include("[FILTERED]")
      expect(text).not_to include("sekret")
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


  describe "silent-truncation note" do
    def answer(sql, **opts)
      described_class.call(sql: sql, **opts).content.first[:text]
    end

    before do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
        .and_return(ActiveRecord::Result.new(%w[n], (1..150).map { |i| [ i ] }))
    end

    it "says rows were held back in the table format" do
      text = answer("SELECT n FROM big", limit: 100)
      expect(text).to include("100 rows shown; the query returned more")
      expect(text).to include("pass limit: up to 1000")
    end

    it "says so in the CSV format, after a blank line outside the block" do
      text = answer("SELECT n FROM big", limit: 100, format: "csv")
      expect(text).to match(/\n\n100 rows shown; the query returned more/)
    end

    it "names the hard cap when the cap is 1000" do
      # The text fetches one row past the cap; 1001 back means the cap cut it.
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
        .and_return(ActiveRecord::Result.new(%w[n], (1..1001).map { |i| [ i ] }))
      expect(answer("SELECT n FROM big", limit: 5000)).to include("the 1000-row hard cap")
    end

    it "does not add the note when the result is under the limit" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
        .and_return(ActiveRecord::Result.new(%w[n], [ [ 1 ], [ 2 ] ]))
      expect(answer("SELECT n FROM big", limit: 100)).not_to include("rows shown; the query returned")
    end

    # R5: `SELECT DISTINCT city ...` with limit 7 returned all 7 cities plus a
    # note that rows were held back. Exactly the cap is everything; only a row
    # past it means the cap cut the answer.
    it "does not add the note when exactly the cap came back" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
        .and_return(ActiveRecord::Result.new(%w[n], (1..7).map { |i| [ i ] }))
      text = answer("SELECT DISTINCT n FROM big", limit: 7)
      expect(text).to include("7 rows returned")
      expect(text).not_to include("rows shown; the query returned")
    end

    it "adds the note and drops the extra row when one past the cap came back" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
        .and_return(ActiveRecord::Result.new(%w[n], (1..8).map { |i| [ i ] }))
      text = answer("SELECT n FROM big", limit: 7)
      expect(text).to include("7 rows returned")
      expect(text).to include("7 rows shown; the query returned more")
    end
  end

  describe "result redaction by provenance" do
    it "redacts a result column whose source is a secret column, whatever its name" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_return(ActiveRecord::Result.new(%w[a b c], [ [ 1, "secret-value", 3 ] ]))
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:column_sources).and_return([ [ 0, "id", "users" ], [ 1, "password_digest", "users" ] ])

      text = described_class.call(sql: "SELECT a, b, c FROM t").content.first[:text]
      expect(text).to include("[FILTERED]")
      expect(text).not_to include("secret-value")
    end

    # A source whose column name could not be read: filtered when its relation
    # holds a secret column, returned otherwise.
    it "filters a column of a secret-holding relation whose column names could not be read" do
      conn = ActiveRecord::Base.connection
      conn.create_table(:rac_vaults, force: true) { |t| t.string :api_token }
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
        .and_return(ActiveRecord::Result.new(%w[a b c], [ [ "vault-value", "plain-value", "other-value" ] ]))
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:column_sources)
        .and_return([ [ 0, nil, "rac_vaults" ], [ 1, nil, "tags" ], [ 2, "title", "posts" ] ])

      text = described_class.call(sql: "SELECT a, b, c FROM t").content.first[:text]
      expect(text).not_to include("vault-value")
      expect(text).to include("plain-value").and include("other-value")
    ensure
      conn.drop_table(:rac_vaults, if_exists: true)
    end
  end


  describe "cell formatting" do
    def answer(rows, **opts)
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_return(ActiveRecord::Result.new(%w[a b], rows))
      described_class.call(sql: "SELECT a, b FROM t", **opts).content.first[:text]
    end

    it "writes a CSV cell as the value: NULL empty, binary [BLOB], nothing cut or escaped, RFC 4180 quoting" do
      long = "z" * 150
      text = answer([ [ nil, "\x00\x01".b ], [ long, "a|b" ], [ "x, y", 'say "hi"' ] ], format: "csv")
      expect(text).to eq("a,b\n,[BLOB]\n#{long},a|b\n\"x, y\",\"say \"\"hi\"\"\"")
    end

    it "writes a table cell's line break as backslash-n and escapes a pipe in a value cut at 100 characters" do
      text = answer([ [ "line1\nline2", ("a" * 50) + "|" + ("b" * 60) ] ])
      expect(text).to include("line1\\nline2")
      expect(text).to include(("a" * 50) + "\\|" + ("b" * 49) + "...")
    end
  end

  # R7: in the default format a SHOW CREATE definition was one table cell, cut
  # at 100 characters with its lines folded into `\n`, and nothing said that
  # format: "csv" had all of it.
  describe "SHOW CREATE definition rendering" do
    let!(:original_cap) { RailsAiContext.configuration.max_tool_response_chars }
    after { RailsAiContext.configuration.max_tool_response_chars = original_cap }

    let(:ddl) do
      "CREATE TABLE `posts` (\n" \
        "  `id` bigint(20) NOT NULL AUTO_INCREMENT,\n" \
        "  `title` varchar(255) NOT NULL,\n" \
        "  `body` text DEFAULT NULL,\n" \
        "  PRIMARY KEY (`id`)\n" \
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
    end

    def answer(sql, rows:, columns: [ "Table", "Create Table" ], **opts)
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_return(ActiveRecord::Result.new(columns, rows))
      described_class.call(sql: sql, **opts).content.first[:text]
    end

    it "shows the whole definition, its line breaks kept, in a fenced code block" do
      text = answer("SHOW CREATE TABLE posts", rows: [ [ "posts", ddl ] ])
      expect(ddl.length).to be > 100
      expect(text).to include("Table: posts")
      expect(text).to include("```sql\n#{ddl}\n```")
      expect(text).not_to include("...")
      expect(text).not_to include("\\n")
    end

    it "lists a view's other columns after its definition" do
      text = answer("SHOW CREATE VIEW totals",
        columns: [ "View", "Create View", "character_set_client", "collation_connection" ],
        rows: [ [ "totals", "CREATE VIEW `totals` AS select 1 AS `n`", "utf8mb4", "utf8mb4_general_ci" ] ])
      expect(text).to include("View: totals")
      expect(text).to include("```sql\nCREATE VIEW `totals` AS select 1 AS `n`\n```")
      expect(text).to include("character_set_client: utf8mb4\ncollation_connection: utf8mb4_general_ci")
    end

    it "fences the definition past its longest backtick run" do
      # The identifier a` is written `a```, a run of three backticks.
      tricky = "CREATE TABLE `a``` (`id` int)"
      text = answer("SHOW CREATE TABLE x", rows: [ [ "a`", tricky ] ])
      expect(text).to include("````sql\n#{tricky}\n````")
    end

    it "still redacts a credential inside the definition" do
      secret = "p#{'w' * 14}"
      linked = "CREATE TABLE `l` (`id` int) COMMENT='mysql://svc_user:#{secret}@db.internal:3306/app'"
      text = answer("SHOW CREATE TABLE l", rows: [ [ "l", linked ] ])
      expect(text).to include("```sql\n")
      expect(text).to include("mysql://#{RailsAiContext::Redaction::FILTERED}@db.internal:3306/app")
      expect(text).not_to include(secret)
    end

    it "leaves the CSV format a plain comma block" do
      text = answer("SHOW CREATE TABLE posts", rows: [ [ "posts", ddl ] ], format: "csv")
      expect(text).to start_with("Table,Create Table\nposts,\"CREATE TABLE")
      expect(text).not_to include("```")
    end

    it "is still bounded by the response size cap" do
      RailsAiContext.configuration.max_tool_response_chars = 200
      wide = "CREATE TABLE `t` (\n#{(1..60).map { |i| "  `c#{i}` int DEFAULT NULL" }.join(",\n")}\n)"
      text = answer("SHOW CREATE TABLE t", rows: [ [ "t", wide ] ])
      expect(text).to include("Response truncated")
      expect(text.length).to be < wide.length
    end
  end

  # The only statements refused before the SQL gate that it runs: two string
  # literals. Every other refusal stands (sql_gate_spec).
  describe "statements refused before that now run" do
    it "runs a literal holding OR 1=1" do
      response = described_class.call(sql: "SELECT 'a' AS v WHERE 'x' LIKE '%OR 1=1%' OR 1 = 1")
      expect(response.error?).to be(false)
      expect(response.content.first[:text]).to include("1 row returned")
    end

    it "runs a literal holding a locking phrase on PostgreSQL" do
      allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("PostgreSQL")
      allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:plan).and_return("Node Type" => "Result")
      allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:column_sources).and_return([])
      allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:read_only).and_return(ActiveRecord::Result.new(%w[id], [ [ 4 ] ]))

      response = described_class.call(sql: "SELECT id FROM orders WHERE notes LIKE '%ready for update%'")
      expect(response.error?).to be(false)
      expect(response.content.first[:text]).to include("| 4")
    end
  end

  describe "a query with no limit of its own" do
    it "fetches one row past the cap for a negative SQLite limit, and says rows were held back" do
      sent = nil
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_wrap_original { |m, c, sql, t| sent = sql; m.call(c, sql, t) }
      text = described_class.call(sql: "SELECT * FROM (VALUES (1),(2),(3)) v LIMIT -1", limit: 2).content.first[:text]
      expect(sent).to end_with("LIMIT 3")
      expect(text).to include("2 rows returned")
      expect(text).to include("2 rows shown; the query returned more")
    end
  end

  describe "an EXPLAIN that fails" do
    it "is an error result" do
      response = described_class.call(sql: "SELECT nope FROM no_such_table", explain: true)
      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to start_with("EXPLAIN failed:")
    end

    it "is an error result when asked of a statement it cannot explain" do
      expect(described_class.call(sql: "SHOW tables", explain: true).error?).to be(true)
    end
  end
end
