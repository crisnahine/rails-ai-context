# frozen_string_literal: true

require "spec_helper"

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
      attr_accessor :failure, :session_timeout

      def initialize(mariadb)
        @mariadb = mariadb
        @statements = []
        @session_timeout = 250
      end

      def adapter_name = "Mysql2"

      def mariadb? = @mariadb

      def execute(sql)
        raise ActiveRecord::StatementInvalid, "1568" if @in_transaction && sql.start_with?("SET TRANSACTION")

        @statements << sql
      end

      def select_value(sql)
        @statements << sql
        @session_timeout
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
        "SELECT @@SESSION.max_execution_time", "SET SESSION max_execution_time = 2000",
        "SET TRANSACTION READ ONLY", "BEGIN", "WITH t AS (SELECT 1) SELECT * FROM t", "ROLLBACK",
        "SET SESSION max_execution_time = 250"
      ])
    end

    it "restores the session's max_execution_time when the statement raises" do
      conn.failure = ActiveRecord::StatementInvalid.new("syntax")

      expect { described_class::MYSQL.read_only(conn, "EXPLAIN ANALYZE SELECT 1", timeout: 2) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(conn.statements.last).to eq("SET SESSION max_execution_time = 250")
    end

    context "when the restore itself fails" do
      before do
        conn.failure = ActiveRecord::StatementInvalid.new("Lost connection to server during query")
        conn.define_singleton_method(:execute) do |sql|
          raise ActiveRecord::ConnectionNotEstablished, "gone" if sql == "SET SESSION max_execution_time = 250"

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

    it "bounds a WITH statement with SET STATEMENT max_statement_time inside the read-only transaction" do
      described_class::MYSQL.read_only(conn, "WITH t AS (SELECT 1) SELECT * FROM t", timeout: 2)

      expect(conn.statements).to eq([
        "SET TRANSACTION READ ONLY", "BEGIN",
        "SET STATEMENT max_statement_time = 2.0 FOR WITH t AS (SELECT 1) SELECT * FROM t", "ROLLBACK"
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
        conn = mysql_class.new(false)
        conn.define_singleton_method(:execute) { |sql| statements << sql }
        described_class::POSTGRESQL.read_only(conn, "SELECT 1", timeout: timeout)
        expect(conn.statements).to include("SET LOCAL statement_timeout = '1'")
      end

      it "still bounds a MySQL and a MariaDB statement (#{timeout})" do
        mysql = mysql_class.new(false)
        mariadb = mysql_class.new(true)
        described_class::MYSQL.read_only(mysql, "SELECT 1", timeout: timeout)
        described_class::MYSQL.read_only(mariadb, "SELECT 1", timeout: timeout)
        expect(mysql.statements).to include("SET SESSION max_execution_time = 1")
        expect(mariadb.statements).to include("SET STATEMENT max_statement_time = 0.001 FOR SELECT 1")
      end
    end

    it "times a SQLite statement out at once", if: Process.respond_to?(:fork) do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "bounded.sqlite3")
        SQLite3::Database.new(path).close
        conn = double("connection", pool: double(db_config: double(configuration_hash: {})))
        allow(described_class::SqliteRuntime).to receive(:fork_path).and_return(path)

        expect { described_class::SQLITE.read_only(conn, "SELECT 1", timeout: 0) }.to raise_error(described_class::TimedOut)
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
      expect(described_class::POSTGRESQL.column_sources(described_pg, "SELECT ...", plan: nil))
        .to eq([ [ 0, nil, "accounts" ], [ 1, "api_token", "tokens" ] ])
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
