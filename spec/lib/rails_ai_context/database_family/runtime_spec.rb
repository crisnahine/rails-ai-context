# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe RailsAiContext::DatabaseFamily do
  # Fails on any message a statement could ride, so a refusal is proven to send nothing.
  let(:untouchable) do
    Class.new do
      def adapter_name = "SQLServer"

      def method_missing(name, *) = raise("#{name} reached the connection")

      def respond_to_missing?(*) = false
    end.new
  end

  # Records every statement and enforces MySQL's rule that transaction
  # characteristics cannot change once a transaction is open (error 1568).
  let(:mysql_class) do
    Class.new do
      attr_reader :statements
      attr_accessor :failure, :session_timeout, :session

      def initialize(mariadb)
        @mariadb = mariadb
        @statements = []
        @session_timeout = 250
        @session = 7
      end

      def adapter_name = "Mysql2"

      def mariadb? = @mariadb

      def transaction_open? = @in_transaction || false

      def execute(sql)
        raise ActiveRecord::StatementInvalid, "1568" if @in_transaction && sql.start_with?("SET TRANSACTION")

        @statements << sql
      end

      def select_rows(sql)
        @statements << sql
        [ [ @session_timeout, 31_536_000, 7 ] ]
      end

      def select_value(sql)
        @statements << sql
        @session
      end

      def transaction
        @statements << "BEGIN"
        @in_transaction = true
        yield
      rescue ActiveRecord::Rollback
        @statements << "ROLLBACK"
      ensure
        @in_transaction = false
      end

      def select_all(sql)
        @statements << sql
        raise failure if failure

        ActiveRecord::Result.new(%w[x], [ [ 1 ] ])
      end
    end
  end

  def statements
    sent = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| sent << payload[:sql] }
    yield
    sent
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # An adapter error whose cause carries the driver's native code, as Rails raises it.
  def driver_error(error_class, code, reader: :error_number)
    native = Class.new(StandardError) { attr_accessor reader }.new("native").tap { |e| e.public_send("#{reader}=", code) }
    begin
      raise native
    rescue
      raise error_class, "wrapped" rescue $!
    end
  end

  describe "MySQL" do
    let(:conn) { mysql_class.new(false) }

    it "bounds a WITH statement with the session max_execution_time and restores the session's own" do
      rows = described_class::MYSQL.read_only(conn, "WITH t AS (SELECT 1) SELECT * FROM t", timeout: 2)

      expect(rows.rows).to eq([ [ 1 ] ])
      expect(conn.statements).to eq([
        "SELECT @@SESSION.max_execution_time, @@SESSION.lock_wait_timeout, CONNECTION_ID()",
        "SET SESSION max_execution_time = 2000, lock_wait_timeout = 2",
        "SET TRANSACTION READ ONLY", "BEGIN", "SELECT CONNECTION_ID()", "WITH t AS (SELECT 1) SELECT * FROM t", "ROLLBACK",
        "SET SESSION max_execution_time = 250, lock_wait_timeout = 31536000"
      ])
    end

    it "bounds a block of reads the same way, answers what the block answers, and puts both session values back" do
      answer = described_class::MYSQL.bounded(conn, timeout: 0.4) { conn.select_all("SHOW FULL FIELDS FROM t") && :read }

      expect(answer).to eq(:read)
      expect(conn.statements).to eq([
        "SELECT @@SESSION.max_execution_time, @@SESSION.lock_wait_timeout, CONNECTION_ID()",
        "SET SESSION max_execution_time = 400, lock_wait_timeout = 1", "SHOW FULL FIELDS FROM t",
        "SET SESSION max_execution_time = 250, lock_wait_timeout = 31536000"
      ])
    end

    it "puts both session values back when a read in the block raises, and reads a lock wait that ran out as a timeout" do
      conn.failure = driver_error(ActiveRecord::StatementInvalid, 1205)

      expect { described_class::MYSQL.bounded(conn, timeout: 2) { conn.select_all("SHOW FULL FIELDS FROM t") } }
        .to raise_error(described_class::TimedOut)
      expect(conn.statements.last).to eq("SET SESSION max_execution_time = 250, lock_wait_timeout = 31536000")
    end

    it "changes nothing when the session values cannot be read" do
      conn.define_singleton_method(:select_rows) { |_sql| raise ActiveRecord::StatementInvalid, "gone" }

      expect { described_class::MYSQL.bounded(conn, timeout: 2) { raise "the block ran" } }.to raise_error(ActiveRecord::StatementInvalid, "gone")
      expect(conn.statements).to eq([])
    end

    it "restores the session's max_execution_time when the statement raises" do
      conn.failure = ActiveRecord::StatementInvalid.new("syntax")

      expect { described_class::MYSQL.read_only(conn, "EXPLAIN ANALYZE SELECT 1", timeout: 2) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(conn.statements.last).to eq("SET SESSION max_execution_time = 250, lock_wait_timeout = 31536000")
    end

    context "when the restore itself fails" do
      before do
        conn.failure = ActiveRecord::StatementInvalid.new("Lost connection to server during query")
        conn.define_singleton_method(:execute) do |sql|
          raise ActiveRecord::ConnectionNotEstablished, "gone" if sql.start_with?("SET SESSION max_execution_time = 250")

          statements << sql
        end
      end

      it "raises the statement's own error and takes the connection out of use" do
        conn.define_singleton_method(:throw_away!) { statements << "THROW AWAY" }

        expect { described_class::MYSQL.read_only(conn, "SELECT 1", timeout: 2) }
          .to raise_error(ActiveRecord::StatementInvalid, /Lost connection/)
        expect(conn.statements.last).to eq("THROW AWAY")
      end

      it "disconnects a connection that cannot be thrown away" do
        conn.define_singleton_method(:disconnect!) { statements << "DISCONNECT" }

        expect { described_class::MYSQL.read_only(conn, "SELECT 1", timeout: 2) }
          .to raise_error(ActiveRecord::StatementInvalid, /Lost connection/)
        expect(conn.statements.last).to eq("DISCONNECT")
      end

      it "takes the connection out of use after a statement that succeeded too" do
        conn.failure = nil
        conn.define_singleton_method(:throw_away!) { statements << "THROW AWAY" }

        expect(described_class::MYSQL.read_only(conn, "SELECT 1", timeout: 2).rows).to eq([ [ 1 ] ])
        expect(conn.statements.last).to eq("THROW AWAY")
      end
    end

    it "sends no statement when the session inside the transaction is another one, and raises the lost connection" do
      conn.session = 8

      expect { described_class::MYSQL.read_only(conn, "SELECT 1", timeout: 2) }
        .to raise_error(ActiveRecord::ConnectionNotEstablished, /the connection was replaced before the statement was sent/)
      expect(conn.statements).not_to include("SELECT 1")
      expect(conn.statements.last).to eq("SET SESSION max_execution_time = 250, lock_wait_timeout = 31536000")
    end

    it "refuses a guarded read inside a transaction that is already open, and sends nothing" do
      conn.transaction do
        expect { described_class::MYSQL.read_only(conn, "SELECT 1", timeout: 2) }
          .to raise_error(described_class::Unsupported, /already open/)
      end
      expect(conn.statements).to eq([ "BEGIN" ])
    end

    it "reads a 3024 or 1317 as a timeout" do
      [ 3024, 1317 ].each do |code|
        conn.failure = driver_error(ActiveRecord::StatementInvalid, code)
        expect { described_class::MYSQL.read_only(conn, "SELECT 1", timeout: 2) }.to raise_error(described_class::TimedOut)
      end
    end

    it "reads ActiveRecord's own timeout classes as a timeout" do
      conn.failure = ActiveRecord::StatementTimeout.new("stopped")
      expect { described_class::MYSQL.read_only(conn, "SELECT 1", timeout: 2) }.to raise_error(described_class::TimedOut)
    end

    it "reads a lock wait the database's own lock timeout ended as a timeout" do
      conn.failure = ActiveRecord::LockWaitTimeout.new("canceling statement due to lock timeout")
      expect { described_class::MYSQL.read_only(conn, "SELECT 1", timeout: 2) }.to raise_error(described_class::TimedOut)
    end

    it "raises a connection the server dropped as itself", if: defined?(ActiveRecord::ConnectionFailed) do
      conn.failure = ActiveRecord::ConnectionFailed.new("server closed the connection")
      expect { described_class::MYSQL.read_only(conn, "SELECT 1", timeout: 2) }
        .to raise_error(ActiveRecord::ConnectionFailed) { |e| expect(e).not_to be_a(described_class::TimedOut) }
    end

    it "reads an error that mentions a timeout column as an SQL error" do
      conn.failure = driver_error(ActiveRecord::StatementInvalid, 1054)
      conn.failure.define_singleton_method(:message) { "Unknown column 'timeout' in 'field list' (max_execution_time exceeded)" }

      expect { described_class::MYSQL.read_only(conn, "SELECT timeout FROM t", timeout: 2) }
        .to raise_error(ActiveRecord::StatementInvalid, /Unknown column/)
    end
  end

  it "lists equally large PostgreSQL tables by name" do
    conn = double("connection")
    allow(RailsAiContext::Introspectors::PgPartitions).to receive(:table_bytes).with(conn)
      .and_return([ { name: "posts", bytes: 8192 }, { name: "comments", bytes: 8192 }, { name: "users", bytes: 16384 } ])

    expect(described_class::POSTGRESQL.table_sizes(conn).map { |r| r[:name] }).to eq(%w[users comments posts])
  end

  it "sizes MySQL base tables only" do
    conn = double("connection")
    allow(conn).to receive(:select_all).with(a_string_matching(/TABLE_TYPE = 'BASE TABLE'/))
      .and_return([ { "name" => "products", "bytes" => 1024 } ])

    expect(described_class::MYSQL.table_sizes(conn)).to eq([ { name: "products", bytes: 1024 } ])
  end

  describe "MariaDB" do
    let(:conn) { mysql_class.new(true) }

    it "bounds a WITH statement with the session max_statement_time and restores the session's own" do
      described_class::MYSQL.read_only(conn, "WITH t AS (SELECT 1) SELECT * FROM t", timeout: 2)

      expect(conn.statements).to eq([
        "SELECT @@SESSION.max_statement_time, @@SESSION.lock_wait_timeout, CONNECTION_ID()",
        "SET SESSION max_statement_time = 2.0, lock_wait_timeout = 2",
        "SET TRANSACTION READ ONLY", "BEGIN", "SELECT CONNECTION_ID()", "WITH t AS (SELECT 1) SELECT * FROM t", "ROLLBACK",
        "SET SESSION max_statement_time = 250, lock_wait_timeout = 31536000"
      ])
    end

    it "bounds a block of reads the same way" do
      described_class::MYSQL.bounded(conn, timeout: 0.4) { conn.select_all("SHOW FULL FIELDS FROM t") }

      expect(conn.statements[1..]).to eq([
        "SET SESSION max_statement_time = 0.4, lock_wait_timeout = 1", "SHOW FULL FIELDS FROM t",
        "SET SESSION max_statement_time = 250, lock_wait_timeout = 31536000"
      ])
    end

    it "reads a 1969 from Trilogy as a timeout" do
      conn.failure = driver_error(ActiveRecord::StatementInvalid, 1969, reader: :error_code)
      expect { described_class::MYSQL.read_only(conn, "SELECT 1", timeout: 2) }.to raise_error(described_class::TimedOut)
    end
  end

  describe "a timeout of zero or under a millisecond" do
    [ 0, 0.0004 ].each do |timeout|
      it "still bounds a PostgreSQL statement, at one millisecond (#{timeout})" do
        conn = Class.new do
          attr_reader :statements

          def initialize = @statements = []

          def adapter_name = "PostgreSQL"

          def execute(sql) = @statements << sql

          def select_all(_sql) = ActiveRecord::Result.new(%w[x], [ [ 1 ] ])

          def transaction(**)
            yield
          rescue ActiveRecord::Rollback
            nil
          end
        end.new
        described_class::POSTGRESQL.read_only(conn, "SELECT 1", timeout: timeout)
        expect(conn.statements).to include("SET LOCAL statement_timeout = '1'")
      end

      it "still bounds a MySQL and a MariaDB statement (#{timeout})" do
        mysql = mysql_class.new(false)
        mariadb = mysql_class.new(true)
        described_class::MYSQL.read_only(mysql, "SELECT 1", timeout: timeout)
        described_class::MYSQL.read_only(mariadb, "SELECT 1", timeout: timeout)
        expect(mysql.statements).to include("SET SESSION max_execution_time = 1, lock_wait_timeout = 1")
        expect(mariadb.statements).to include("SET SESSION max_statement_time = 0.001, lock_wait_timeout = 1")
      end
    end

    it "times a SQLite statement out at once", if: Process.respond_to?(:fork) do
      Dir.mktmpdir do |dir|
        stub_const("RuntimeSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
        RuntimeSpecRecord.establish_connection(adapter: "sqlite3", database: File.join(dir, "bounded.sqlite3"))

        expect { described_class::SQLITE.read_only(RuntimeSpecRecord.connection, "SELECT 1", timeout: 0) }
          .to raise_error(described_class::TimedOut)
      ensure
        RuntimeSpecRecord.remove_connection
      end
    end
  end

  describe "a block of reads on PostgreSQL" do
    let(:conn) do
      Class.new do
        attr_reader :statements

        def initialize = @statements = []

        def adapter_name = "PostgreSQL"

        def execute(sql) = @statements << sql

        def transaction(requires_new:)
          @statements << "BEGIN"
          yield
        rescue ActiveRecord::Rollback
          @statements << "ROLLBACK"
        end
      end.new
    end

    it "runs read-only under SET LOCAL statement_timeout, answers what the block answers, and rolls back" do
      answer = described_class::POSTGRESQL.bounded(conn, timeout: 0.25) { conn.execute("SELECT attname FROM pg_attribute") && :read }

      expect(answer).to eq(:read)
      expect(conn.statements).to eq([
        "BEGIN", "SET TRANSACTION READ ONLY", "SET LOCAL statement_timeout = '250'", "SELECT attname FROM pg_attribute", "ROLLBACK"
      ])
    end

    it "raises a read the timeout ended as the timeout" do
      expect { described_class::POSTGRESQL.bounded(conn, timeout: 1) { raise ActiveRecord::QueryCanceled, "canceling statement due to statement timeout" } }
        .to raise_error(described_class::TimedOut)
    end
  end

  describe "a block of reads on SQLite" do
    it "answers what the block answers, and raises a read of a database another connection has locked as busy, which is no timeout" do
      conn = double("connection")
      busy = begin
        begin
          raise SQLite3::BusyException, "database is locked"
        rescue SQLite3::BusyException
          raise ActiveRecord::StatementInvalid, "SQLite3::BusyException: database is locked"
        end
      rescue ActiveRecord::StatementInvalid => e
        e
      end

      expect(described_class::SQLITE.bounded(conn, timeout: 1) { :read }).to eq(:read)
      expect { described_class::SQLITE.bounded(conn, timeout: 1) { raise busy } }
        .to raise_error(described_class::Busy) { |e| expect(e).not_to be_a(described_class::TimedOut) }
      expect(described_class.timed_out?(busy)).to be(false)
    end
  end

  it "refuses a block of reads on an adapter with no family before running it" do
    expect { described_class.of(untouchable).bounded(untouchable, timeout: 1) { raise "the block ran" } }
      .to raise_error(described_class::Unsupported, /SQLServer/)
  end

  describe "the schema reads on SQLite" do
    let(:dir) { Dir.mktmpdir }

    before do
      stub_const("RuntimeSchemaRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      RuntimeSchemaRecord.establish_connection(adapter: "sqlite3", database: File.join(dir, "schema.sqlite3"))
      @conn = RuntimeSchemaRecord.connection
      @conn.execute("CREATE TABLE accounts (id INTEGER, passwd TEXT, shadow TEXT AS (passwd) VIRTUAL, kept TEXT AS (id || 'k') STORED)")
      @conn.execute("CREATE TABLE notes (id INTEGER, body TEXT)")
      @conn.execute("CREATE VIEW people (a, b) AS SELECT id, passwd FROM accounts")
    end

    after do
      RuntimeSchemaRecord.remove_connection
      FileUtils.rm_rf(dir)
    end

    it "explains a statement by the tables it reads, says which names the statement gave, and reads no table for a constant row" do
      joined = described_class::SQLITE.explain(@conn, "SELECT a.id FROM accounts a JOIN notes ON notes.id = a.id", timeout: 5)
      constant = described_class::SQLITE.explain(@conn, "SELECT 1", timeout: 5)

      expect(joined[:scan_types].map { |scan| scan[:table] }).to contain_exactly("a (a name the statement gives)", "notes")
      expect(joined[:warnings]).to all(start_with("Full table scan on "))
      expect(constant).to include(scan_types: [], warnings: [], raw: "SCAN CONSTANT ROW")
    end

    it "explains a search of a table the statement names scan as a search" do
      @conn.execute("CREATE INDEX notes_id ON notes (id)")

      expect(described_class::SQLITE.explain(@conn, "SELECT scan.body FROM notes scan WHERE scan.id = 1", timeout: 5)[:scan_types])
        .to eq([ { table: "scan (a name the statement gives)", type: "index search", index: "notes_id" } ])
    end

    it "lists every table's columns, generated ones too, in one statement" do
      columns = nil
      expect(statements { columns = described_class::SQLITE.relation_columns(@conn) }.size).to eq(1)
      expect(columns).to eq("accounts" => %w[id passwd shadow kept], "notes" => %w[id body])
    end

    it "answers the whole table definition for a generated column whose own expression it cannot tell" do
      runtime = RailsAiContext::DatabaseFamily::SqliteRuntime
      definition = %(CREATE TABLE t ("x" TEXT AS (passwd), "X" TEXT AS (id), passwd TEXT, id INTEGER, CHECK (id > 0)))
      allow(@conn).to receive(:select_rows).and_return([ [ "t", "x", 2, definition ], [ "t", "passwd", 0, definition ] ])

      expect(runtime.column_expressions(definition)).to eq("x" => nil, "passwd" => nil, "id" => nil)
      expect(described_class::SQLITE.generated_columns(@conn)).to eq("t" => { "x" => definition })
    end

    it "keeps each generated column's own expression where two names differ by the case of a letter past ASCII, as SQLite tells them apart" do
      @conn.execute(%(CREATE TABLE accents (id INTEGER, passwd TEXT, "É" TEXT AS (passwd) STORED, "é" TEXT AS (id) STORED)))

      expect(described_class::SQLITE.generated_columns(@conn)["accents"]).to match("É" => a_string_matching(/\A \(passwd\)/), "é" => a_string_matching(/\A \(id\)/))
    end

    it "reads the view bodies in one statement and the generated columns in one" do
      views = generated = nil
      expect(statements { views = described_class::SQLITE.view_definitions(@conn) }.size).to eq(1)
      expect(statements { generated = described_class::SQLITE.generated_columns(@conn) }.size).to eq(1)

      expect(views).to eq("people" => " SELECT id, passwd FROM accounts")
      expect(generated.keys).to eq([ "accounts" ])
      expect(generated["accounts"].keys).to eq(%w[shadow kept])
      expect(generated["accounts"]["shadow"]).to match(/\bpasswd\b/).and satisfy { |text| text.scan(/\bpasswd\b/).size == 1 }
    end

    it "lists the shadow tables of the schemas it is given and of no other" do
      @conn.execute("CREATE VIRTUAL TABLE docs USING fts5(body)")
      @conn.execute("ATTACH DATABASE '#{File.join(dir, "side.sqlite3")}' AS side")
      @conn.execute("CREATE VIRTUAL TABLE side.docs_more USING fts5(body)")

      expect(described_class::SQLITE.index_tables(@conn)).to include("docs_data" => [ :shadow, "docs" ])
      expect(described_class::SQLITE.index_tables(@conn).keys).not_to include("docs_more_data")
      expect(described_class::SQLITE.index_tables(@conn, %w[main SIDE])).to include("docs_more_data" => [ :shadow, "docs_more" ])
    end
  end

  describe "a SQLite statement" do
    let(:dir) { Dir.mktmpdir }

    def connect(database)
      stub_const("RuntimeStatementRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      RuntimeStatementRecord.establish_connection(adapter: "sqlite3", database: database)
      RuntimeStatementRecord.connection.tap do |conn|
        conn.execute("CREATE TABLE big (n INTEGER)")
        conn.execute("INSERT INTO big WITH RECURSIVE r(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM r WHERE x < 2000) SELECT x FROM r")
      end
    end

    after do
      RuntimeStatementRecord.remove_connection
      FileUtils.rm_rf(dir)
    end

    context "in a file", if: Process.respond_to?(:fork) do
      let(:conn) { connect(File.join(dir, "statement.sqlite3")) }

      it "answers from the rows of a transaction that is already open, on the app's own connection, and leaves it as it found it" do
        conn.transaction do
          conn.execute("INSERT INTO big VALUES (2001)")
          result = described_class::SQLITE.read_only(conn, "SELECT count(*) FROM big", timeout: 5)
          expect([ result.rows, result.unbounded ]).to eq([ [ [ 2001 ] ], true ])
          expect { described_class::SQLITE.read_only(conn, "INSERT INTO big VALUES (9)", timeout: 5) }
            .to raise_error(ActiveRecord::StatementInvalid, /readonly/)
          conn.execute("INSERT INTO big VALUES (2002)")
        end

        expect(conn.select_value("SELECT count(*) FROM big")).to eq(2002)
      end

      # total_changes() is 0 in the child and above it here, so only the child reaches the failing branch.
      it "raises the error of a statement that fails while it runs, whatever its message says, and runs it nowhere else" do
        sql = "SELECT CASE WHEN total_changes() = 0 THEN json_extract('{}', 'no such function: x') " \
          "ELSE (SELECT count(*) FROM big a, big b) END AS n"
        conn

        sent = statements do
          expect { described_class::SQLITE.read_only(conn, sql, timeout: 5) }
            .to raise_error(ActiveRecord::StatementInvalid, /no such function: x/) { |e| expect(e).not_to be_a(described_class::TimedOut) }
        end
        expect(sent).to eq([])
      end

      it "raises the SQL error of a statement neither connection can prepare" do
        expect { described_class::SQLITE.read_only(conn, "SELECT * FROM [no such function: x]", timeout: 5) }
          .to raise_error(ActiveRecord::StatementInvalid, /no such table/)
        expect(conn.select_value("PRAGMA query_only")).to eq(0)
      end
    end

    context "on the app's own connection" do
      let(:conn) { connect(":memory:") }
      # 400,000 rows, each after a scan of the table: it returns to Ruby between rows for minutes.
      let(:slow_rows) { "SELECT a.n FROM big a, big d WHERE d.n <= 200 AND (SELECT count(*) FROM big b WHERE b.n <> a.n + d.n) >= 0" }

      it "ends a statement that returns rows slowly at the deadline, as the timeout, and leaves the connection usable" do
        expect { described_class::SQLITE.read_only(conn, slow_rows, timeout: 0.5) }.to raise_error(described_class::TimedOut)
        expect(conn.select_value("PRAGMA query_only")).to eq(0)
        expect(described_class::SQLITE.read_only(conn, "SELECT count(*) FROM big", timeout: 5).to_h)
          .to eq(columns: [ "count(*)" ], rows: [ [ 2000 ] ], unbounded: true)
      end

      it "puts PRAGMA query_only back to the value it found" do
        conn.execute("PRAGMA query_only = ON")
        described_class::SQLITE.read_only(conn, "SELECT 1", timeout: 5)

        expect(conn.select_value("PRAGMA query_only")).to eq(1)
      end

      it "raises the statement's own error and takes the connection out of use when query_only cannot be put back" do
        allow(conn).to receive(:execute).and_call_original
        allow(conn).to receive(:execute).with("PRAGMA query_only = 0").and_raise(ActiveRecord::StatementInvalid, "reset failed")
        allow(conn).to receive(:throw_away!)

        expect { described_class::SQLITE.read_only(conn, "SELECT nope", timeout: 5) }
          .to raise_error(ActiveRecord::StatementInvalid, /no such column: nope/)
        expect(conn).to have_received(:throw_away!)
      end

      it "leaves a transaction that is already open as it found it" do
        conn.transaction do
          conn.execute("INSERT INTO big VALUES (2001)")
          expect { described_class::SQLITE.read_only(conn, "INSERT INTO big VALUES (9)", timeout: 5) }
            .to raise_error(ActiveRecord::StatementInvalid, /readonly/)
          expect(described_class::SQLITE.read_only(conn, "SELECT count(*) FROM big", timeout: 5).rows).to eq([ [ 2001 ] ])
          conn.execute("INSERT INTO big VALUES (2002)")
        end

        expect(conn.select_value("SELECT count(*) FROM big")).to eq(2002)
      end

      it "times a statement out at once when the timeout is zero" do
        conn

        expect(statements { expect { described_class::SQLITE.read_only(conn, "SELECT 1", timeout: 0) }.to raise_error(described_class::TimedOut) })
          .to eq([])
      end
    end
  end

  it "raises errors under the gem's own base class" do
    expect([ described_class::TimedOut, described_class::Unsupported ]).to all(be < RailsAiContext::Error)
  end

  describe "#column_sources" do
    it "names no source column on SQLite and MySQL" do
      expect(described_class::SQLITE.column_sources(nil, "SELECT 1", plan: nil)).to eq([])
      expect(described_class::MYSQL.column_sources(nil, "SELECT 1", plan: nil)).to eq([])
    end

    it "reads PostgreSQL's top plan Output by position, past any rename" do
      plan = { "Node Type" => "Hash Join", "Output" => [ "p.title", "u.api_token", '"*SELECT* 1".t', "upper(u.email)" ],
               "Plans" => [ { "Relation Name" => "posts", "Alias" => "p" }, { "Relation Name" => "users", "Alias" => "u" } ] }

      expect(described_class::POSTGRESQL.column_sources(untouchable, "SELECT ...", plan: plan))
        .to eq([ [ 0, "title", "posts" ], [ 1, "api_token", "users" ] ])
    end

    # Result columns from oid 10 (accounts) and oid 20 (tokens); reading accounts' columns fails.
    let(:described_pg) do
      desc = double("description", nfields: 2)
      allow(desc).to receive(:ftable) { |i| [ 10, 20 ][i] }
      allow(desc).to receive(:ftablecol) { |i| [ 3, 2 ][i] }
      raw = double("raw", prepare: nil, describe_prepared: desc, exec: nil)
      conn = double("connection", raw_connection: raw)
      allow(conn).to receive(:select_value) { |sql| sql.include?("= 10") ? "accounts" : "tokens" }
      allow(conn).to receive(:select_rows) do |sql|
        raise ActiveRecord::StatementInvalid, "permission denied" if sql.include?("= 10")

        [ [ 1, "id" ], [ 2, "api_token" ] ]
      end
      conn
    end

    it "keeps one relation's described columns when another relation's column names cannot be read" do
      expect(described_class::POSTGRESQL.column_sources(described_pg, "SELECT ...", plan: { "Node Type" => "Result" }))
        .to eq([ [ 0, nil, "accounts" ], [ 1, "api_token", "tokens" ] ])
    end

    it "names no PostgreSQL source without the statement's plan" do
      expect { described_class::POSTGRESQL.column_sources(untouchable, "SELECT 1", plan: nil) }
        .to raise_error(ArgumentError, /plan/)
    end
  end

  describe "PostgreSQL planning" do
    let(:conn) { double("connection") }

    it "raises a timeout and an SQL error" do
      allow(described_class::PostgresqlRuntime).to receive(:read_only).and_raise(described_class::TimedOut, "stopped")
      expect { described_class::POSTGRESQL.plan(conn, "SELECT 1", timeout: 2) }.to raise_error(described_class::TimedOut)

      allow(described_class::PostgresqlRuntime).to receive(:read_only).and_raise(ActiveRecord::StatementInvalid, "syntax")
      expect { described_class::POSTGRESQL.plan(conn, "SELECT nope", timeout: 2) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "answers no plan for text that is not one" do
      [ "not json", "{}", "[]" ].each do |text|
        allow(described_class::PostgresqlRuntime).to receive(:read_only)
          .and_return(described_class::Rows.new(%w[plan], [ [ text ] ], false))
        expect(described_class::POSTGRESQL.plan(conn, "SELECT 1", timeout: 2)).to be_nil, text
      end
    end
  end

  describe "an adapter with no family" do
    let(:family) { described_class.of(untouchable) }

    %i[read_only explain plan].each do |call|
      it "refuses #{call} by the adapter's name before touching the connection" do
        expect { family.public_send(call, untouchable, "SELECT 1", timeout: 5) }
          .to raise_error(described_class::Unsupported, /SQLServer/)
      end
    end

    %i[table_sizes row_estimates index_usage].each do |call|
      it "refuses #{call} by the adapter's name before touching the connection" do
        expect { family.public_send(call, untouchable) }.to raise_error(described_class::Unsupported, /SQLServer/)
      end
    end
  end
end
