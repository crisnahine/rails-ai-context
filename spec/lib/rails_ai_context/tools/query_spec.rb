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

  # A timeout one example shortens is not the next spec file's.
  after { RailsAiContext.configuration.query_timeout = 5 }

  # A faked adapter name would send the family's catalogue reads to this SQLite database.
  def fake_family(adapter_name)
    allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return(adapter_name)
    [ RailsAiContext::DatabaseFamily::MysqlRuntime, RailsAiContext::DatabaseFamily::PostgresqlRuntime ].each do |runtime|
      allow(runtime).to receive_messages(view_definitions: {}, generated_columns: {}, traced_views: [], schemas_named: [])
      allow(runtime).to receive(:bounded) { |_connection, _timeout, &reads| reads.call }
      allow(runtime).to receive(:relation_columns) { |connection| RailsAiContext::DatabaseFamily::SqliteRuntime.relation_columns(connection) }
    end
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

    # A second LIMIT would be a syntax error.
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
        expect(result.content.first[:text]).not_to include("cannot be reached")
      end

      it "answers the family's timeout as an error" do
        allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_raise(RailsAiContext::DatabaseFamily::TimedOut, "stopped")

        result = described_class.call(sql: "SELECT SLEEP(60) FROM tags")

        expect(result.content.first[:text]).to start_with("Query exceeded 5 second timeout")
        expect(result.error?).to be true
      end

      it "answers a timed out EXPLAIN as the same error" do
        allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_raise(RailsAiContext::DatabaseFamily::TimedOut, "stopped")

        result = described_class.call(sql: "SELECT id FROM tags", explain: true)

        expect(result.content.first[:text]).to start_with("Query exceeded 5 second timeout")
        expect(result.error?).to be true
      end

      it "flags an SQL error that mentions a timeout as an SQL error" do
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

      it "refuses an adapter with no family from the configuration, before the connection is verified or sent anything" do
        config = ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, "primary", adapter: "sqlserver", database: "app")
        allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(config)
        conn = ActiveRecord::Base.connection
        %i[verify! active? execute select_all select_value select_rows exec_query columns tables transaction].each do |sent|
          allow(conn).to receive(sent).and_raise("#{sent} reached the database")
        end

        result = described_class.call(sql: "SELECT 1 AS x")

        expect(result.error?).to be true
        expect(result.content.first[:text]).to start_with("rails_query refuses the sqlserver adapter").and end_with("No statement was sent.")
      end

      if defined?(ActiveRecord::ConnectionFailed)
        it "answers a connection the server dropped as the database that stopped answering, from the statement and from a read beside it" do
          dropped = ActiveRecord::ConnectionFailed.new("server has gone away")
          stopped = "The primary database stopped answering during the query: server has gone away"
          runtime = RailsAiContext::DatabaseFamily::SqliteRuntime

          allow(runtime).to receive(:read_only).and_raise(dropped)
          [ {}, { explain: true } ].each do |options|
            result = described_class.call(sql: "SELECT 1", **options)
            expect([ result.content.first[:text], result.error? ]).to eq([ stopped, true ]), options.to_s
          end

          allow(runtime).to receive(:relation_columns).and_raise(dropped)
          result = RailsAiContext::RunCache.around { described_class.call(sql: "SELECT 1") }
          expect([ result.content.first[:text], result.error? ]).to eq([ stopped, true ])
        end
      end

      it "refuses every statement when the database's columns cannot be read, and sends none" do
        runtime = RailsAiContext::DatabaseFamily::SqliteRuntime
        allow(described_class).to receive(:cached_context).and_return({})
        allow(runtime).to receive(:relation_columns).and_raise(ActiveRecord::StatementInvalid, "catalogue unreadable")
        allow(runtime).to receive(:read_only).and_call_original

        result = RailsAiContext::RunCache.around { described_class.call(sql: "SELECT 1 AS x") }

        expect(result.error?).to be true
        expect(result.content.first[:text])
          .to eq("The columns of the primary database could not be read, so its secret columns cannot be told and no query runs on it.")
        expect(runtime).not_to have_received(:read_only)
      end

      it "answers a primary no connection reaches as an error that names it" do
        allow(ActiveRecord::Base.connection).to receive(:verify!)
          .and_raise(ActiveRecord::ConnectionNotEstablished, "connection to server at 127.0.0.1, port 5432 failed")
        result = described_class.call(sql: "SELECT 1")

        expect(result.error?).to be true
        expect(result.content.first[:text]).to eq("The primary database cannot be reached: connection to server at 127.0.0.1, " \
          "port 5432 failed. Check the file its config/database.yml entry names.")
      end

      it "answers a connection lost during the statement as an error that names the database" do
        allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
          .and_raise(ActiveRecord::ConnectionNotEstablished, "server closed the connection unexpectedly")

        result = described_class.call(sql: "SELECT 1")

        expect(result.error?).to be true
        expect(result.content.first[:text]).to eq("The primary database stopped answering during the query: server closed the connection unexpectedly")
      end

      it "reads a missing database named in an SQL error as the SQL error" do
        allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
          .and_raise(ActiveRecord::StatementInvalid, "Unknown database 'reports' in a cross-database read")

        expect(described_class.call(sql: "SELECT 1").content.first[:text]).to start_with("SQL error: Unknown database 'reports'")
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
      it "blocks in production by default, as an error" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        result = described_class.call(sql: "SELECT 1")
        expect([ result.error?, result.content.first[:text] ]).to match([ true, a_string_including("disabled in production") ])
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
    # Eight billion rows to count: it runs for hours, so nothing but the deadline's kill ends it.
    # These examples read how the child ended and time nothing, since a busy machine wakes the parent late.
    let(:slow_sql) { "SELECT count(*) AS n FROM big a, big b, big c" }
    let(:reaped) { [] }
    let(:killed) { Signal.list.fetch("KILL") }

    before do
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
      allow(Process).to receive(:wait).and_wrap_original { |original, pid| original.call(pid).tap { reaped << $? } }
    end

    after do
      QueryTimeoutSpecRecord.remove_connection
      FileUtils.rm_rf(dir)
    end

    it "ends a query that would run for hours at query_timeout, by killing its process, and answers the timeout" do
      RailsAiContext.configuration.query_timeout = 1
      response = described_class.call(sql: slow_sql)

      expect(response.content.first[:text]).to start_with("Query exceeded 1 second timeout")
      expect(response.error?).to be(true)
      expect(reaped.map(&:termsig)).to eq([ killed ])
    end

    it "decides the deadline once, before the child starts, and waits no longer than what is left of it" do
      waits = []
      allow(IO).to receive(:select).and_wrap_original { |original, *args| waits << args.last; original.call(*args) }

      expect { RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, slow_sql, timeout: 1) }
        .to raise_error(RailsAiContext::DatabaseFamily::TimedOut)
      expect(waits).to all(be_between(0, 1))
      expect(waits).to eq(waits.sort.reverse)
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

      expect { RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, slow_sql, timeout: 5) }.to raise_error(IOError)

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

    it "answers a database another process keeps locked as locked, from the reads before the statement and from the child" do
      conn.execute("PRAGMA journal_mode = DELETE")
      writer = IO.popen([ RbConfig.ruby, "-rbundler/setup", "-rsqlite3", "-e", <<~RUBY, File.join(dir, "t.sqlite3") ])
        db = SQLite3::Database.new(ARGV[0])
        db.execute("BEGIN EXCLUSIVE")
        $stdout.puts "locked"
        $stdout.flush
        sleep 30
      RUBY
      expect(writer.gets).to eq("locked\n")

      response = described_class.call(sql: "SELECT count(*) AS n FROM nums")
      expect([ response.error?, response.content.first[:text] ]).to eq(
        [ true, "The database is locked by another connection, so the query did not run. Run it again when the other connection has finished." ]
      )
      expect { RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT count(*) AS n FROM nums", timeout: 1) }
        .to raise_error(RailsAiContext::DatabaseFamily::Busy)
    ensure
      Process.kill(:KILL, writer.pid) if writer
      writer&.close
    end

    it "answers as locked a database another process locked before the connection opened" do
      conn.execute("PRAGMA journal_mode = DELETE")
      QueryTimeoutSpecRecord.connection_pool.disconnect!
      writer = IO.popen([ RbConfig.ruby, "-rbundler/setup", "-rsqlite3", "-e", <<~RUBY, File.join(dir, "t.sqlite3") ])
        db = SQLite3::Database.new(ARGV[0])
        db.execute("BEGIN EXCLUSIVE")
        $stdout.puts "locked"
        $stdout.flush
        sleep 30
      RUBY
      expect(writer.gets).to eq("locked\n")

      response = described_class.call(sql: "SELECT count(*) AS n FROM nums")
      expect([ response.error?, response.content.first[:text] ]).to eq(
        [ true, "The database is locked by another connection, so the query did not run. Run it again when the other connection has finished." ]
      )
    ensure
      Process.kill(:KILL, writer.pid) if writer
      writer&.close
    end

    it "answers locked when the deadline passes while a slow child still waits on the lock, and the timeout when no lock is met" do
      conn.execute("PRAGMA journal_mode = DELETE")
      slow = 0.4
      allow(SQLite3::Database).to receive(:new).and_wrap_original do |original, *args, **options|
        sleep slow
        original.call(*args, **options)
      end
      expect { RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT count(*) AS n FROM nums", timeout: 0.2) }
        .to raise_error(RailsAiContext::DatabaseFamily::TimedOut)

      writer = IO.popen([ RbConfig.ruby, "-rbundler/setup", "-rsqlite3", "-e", <<~RUBY, File.join(dir, "t.sqlite3") ])
        db = SQLite3::Database.new(ARGV[0])
        db.execute("BEGIN EXCLUSIVE")
        $stdout.puts "locked"
        $stdout.flush
        sleep 30
      RUBY
      expect(writer.gets).to eq("locked\n")
      # The child opens at 0.4 s and would wait on the lock until 1.2 s, past the deadline at 1 s.
      expect { RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT count(*) AS n FROM nums", timeout: 1) }
        .to raise_error(RailsAiContext::DatabaseFamily::Busy)
    ensure
      Process.kill(:KILL, writer.pid) if writer
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
            sleep 600
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

      def still_running?(pid)
        Process.waitpid(pid, Process::WNOHANG).nil?
      end

      it "returns a fast result while that process still holds the pipe" do
        result = RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT n FROM nums ORDER BY n", timeout: 5)

        expect(result.rows).to eq([ [ 1 ], [ 2 ], [ 3 ] ])
        expect(still_running?(sleepers.last)).to be(true)
      end

      it "still ends a slow query at the deadline, while that process still holds the pipe" do
        expect { RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, slow_sql, timeout: 1) }
          .to raise_error(RailsAiContext::DatabaseFamily::TimedOut)
        expect(reaped.map(&:termsig)).to eq([ killed ])
        expect(still_running?(sleepers.last)).to be(true)
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

      fast = Thread.new { RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, "SELECT n FROM nums", timeout: 600) }
      sleep 0.1
      slow = Thread.new { RailsAiContext::DatabaseFamily::SQLITE.read_only(conn, slow_sql, timeout: 600) }

      expect(fast.value.rows).to eq([ [ 1 ], [ 2 ], [ 3 ] ])
      expect(slow).to be_alive
    ensure
      slow&.kill
      slow&.join
    end
  end

  # Where there is no fork (Windows), a file-backed database gets no
  # timeout: the query runs in this process, and the answer says so.
  describe "SQLite tables that hold another table's rows or words, on a file-backed database" do
    let(:dir) { Dir.mktmpdir }
    let(:marker) { "MARKER7f3a" }
    let(:conn) do
      stub_const("QueryIndexTablesSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      QueryIndexTablesSpecRecord.establish_connection(adapter: "sqlite3", database: File.join(dir, "t.sqlite3"))
      QueryIndexTablesSpecRecord.connection.tap do |c|
        [ "CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT, api_token TEXT)",
          "INSERT INTO accounts VALUES (1, 'a@example.com', '#{marker}')",
          "CREATE VIRTUAL TABLE docs USING fts5(title, api_token)",
          "INSERT INTO docs VALUES ('hello', '#{marker}')",
          "CREATE VIRTUAL TABLE docs_words USING fts5vocab(docs, row)",
          "CREATE VIRTUAL TABLE notes USING fts5(title, body)",
          "INSERT INTO notes VALUES ('plain', 'ordinary words')",
          "CREATE VIRTUAL TABLE notes_words USING fts5vocab('notes', 'row')",
          "CREATE TABLE notes_archive (id INTEGER, title TEXT)",
          "INSERT INTO notes_archive VALUES (7, 'kept')",
          "CREATE VIEW note_rows AS SELECT c1 AS body FROM notes_content",
          "CREATE VIEW pages AS SELECT data FROM sqlite_dbpage" ].each { |sql| c.execute(sql) }
      end
    end

    before do
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
      allow(described_class).to receive(:cached_context).and_return({})
    end

    after do
      QueryIndexTablesSpecRecord.remove_connection
      FileUtils.rm_rf(dir)
    end

    def answer(sql)
      response = RailsAiContext::RunCache.around { described_class.call(sql: sql) }
      [ response.error?, response.content.first[:text] ]
    end

    def refused(sql, text)
      expect(answer(sql)).to eq([ true, text ]), sql
    end

    it "never reads the database file's raw pages" do
      [ "SELECT CAST(substr(data, instr(data, 'MARKER'), 20) AS TEXT) AS v FROM sqlite_dbpage WHERE instr(data, 'MARKER') > 0",
        "SELECT pgno FROM SQLITE_DBPAGE('main')", "SELECT 'sqlite_dbpage' AS v" ].each do |sql|
        refused(sql, "Blocked: `sqlite_dbpage` is not read: it returns the database file's raw pages, and every stored value is in them.")
      end
    end

    it "never reads a shadow table, and names the virtual table to query" do
      [ "SELECT * FROM notes_content", "SELECT c1 AS v FROM NOTES_CONTENT", "SELECT block FROM \"notes_data\"", "SELECT term FROM notes_idx" ].each do |sql|
        table = sql[/notes_\w+/i].downcase
        refused(sql, "Blocked: `#{table}` is not read: it is a shadow table, where SQLite keeps what the virtual table `notes` " \
                     "stores under other column names. Query `notes`.")
      end
      refused("SELECT * FROM docs_content",
              "Blocked: `docs_content` is not read: it is a shadow table, where SQLite keeps what the virtual table `docs` stores under other column names.")
    end

    it "refuses a view over a shadow table and over the raw pages" do
      refused("SELECT body FROM note_rows", "Blocked: the view `note_rows` is not queried: its definition reads `notes_content`, which is not read. " \
                                            "A view can rename a column past the redaction on SQLite, so query the tables it reads.")
      expect(answer("SELECT * FROM pages").last).to start_with("Blocked: the view `pages` is not queried: its definition reads `sqlite_dbpage`")
    end

    it "refuses the vocabulary of a virtual table that holds a secret column, and the virtual table whole" do
      refused("SELECT term FROM docs_words",
              "Blocked: `docs_words` is not read: it lists the words of the full-text table `docs`, which holds the secret column `api_token`.")
      [ "SELECT highlight(docs, 1, '', '') AS h FROM docs", "SELECT snippet(docs, 1, '', '', '', 8) AS s FROM docs",
        "SELECT count(*) AS n FROM docs WHERE docs MATCH 'marker*'", "SELECT title FROM docs" ].each do |sql|
        refused(sql, "Blocked: `docs` is not read: it is a virtual table that holds the secret column `api_token`, and a search or a " \
                     "function over a virtual table reads a column by its position, with no name written.")
      end
    end

    it "runs dbstat, a full-text table with no secret column, its vocabulary, and a table that only shares its prefix" do
      # A SQLite built without dbstat has no such table to run.
      sizes = conn.select_values("SELECT name FROM pragma_module_list").include?("dbstat") ? { "SELECT name, sum(pgsize) AS bytes FROM dbstat GROUP BY name" => "accounts" } : {}
      { **sizes,
        "SELECT title, body FROM notes WHERE notes MATCH 'ordinary'" => "ordinary words",
        "SELECT highlight(notes, 1, '<', '>') AS h FROM notes WHERE notes MATCH 'words'" => "ordinary <words>",
        "SELECT snippet(notes, 1, '<', '>', '', 8) AS s FROM notes WHERE notes MATCH 'words'" => "ordinary <words>",
        "SELECT title FROM notes" => "plain",
        "SELECT term FROM notes_words ORDER BY term" => "ordinary",
        "SELECT id, title FROM notes_archive" => "kept" }.each do |sql, value|
        failed, text = answer(sql)
        expect([ failed, text.include?(value) ]).to eq([ false, true ]), "#{sql}: #{text}"
      end
    end

    it "runs a full-text table whose own name reads like a secret column's, since only the columns it declares decide" do
      conn.execute("CREATE VIRTUAL TABLE token_search USING fts5(title, body)")
      conn.execute("INSERT INTO token_search VALUES ('hello', 'world of words')")
      conn.execute("CREATE VIRTUAL TABLE token_search_vocab USING fts5vocab(token_search, row)")

      { "SELECT * FROM token_search" => "world of words",
        "SELECT title FROM token_search WHERE token_search MATCH 'hello'" => "hello",
        "SELECT highlight(token_search, 1, '<', '>') AS h FROM token_search WHERE token_search MATCH 'words'" => "world of <words>",
        "SELECT snippet(token_search, 1, '<', '>', '', 8) AS s FROM token_search WHERE token_search MATCH 'words'" => "world of <words>",
        "SELECT term FROM token_search_vocab ORDER BY term" => "words" }.each do |sql, value|
        failed, text = answer(sql)
        expect([ failed, text.include?(value) ]).to eq([ false, true ]), "#{sql}: #{text}"
      end
      expect(answer("SELECT title FROM docs").last).to start_with("Blocked: `docs` is not read: it is a virtual table that holds the secret column `api_token`")
    end

    it "refuses a virtual table whose definition names a refused view, with its vocabulary and a view over it" do
      [ "CREATE VIEW ren AS SELECT id, api_token AS word FROM accounts",
        "CREATE VIRTUAL TABLE ren_fts USING fts5(word, content='ren', content_rowid='id')",
        "CREATE VIRTUAL TABLE ren_terms USING fts5vocab(ren_fts, row)",
        "CREATE VIEW ren_over AS SELECT word AS w FROM ren_fts",
        "CREATE VIRTUAL TABLE mail_fts USING fts5(email, content='accounts', content_rowid='id')" ].each { |sql| conn.execute(sql) }

      [ "SELECT word FROM ren_fts", "SELECT * FROM ren_fts", "SELECT highlight(ren_fts, 0, '', '') AS h FROM ren_fts" ].each do |sql|
        refused(sql, "Blocked: `ren_fts` is not read: its definition names the view `ren`, which is not queried: its definition names the secret column `api_token`.")
      end
      refused("SELECT term FROM ren_terms", "Blocked: `ren_terms` is not read: its definition names `ren_fts`, which is not read.")
      expect(answer("SELECT w FROM ren_over")).to match([ true, a_string_starting_with("Blocked: the view `ren_over` is not queried: its definition reads `ren_fts`, which is not read.") ])
      expect(answer("SELECT email FROM mail_fts")).to match([ false, a_string_including("a@example.com") ])
    end

    it "reads a shadow table by its name where SQLite does not type one, so a table that shares a virtual table's prefix is not read" do
      allow(conn).to receive(:database_version).and_return(ActiveRecord::ConnectionAdapters::AbstractAdapter::Version.new("3.36.0"))
      expect(answer("SELECT c1 FROM docs_content").last).to start_with("Blocked: `docs_content` is not read: it is a shadow table")
      expect(answer("SELECT id FROM notes_archive").last).to start_with("Blocked: `notes_archive` is not read: it is a shadow table")
      expect(answer("SELECT id, email FROM accounts").first).to be(false)
    end
  end

  describe "a wildcard inside a subquery on a file-backed SQLite database" do
    let(:dir) { Dir.mktmpdir }
    let(:conn) do
      stub_const("QueryWildcardSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      QueryWildcardSpecRecord.establish_connection(adapter: "sqlite3", database: File.join(dir, "t.sqlite3"))
      QueryWildcardSpecRecord.connection.tap do |c|
        [ "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, password_digest TEXT)",
          "INSERT INTO users VALUES (1, 'a@example.test', 'MARKER-DIGEST-1')",
          "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT)", "INSERT INTO posts VALUES (1, 'the users table'), (2, 'users')",
          "CREATE TABLE ids (id INTEGER PRIMARY KEY)", "INSERT INTO ids VALUES (1)" ].each { |sql| c.execute(sql) }
      end
    end

    before do
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
      allow(described_class).to receive(:cached_context).and_return({})
    end

    after do
      QueryWildcardSpecRecord.remove_connection
      FileUtils.rm_rf(dir)
    end

    def answer(sql)
      response = RailsAiContext::RunCache.around { described_class.call(sql: sql) }
      [ response.error?, response.content.first[:text] ]
    end

    it "refuses it when a string of the statement equals the name of a table that holds a secret column" do
      [ "('users')", "(('users'))", "('users') AS u", "('users' u)", "('users' NOT INDEXED)", "ids CROSS JOIN ('users')",
        "ids LEFT JOIN ('users') ON 1", "(ids), ('users')", "'users'", "main.'users'", "('USERS')" ].each do |from|
        sql = "SELECT (1, 'a@example.test', 'M') < (SELECT * FROM #{from}) AS o"
        name = from[/'(\w+)'/, 1]
        expect(answer(sql)).to eq([ true,
          "Blocked: a `*` inside a subquery is not run in a statement that holds the string '#{name}'. SQLite reads a string as a table's " \
          "name where a name can stand, and the table `#{name}` holds the secret column `password_digest`. A value read through such a " \
          "wildcard can be compared or renamed past the redaction, so name the columns in the subquery." ]), sql
      end
      expect(answer("SELECT * FROM (SELECT * FROM posts) p WHERE title = 'users'").last).to start_with("Blocked: a `*` inside a subquery")
    end

    it "refuses IN before the name of a table that holds a secret column, and runs IN before a list or a subquery in parentheses" do
      row = "(1, 'a@example.test', 'MARKER-DIGEST-1')"
      [ "SELECT #{row} IN users AS o", "SELECT #{row} NOT IN users AS o", %(SELECT #{row} IN "users" AS o), "SELECT #{row} IN main.users AS o",
        "SELECT #{row} IN 'users' AS o" ].each do |sql|
        expect(answer(sql)).to match([ true, a_string_starting_with("Blocked: `IN` before a table's name is not run in a statement that ") ]), sql
      end
      { "SELECT id FROM users WHERE id IN (1, 2)" => "| 1  |", "SELECT title FROM posts WHERE id IN (SELECT id FROM users)" => "the users table",
        "SELECT 1 IN ids AS o" => "| 1 |" }.each do |sql, value|
        failed, text = answer(sql)
        expect([ failed, text.include?(value) ]).to eq([ false, true ]), "#{sql}: #{text}"
      end
    end

    it "answers SQLite's own error for TABLE, which SQLite has no statement for" do
      [ "SELECT 1 < (TABLE users)", "SELECT * FROM (TABLE users) t" ].each do |sql|
        expect(answer(sql)).to match([ true, a_string_starting_with("SQL error: SQLite3::SQLException: near \"TABLE\": syntax error") ]), sql
      end
    end

    it "runs it when the strings of the statement name no such table" do
      { "SELECT * FROM (SELECT * FROM posts) p WHERE title LIKE '%users%'" => "the users table",
        "SELECT * FROM (SELECT * FROM ('posts')) p WHERE id = 1" => "the users table",
        "SELECT title FROM posts WHERE title = 'users'" => "| users" }.each do |sql, value|
        failed, text = answer(sql)
        expect([ failed, text.include?(value) ]).to eq([ false, true ]), "#{sql}: #{text}"
      end
    end
  end

  describe "SQLite tables in the temp schema and in an attached database" do
    let(:dir) { Dir.mktmpdir }
    let(:conn) do
      stub_const("QuerySchemasSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      QuerySchemasSpecRecord.establish_connection(adapter: "sqlite3", database: File.join(dir, "t.sqlite3"))
      QuerySchemasSpecRecord.connection.tap do |c|
        [ "CREATE TABLE notes (id INTEGER, body TEXT)", "INSERT INTO notes VALUES (1, 'kept')",
          "ATTACH DATABASE '#{File.join(dir, "other.sqlite3")}' AS other",
          "CREATE TABLE other.vault (id INTEGER, email TEXT, door_token TEXT)", "INSERT INTO other.vault VALUES (1, 'v@example.com', 'door-value')",
          "CREATE TEMP TABLE scratch (id INTEGER, pin_token TEXT)", "INSERT INTO scratch VALUES (1, 'pin-value')",
          "CREATE TEMP VIEW peek AS SELECT door_token AS d FROM other.vault" ].each { |sql| c.execute(sql) }
      end
    end

    before do
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
      allow(described_class).to receive(:cached_context).and_return({})
    end

    after do
      QuerySchemasSpecRecord.remove_connection
      FileUtils.rm_rf(dir)
    end

    def answer(sql)
      response = RailsAiContext::RunCache.around { described_class.call(sql: sql) }
      [ response.error?, response.content.first[:text] ]
    end

    it "refuses a statement that names a secret column of either, as it does for a table of the main database" do
      { "SELECT door_token AS d FROM other.vault" => "door_token", "SELECT upper(door_token) AS d FROM vault" => "door_token",
        "SELECT pin_token AS p FROM scratch" => "pin_token", "SELECT id FROM temp.scratch WHERE pin_token LIKE 'pin%'" => "pin_token" }.each do |sql, column|
        expect(answer(sql)).to match([ true, a_string_starting_with("Blocked: query references secret column `#{column}`") ]), sql
      end
      expect(answer("SELECT * FROM peek")).to match([ true, a_string_starting_with("Blocked: the view `peek` is not queried: its definition names the secret column `door_token`") ])
    end

    it "holds a wildcard subquery and IN to the wildcard rule when a string or a name spells a table of either" do
      row = "(1, 'v@example.com', 'door-value')"
      [ "SELECT #{row} < (SELECT * FROM ('vault')) AS o", "SELECT #{row} < (SELECT * FROM other.'vault') AS o",
        "SELECT (1, 'pin-value') < (SELECT * FROM ('scratch')) AS o", "SELECT #{row} IN 'vault' AS o", "SELECT #{row} IN other.vault AS o",
        "SELECT (1, 'pin-value') IN temp.scratch AS o" ].each do |sql|
        expect(answer(sql)).to match([ true, a_string_starting_with("Blocked: ").and(including("is not run in a statement that")) ]), sql
      end
    end

    it "filters a secret column of either in place, and runs a statement that reads none" do
      expect(answer("SELECT * FROM other.vault")).to match([ false, a_string_including("v@example.com", "[FILTERED]") ])
      expect(answer("SELECT * FROM other.vault").last).not_to include("door-value")
      expect(answer("SELECT n.body, v.email FROM notes n JOIN other.vault v ON v.id = n.id")).to match([ false, a_string_including("kept", "v@example.com") ])
      expect(answer("SELECT id FROM scratch")).to match([ false, a_string_including("| 1") ])
    end
  end

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

  describe "a statement over the length the checks read" do
    it "is refused before anything reads it" do
      expect(RailsAiContext::SecretColumns).not_to receive(:for)
      expect(RailsAiContext::SqlGate).not_to receive(:comment_free)
      response = described_class.call(sql: "SELECT 1 AS v, #{"[" * 1_000_000}")
      expect(response.error?).to be(true)
      expect(response.content.first[:text])
        .to eq("Blocked: the statement is 1000015 bytes long, and rails_query checks a statement of 1000000 bytes at most.")
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
      runtime = RailsAiContext::DatabaseFamily::SqliteRuntime
      %i[relation_columns view_definitions generated_columns].each { |read| allow(runtime).to receive(read).and_call_original }
      RailsAiContext::RunCache.around { described_class.call(sql: "SELECT 1 AS n") }
      %i[relation_columns view_definitions generated_columns].each { |read| expect(runtime).to have_received(read).once }
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
        expect(text).to include("secret column `secret`", "config.query_allowed_columns does not release it")
        expect(text).not_to include("| 7", "add \"secret\"")
      end
    end
  end

  describe "the text that runs is the text that was validated" do
    def answer(sql, **opts)
      described_class.call(sql: sql, **opts).content.first[:text]
    end

    it "refuses a secret column that follows a comment marker in a string literal" do
      text = answer("SELECT '--' AS m, api_key AS x FROM (SELECT 'leak' AS api_key) t")

      expect(text).to include("secret column `api_key`")
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

      fake_family("Trilogy")
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

    it "says what explain takes for a statement that is no SELECT, and that an EXPLAIN is one already" do
      expect(described_class.call(sql: "SHOW tables", explain: true).content.first[:text])
        .to eq("`explain: true` takes a SELECT or WITH statement and explains it.")
      [ "EXPLAIN SELECT 1 AS test", "explain query plan SELECT 1 AS test" ].each do |sql|
        response = described_class.call(sql: sql, explain: true)
        expect([ response.error?, response.content.first[:text] ]).to eq(
          [ true, "The statement is already an EXPLAIN. `explain: true` takes a SELECT or WITH statement and explains it." ]
        ), sql
      end
    end

    it "ends an SQL error where the database's message ends, with no colon after it" do
      expect(described_class.call(sql: "SELECT id FROM no_such_table").content.first[:text]).to eq("SQL error: SQLite3::SQLException: no such table: no_such_table")
      expect(described_class.call(sql: "SELECT id FROM no_such_table", explain: true).content.first[:text])
        .to eq("EXPLAIN failed: SQLite3::SQLException: no such table: no_such_table")
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
      fake_family("Trilogy")
    end

    it "runs regular queries through the MySQL family" do
      expect(RailsAiContext::DatabaseFamily::MysqlRuntime).to receive(:read_only).and_return(ActiveRecord::Result.new(%w[x], [ [ 1 ] ]))

      expect(described_class.call(sql: "SELECT 1 AS x").content.first[:text]).to include("1")
    end

    it "issues EXPLAIN FORMAT=TRADITIONAL (not the bare EXPLAIN MySQL 8.3+/9.x would render as TREE)" do
      without_partial_double_verification { allow(ActiveRecord::Base.connection).to receive(:mariadb?).and_return(false) }
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
      fake_family("PostGIS")
      allow(runtime).to receive(:read_only).and_return(ActiveRecord::Result.new(%w[x], [ [ "[]" ] ]))
      allow(runtime).to receive(:plan).and_return("Node Type" => "Result")
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

    it "still redacts secret columns for plain SELECT queries" do
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
    it "answers the header row alone when the query returns no rows" do
      result = described_class.call(sql: "SELECT 1 AS a, 'x' AS \"b,c\" WHERE 1 = 0", format: "csv")
      expect(result.content.first[:text]).to eq(%(a,"b,c"))
      expect(described_class.call(sql: "SELECT 1 AS a WHERE 1 = 0").content.first[:text]).to start_with("_Query returned 0 rows._")
    end

    it "escapes newlines in cell values" do
      columns = %w[id note]
      rows = [ [ 1, "line1\nline2" ] ]
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only)
        .and_return(RailsAiContext::DatabaseFamily::Rows.new(columns, rows, false))

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

  describe "a result column SQLite renamed as a duplicate" do
    it "is filtered by the name before the :N suffix" do
      allow(described_class).to receive(:cached_context).and_return(models: { "Thing" => { encrypts: %w[ssn] } })
      result = ActiveRecord::Result.new(%w[id passwd:1 api_key:12 ssn:2 note:1 ratio:x], [ [ 1, "pw-value", "key-value", "ssn-value", "kept", "3:4" ] ])
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_return(result)

      %w[table csv].each do |format|
        text = RailsAiContext::RunCache.around { described_class.call(sql: "SELECT * FROM t", format: format) }.content.first[:text]
        expect(text).to include("kept", "3:4")
        expect(text).not_to include("pw-value", "key-value", "ssn-value")
        expect(text.scan("[FILTERED]").size).to eq(3)
      end
    end
  end

  describe "the timeouts of one call" do
    let(:runtime) { RailsAiContext::DatabaseFamily::SqliteRuntime }

    def timed(sql = "SELECT 41 + 1 AS answer")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = RailsAiContext::RunCache.around { described_class.call(sql: sql) }
      [ response, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started ]
    end

    it "answers its row when the context took longer than the timeout to build, and builds it outside the guarded reads" do
      RailsAiContext.configuration.query_timeout = 0.3
      guarded = false
      built_guarded = nil
      allow(runtime).to receive(:bounded).and_wrap_original do |original, *args, &reads|
        guarded = true
        original.call(*args, &reads)
      ensure
        guarded = false
      end
      allow(described_class).to receive(:cached_context) do
        built_guarded = guarded
        sleep 0.5
        {}
      end

      response, = timed

      expect(response.error?).to be(false)
      expect(response.content.first[:text]).to include("| 42")
      expect(built_guarded).to be(false)
    end

    it "keeps the rows of a statement that used most of its timeout after reads that used most of theirs" do
      RailsAiContext.configuration.query_timeout = 1
      allow(described_class).to receive(:cached_context).and_return({})
      allow(runtime).to receive(:relation_columns).and_wrap_original { |original, conn| sleep(0.6) && original.call(conn) }
      allow(runtime).to receive(:read_only).and_wrap_original { |original, *args| sleep(0.6) && original.call(*args) }

      response, took = timed

      expect(response.error?).to be(false)
      expect(response.content.first[:text]).to include("| 42")
      expect(runtime).to have_received(:read_only).with(anything, anything, 1)
      expect(took).to be_between(1.2, 2.2)
    end

    it "says the reads before the statement took the time and the statement was not run, when they used all of theirs" do
      RailsAiContext.configuration.query_timeout = 0.3
      allow(described_class).to receive(:cached_context).and_return({})
      allow(runtime).to receive(:relation_columns).and_wrap_original { |original, conn| sleep(0.4) && original.call(conn) }
      allow(runtime).to receive(:read_only).and_call_original

      response, took = timed

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to eq(
        "The reads rails_query makes before a statement (the columns of the schema, and on PostgreSQL the statement's plan) " \
        "took the whole 0.3 second timeout, so the statement was not run."
      )
      expect(runtime).not_to have_received(:read_only)
      expect(took).to be < 1.2
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

  describe "SQLite pragma functions and counters of the connection" do
    def answer(sql)
      response = described_class.call(sql: sql)
      [ response.error?, response.content.first[:text] ]
    end

    it "runs a pragma function that describes the schema or the database file" do
      ActiveRecord::Base.connection.create_table(:rac_pragma_rows, force: true) { |t| t.string :label }
      expect(answer("SELECT name FROM pragma_table_info('rac_pragma_rows') ORDER BY cid")).to match([ false, a_string_including("| label") ])
      expect(answer("SELECT page_size FROM pragma_page_size")).to match([ false, a_string_matching(/\| \d+/) ])
    ensure
      ActiveRecord::Base.connection.drop_table(:rac_pragma_rows, if_exists: true)
    end

    it "refuses a pragma function and a counter that tell of the connection, which is the tool's own" do
      { "SELECT * FROM pragma_foreign_keys" => "pragma_foreign_keys", "SELECT timeout FROM PRAGMA_BUSY_TIMEOUT" => "pragma_busy_timeout",
        %(SELECT * FROM "pragma_cache_size") => "pragma_cache_size", "SELECT changes() AS n" => "changes",
        "SELECT total_changes () AS n" => "total_changes", "SELECT last_insert_rowid() AS id" => "last_insert_rowid" }.each do |sql, name|
        expect(answer(sql)).to eq([ true, "Blocked: `#{name}` tells of the connection that runs it. rails_query runs a statement on a connection of its " \
          "own and sets some of that connection's values itself, so the answer would not be the app's. A pragma function that describes the schema or " \
          "the database file runs, for example `pragma_table_info`." ]), sql
      end
    end
  end

  describe "a literal that reads like an injection or a locking clause" do
    it "runs a literal holding OR 1=1" do
      response = described_class.call(sql: "SELECT 'a' AS v WHERE 'x' LIKE '%OR 1=1%' OR 1 = 1")
      expect(response.error?).to be(false)
      expect(response.content.first[:text]).to include("1 row returned")
    end

    it "runs a literal holding a locking phrase on PostgreSQL" do
      fake_family("PostgreSQL")
      allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:plan).and_return("Node Type" => "Result")
      allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:column_sources).and_return([])
      allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:read_only).and_return(ActiveRecord::Result.new(%w[id], [ [ 4 ] ]))

      response = described_class.call(sql: "SELECT id FROM orders WHERE notes LIKE '%ready for update%'")
      expect(response.error?).to be(false)
      expect(response.content.first[:text]).to include("| 4")
    end
  end

  describe "a SQLite view or generated column that reads a secret column" do
    let(:dir) { Dir.mktmpdir }
    let(:conn) do
      stub_const("QueryViewSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      QueryViewSpecRecord.establish_connection(adapter: "sqlite3", database: File.join(dir, "views.sqlite3"))
      QueryViewSpecRecord.connection.tap do |c|
        c.execute("CREATE TABLE accounts (id INTEGER, email TEXT, passwd TEXT, " \
          "shadow TEXT GENERATED ALWAYS AS (passwd) VIRTUAL, kept TEXT AS (passwd || '-kept') STORED, shout TEXT AS (upper(email)) VIRTUAL)")
        c.execute("CREATE TABLE notes (id INTEGER, body TEXT, size INTEGER AS (length(body)) VIRTUAL)")
        c.execute("INSERT INTO accounts (id, email, passwd) VALUES (1, 'a@example.com', 'pw-value')")
        c.execute("INSERT INTO notes (id, body) VALUES (1, 'hello')")
        c.execute("CREATE VIEW renamed AS SELECT id, passwd AS p1 FROM accounts")
        c.execute("CREATE VIEW nested AS SELECT p1 AS p2 FROM renamed")
        c.execute("CREATE VIEW everything (a, b, c, d, e, f) AS SELECT * FROM accounts")
        c.execute("CREATE VIEW contacts AS SELECT id, email FROM accounts")
      end
    end
    let(:context) { {} }

    before do
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
      allow(described_class).to receive(:cached_context).and_return(context)
    end

    after do
      QueryViewSpecRecord.remove_connection
      FileUtils.rm_rf(dir)
    end

    def answer(sql)
      RailsAiContext::RunCache.around { described_class.call(sql: sql) }
    end

    def text(sql)
      answer(sql).content.first[:text]
    end

    it "refuses a view that renames a secret column, a view built on it, and a view that lists every column" do
      {
        "renamed" => "the view `renamed` is not queried: its definition names the secret column `passwd`",
        "nested" => "the view `nested` is not queried: it reads the view `renamed`",
        "everything" => "the view `everything` is not queried: its definition has a wildcard and names `accounts`"
      }.each do |view, reason|
        response = answer("SELECT * FROM #{view}")
        expect(response.error?).to be(true), view
        expect(response.content.first[:text]).to include(reason, "on SQLite, so query the tables it reads")
        expect(response.content.first[:text]).not_to include("pw-value")
      end
    end

    it "runs a view that names no secret column" do
      expect(text("SELECT * FROM contacts")).to include("a@example.com")
    end

    # Rails before 7.2 asks the SQLite version here, and where no child process can run (no fork) the
    # statement and its query_only guard are sent on this connection: neither is a read of the schema.
    it "sends six reads of the schema before an ordinary statement" do
      conn
      sent = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| sent << payload[:sql] }
      expect(text("SELECT id, email FROM accounts WHERE id = 1")).to include("a@example.com")
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(sent.grep_v(/sqlite_version|query_only|FROM accounts/).size).to eq(6)
    end

    it "refuses a view whose definition holds a comment before its wildcard, and one named with a dollar or a quote" do
      conn.execute("CREATE VIEW lined (a, b, c, d, e, f) AS SELECT -- note\n * FROM accounts")
      conn.execute("CREATE VIEW blocked (a, b, c, d, e, f) AS SELECT /* note */ * FROM accounts")
      conn.execute(%(CREATE VIEW "v$" (a, b) AS SELECT id, passwd FROM accounts))
      conn.execute(%(CREATE VIEW "two  words" (a, b) AS SELECT id, passwd FROM accounts))
      conn.execute(%(CREATE VIEW "quo""ted" (a, b) AS SELECT id, passwd FROM accounts))

      [ "SELECT * FROM lined", "SELECT * FROM blocked", "SELECT * FROM v$", %(SELECT * FROM "v$"), %(SELECT * FROM "two  words"),
        "SELECT * FROM [two  words]", %(SELECT * FROM "quo""ted") ].each do |sql|
        response = answer(sql)
        expect(response.error?).to be(true), sql
        expect(response.content.first[:text]).to start_with("Blocked: the view `"), sql
        expect(response.content.first[:text]).not_to include("pw-value"), sql
      end
    end

    it "refuses a column-alias list in every spelling SQLite reads, and returns no secret value" do
      body = "(SELECT * FROM accounts)"
      lists = [ "(a, b, c, d, e, f)", '("a", "b", "c", "d", "e", "f")', "(`a`, `b`, `c`, `d`, `e`, `f`)", "([a], [b], [c], [d], [e], [f])",
                "('a', 'b', 'c', 'd', 'e', 'f')", "(\u00e9, \u00fc, \u00f1, \u00e5, \u00f8, \u00e7)", "(\u{1F600}, b, c, d, e, f)",
                "(a\u00a0b, b, c, d, e, f)", '(a, "b", `c`, [d], \'e\', f)', '("a""x", b, c, d, e, f)' ]
      statements = lists.flat_map do |list|
        [ "AS", "AS MATERIALIZED", "AS NOT MATERIALIZED", "as\nmaterialized" ].map { |as| "WITH t #{list} #{as} #{body} SELECT * FROM t" }
      end
      statements += [
        %(WITH "t" (a, b, c, d, e, f) AS #{body} SELECT * FROM "t"), "WITH [t] (a, b, c, d, e, f) AS #{body} SELECT * FROM [t]",
        "WITH 't' (a, b, c, d, e, f) AS #{body} SELECT * FROM 't'", "WITH key (a, b, c, d, e, f) AS #{body} SELECT * FROM key",
        "WITH t(a,b,c,d,e,f)AS(SELECT*FROM accounts)SELECT*FROM t", "WITH RECURSIVE t(a, b, c, d, e, f) AS #{body} SELECT * FROM t",
        "WITH x AS (SELECT 1 AS one), t(a, b, c, d, e, f) AS #{body} SELECT * FROM t",
        "WITH t /* x */ (a, b, c, d, e, f) -- y\n AS /* z */ #{body} SELECT * FROM t",
        "WITH t(a, b, c, d, e, f) AS (WITH u AS #{body} SELECT * FROM u) SELECT * FROM t",
        "SELECT * FROM (WITH t(a, b, c, d, e, f) AS #{body} SELECT * FROM t) x",
        "WITH t(a) AS (SELECT passwd_only.* FROM (SELECT 1) x, single passwd_only) SELECT * FROM t"
      ]
      conn.execute("CREATE TABLE single (passwd TEXT)")
      conn.execute("INSERT INTO single VALUES ('pw-value')")

      statements.each do |sql|
        response = answer(sql)
        expect(response.error?).to be(true), sql
        expect(response.content.first[:text]).to start_with("Blocked: a column-alias list"), sql
      end
      expect(text("WITH v(id, name) AS (VALUES (1, 'a'), (2, 'b')) SELECT * FROM v")).to include("2 rows returned")
    end

    it "refuses a wildcard inside a subquery over a table that holds a secret column, by the table and the column" do
      [ "SELECT (1, 'a@example.com', 'pw-valud', 'x', 'y', 'z') < (SELECT * FROM accounts) AS o",
        "SELECT (1, 'a@example.com', 'pw-valud', 'x', 'y', 'z') < (SELECT accounts.* FROM accounts) AS o",
        "SELECT * FROM (SELECT * FROM accounts a JOIN accounts b ON 1)", "SELECT * FROM (SELECT * FROM accounts) x",
        "WITH x AS (SELECT * FROM accounts) SELECT * FROM x", "SELECT id FROM notes WHERE 'pw' IN (SELECT a.* FROM accounts a)" ].each do |sql|
        response = answer(sql)
        expect(response.error?).to be(true), sql
        expect(response.content.first[:text]).to start_with(
          "Blocked: a `*` inside a subquery is not run in a statement that names `accounts`, which holds the secret column `passwd`. On SQLite"
        ).and(end_with("so name the columns in the subquery.")), sql
      end
    end

    it "runs a wildcard at the top, in EXISTS, in count(*) and in a subquery over a table with no secret column" do
      expect(text("SELECT * FROM accounts a JOIN accounts b ON 1")).to include("a@example.com").and(satisfy { |t| !t.include?("pw-value") })
      expect(text("SELECT EXISTS (SELECT * FROM accounts) AS found, (SELECT count(*) FROM accounts) AS n")).to include("| 1     | 1 |")
      expect(text("SELECT * FROM (SELECT * FROM notes) n")).to include("hello")
      expect(text("WITH n AS (SELECT * FROM notes) SELECT * FROM n")).to include("hello")
    end

    it "filters a generated column that reads a secret column, and refuses a statement naming it" do
      everything = text("SELECT * FROM accounts")
      expect(everything).to include("a@example.com", "[FILTERED]")
      expect(everything).not_to include("pw-value")
      expect(text("SELECT shadow AS s FROM accounts")).to include("`shadow` is a generated column")
      expect(text("SELECT kept AS k FROM accounts")).to include("secret column `kept`")
    end

    it "returns a generated column of a table that holds no secret column" do
      expect(text("SELECT size FROM notes")).to include("| 5")
    end

    it "returns a generated column that reads no secret column, beside two on the same table that read one" do
      expect(text("SELECT shout AS s FROM accounts")).to include("| A@EXAMPLE.COM")
      everything = text("SELECT * FROM accounts")
      expect(everything).to include("A@EXAMPLE.COM")
      expect(everything.scan("[FILTERED]").size).to eq(3)
    end

    it "filters a generated column named like a table constraint's keyword, beside that constraint" do
      conn.execute("CREATE TABLE owners (id INTEGER PRIMARY KEY)")
      {
        "constraint" => 'CONSTRAINT "fk_rails_1" FOREIGN KEY ("owner_id") REFERENCES "owners" ("id")',
        "check" => "CHECK (owner_id > 0)", "unique" => 'UNIQUE ("owner_id")', "primary" => 'PRIMARY KEY ("id")',
        "foreign" => 'FOREIGN KEY ("owner_id") REFERENCES "owners" ("id")'
      }.each do |column, constraint|
        conn.execute(%{CREATE TABLE "r_#{column}" ("id" integer, "password_digest" varchar, } +
          %{"#{column}" varchar GENERATED ALWAYS AS (password_digest) STORED, "owner_id" integer, #{constraint})})
        conn.execute(%(INSERT INTO "r_#{column}" (id, password_digest) VALUES (1, 'pw-value')))

        named = answer(%(SELECT "#{column}" FROM r_#{column}))
        expect(named.error?).to be(true), column
        expect(named.content.first[:text]).to include("`#{column}` is a generated column that reads `password_digest`"), column
        expect(text("SELECT * FROM r_#{column}")).to include("[FILTERED]").and(satisfy { |t| !t.include?("pw-value") }), column
      end
    end

    it "filters a generated column whose name differs from an innocent one's by the case of a letter past ASCII" do
      conn.execute(%(CREATE TABLE accents (id INTEGER, passwd TEXT, "É" TEXT AS (passwd) STORED, "é" TEXT AS (id) STORED)))
      conn.execute("INSERT INTO accents (id, passwd) VALUES (1, 'pw-value')")

      [ %(SELECT "É" FROM accents), %(SELECT "é" FROM accents), "SELECT * FROM accents" ].each do |sql|
        expect(text(sql)).not_to include("pw-value"), sql
      end
    end

    it "reads a generated column's own expression past a quoted name, a comma or a parenthesis in a name, and a default with a comma" do
      conn.execute(%{CREATE TABLE odd (id INTEGER, passwd TEXT, label TEXT DEFAULT 'a, b', "two words" TEXT AS (upper(label)) VIRTUAL, } +
        %{"a,b" TEXT AS (passwd) VIRTUAL, "c(d" TEXT AS (label || '!') VIRTUAL, "e""f" TEXT AS (passwd) VIRTUAL, [g h] TEXT AS (label) VIRTUAL, } +
        %{`i)j` TEXT AS (passwd) VIRTUAL, plain TEXT GENERATED ALWAYS AS (lower(label)) STORED, CHECK (id > 0))})
      conn.execute("INSERT INTO odd (id, passwd, label) VALUES (1, 'pw-value', 'Shown')")

      expect(text(%{SELECT "two words" AS a, "c(d" AS b, [g h] AS c, plain AS d FROM odd})).to include("| SHOWN | Shown! | Shown | shown |")
      [ %("a,b"), %("e""f"), "`i)j`" ].each do |column|
        expect(answer("SELECT #{column} AS x FROM odd").error?).to be(true), column
      end
      everything = text("SELECT * FROM odd")
      expect(everything).to include("SHOWN", "Shown!").and(satisfy { |t| !t.include?("pw-value") })
      expect(everything.scan("[FILTERED]").size).to eq(4)
    end

    context "when a second table has a generated column of the same name" do
      let(:context) { { models: { "Vault" => { encrypts: %w[ssn] } } } }

      before do
        conn.execute("CREATE TABLE vaults (id INTEGER, ssn TEXT, shadow TEXT AS (ssn) VIRTUAL)")
        conn.execute("INSERT INTO vaults (id, ssn) VALUES (1, 'ssn-value')")
        conn.execute("CREATE TABLE widgets (id INTEGER, label TEXT, twin TEXT AS (upper(label)) VIRTUAL)")
        conn.execute("CREATE TEMP TABLE widgets (id INTEGER, passwd TEXT, twin TEXT AS (passwd) VIRTUAL)")
        conn.execute("INSERT INTO temp.widgets (id, passwd) VALUES (1, 'pw-value')")
        RailsAiContext.configuration.query_allowed_columns = %w[shadow]
      end

      it "keeps the name secret past the allowed list when any column of that name reads an encrypts column" do
        named = answer("SELECT shadow AS s FROM vaults")
        expect([ named.error?, named.content.first[:text] ]).to match([ true, a_string_including("`shadow` is a generated column that reads `ssn`, an `encrypts` value") ])
        expect(text("SELECT * FROM vaults")).not_to include("ssn-value")
      end

      it "reads the expression of each table of one name in two schemas" do
        expect(answer("SELECT twin AS t FROM temp.widgets").error?).to be(true)
        expect(text("SELECT * FROM temp.widgets")).not_to include("pw-value")
      end

      it "reads every secret column a generated column's expression names" do
        rule = RailsAiContext::SecretColumns.new(relations: { "t" => %w[password_digest ssn both] }, encrypted: %w[ssn],
                                                 generated: { "t" => { "both" => "password_digest || ssn" } })
        expect(rule.encrypted?("both")).to be(true)
      end
    end

    it "releases a view and a generated column over a column the app allows" do
      RailsAiContext.configuration.query_allowed_columns = %w[passwd shadow kept]
      expect(text("SELECT * FROM renamed")).to include("pw-value")
      expect(text("SELECT shadow FROM accounts")).to include("pw-value")
    end

    context "when a model declares the column with encrypts" do
      let(:context) { { models: { "Account" => { encrypts: %w[passwd] } } } }

      it "keeps the view refused and the generated column secret, whatever the app allows" do
        RailsAiContext.configuration.query_allowed_columns = %w[passwd shadow kept]
        expect(answer("SELECT * FROM renamed").error?).to be(true)
        expect(answer("SELECT shadow FROM accounts").error?).to be(true)
        expect(text("SELECT * FROM accounts")).not_to include("pw-value")
      end
    end
  end

  describe "a PostgreSQL statement whose plan cannot be read" do
    let(:runtime) { RailsAiContext::DatabaseFamily::PostgresqlRuntime }

    before do
      fake_family("PostgreSQL")
      allow(runtime).to receive(:read_only).and_return(ActiveRecord::Result.new(%w[row], [ [ "secret-value" ] ]))
    end

    def answer(explain: false)
      response = described_class.call(sql: "SELECT row_to_json(a) AS row FROM accounts a", explain: explain)
      expect(response.error?).to be(true)
      expect(runtime).not_to have_received(:read_only)
      response.content.first[:text]
    end

    it "answers planning's timeout as the reads before the statement, and runs nothing" do
      allow(runtime).to receive(:plan).and_raise(RailsAiContext::DatabaseFamily::TimedOut, "canceling statement due to statement timeout")
      [ answer, answer(explain: true) ].each do |text|
        expect(text).to start_with("The reads rails_query makes before a statement").and end_with("took the whole 5 second timeout, so the statement was not run.")
      end
    end

    it "says the statement ran when the trace of its columns ran out of time" do
      allow(runtime).to receive(:plan).and_return("Node Type" => "Result")
      allow(runtime).to receive(:read_only).and_return(ActiveRecord::Result.new(%w[x], [ [ 1 ] ]))
      allow(runtime).to receive(:column_sources).and_raise(RailsAiContext::DatabaseFamily::TimedOut, "canceling statement due to statement timeout")
      response = described_class.call(sql: "SELECT 1 AS x")
      expect([ response.error?, response.content.first[:text] ]).to eq(
        [ true, "The statement ran, and the read that traces its result columns to their table columns took what was left of the " \
                "5 second timeout the reads beside a statement share, so its rows are not shown." ]
      )
    end

    it "answers planning's error as the SQL error and runs nothing" do
      allow(runtime).to receive(:plan).and_raise(ActiveRecord::StatementInvalid, %(PG::UndefinedTable: ERROR:  relation "accounts" does not exist))
      expect(answer).to start_with(%(SQL error: PG::UndefinedTable: ERROR:  relation "accounts" does not exist))
    end

    it "refuses the statement when planning answers no plan" do
      allow(runtime).to receive(:plan).and_return(nil)
      expect(answer).to include("its plan could not be read")
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

  describe "a failed call on each surface" do
    def cli(*args)
      runner = RailsAiContext::CLI::ToolRunner.new("query", args)
      [ runner.run, runner.error ]
    end

    def mcp(arguments)
      result = RailsAiContext::Server.new(Rails.application).build.handle(
        { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rails_query", arguments: arguments } }
      )[:result]
      [ result[:content].first[:text], result[:isError] ]
    end

    it "answers the production guard with a non-zero exit on the CLI and isError over MCP" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      guard = [ "rails_query is disabled in production for data privacy. Set config.allow_query_in_production = true to override.", true ]

      expect(cli("sql=SELECT 1")).to eq(guard)
      expect(mcp(sql: "SELECT 1")).to eq(guard)
    end

    let(:busy) do
      begin
        raise SQLite3::BusyException, "database is locked"
      rescue SQLite3::BusyException
        raise ActiveRecord::StatementInvalid, "SQLite3::BusyException: database is locked"
      end
    rescue ActiveRecord::StatementInvalid => e
      e
    end
    let(:locked) { [ "The database is locked by another connection, so the query did not run. Run it again when the other connection has finished.", true ] }

    it "answers a lock met while the connection opens as locked, and any other failure to connect as unreachable" do
      allow(ActiveRecord::Base.connection).to receive(:verify!).and_raise(busy)
      expect(cli("sql=SELECT 1")).to eq(locked)
      expect(mcp(sql: "SELECT 1")).to eq(locked)

      allow(ActiveRecord::Base.connection).to receive(:verify!).and_raise(ActiveRecord::ConnectionNotEstablished, "no file")
      expect(mcp(sql: "SELECT 1")).to match([ a_string_starting_with("The primary database cannot be reached: no file."), true ])
    end

    it "answers a locked SQLite database as locked, with no word of a timeout, for a query and for its EXPLAIN" do
      allow(ActiveRecord::Base.connection).to receive(:select_all).and_wrap_original do |original, sql, *rest, **options|
        sql.to_s.match?(/FROM users/) ? raise(busy) : original.call(sql, *rest, **options)
      end
      expect(cli("sql=SELECT id FROM users")).to eq(locked)
      expect(cli("sql=SELECT id FROM users", "explain=true")).to eq(locked)
      expect(mcp(sql: "SELECT id FROM users")).to eq(locked)

      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:relation_columns).and_raise(busy)
      expect(mcp(sql: "SELECT 1 AS one")).to eq(locked)
    end

    it "answers a failing EXPLAIN with a non-zero exit on the CLI and isError over MCP" do
      expect(cli("sql=SELECT nope FROM no_such_table", "explain=true")).to match([ a_string_starting_with("EXPLAIN failed:"), true ])
      expect(mcp(sql: "SELECT nope FROM no_such_table", explain: true)).to match([ a_string_starting_with("EXPLAIN failed:"), true ])
    end

    it "answers a database no connection reaches the same way" do
      allow(ActiveRecord::Base.connection).to receive(:verify!).and_raise(ActiveRecord::ConnectionNotEstablished, "refused")
      unreachable = [ "The primary database cannot be reached: refused. Check the file its config/database.yml entry names.", true ]

      expect(cli("sql=SELECT 1")).to eq(unreachable)
      expect(mcp(sql: "SELECT 1")).to eq(unreachable)
    end

    it "answers a timeout the same way, with the same text, for a query and for its EXPLAIN" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:read_only).and_raise(RailsAiContext::DatabaseFamily::TimedOut, "stopped")
      timeout = [ "Query exceeded 5 second timeout. Simplify the query or add indexes.", true ]

      expect(cli("sql=SELECT id FROM users")).to eq(timeout)
      expect(cli("sql=SELECT id FROM users", "explain=true")).to eq(timeout)
      expect(mcp(sql: "SELECT id FROM users")).to eq(timeout)
      expect(mcp(sql: "SELECT id FROM users", explain: true)).to eq(timeout)
    end
  end
end
