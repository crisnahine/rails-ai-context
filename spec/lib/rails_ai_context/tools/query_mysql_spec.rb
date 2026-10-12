# frozen_string_literal: true

require "spec_helper"
require "uri"

# rails_query against a real MySQL and a real MariaDB, where no result column is traced to its table
# column. Each group runs only when its URL is set.
RSpec.describe RailsAiContext::Tools::Query do
  { "MySQL" => "RAC_TEST_MYSQL_URL", "MariaDB" => "RAC_TEST_MARIADB_URL" }.each do |server, env|
    describe "on #{server}", skip: (ENV[env] ? false : "set #{env} to run rails_query against #{server}") do
      let(:conn) { RacMysqlQueryRecord.connection }
      let(:env) { env }
      let(:context) { {} }
      let(:runtime) { RailsAiContext::DatabaseFamily::MysqlRuntime }

      def drop
        %w[rac_my_nested rac_my_renamed rac_my_everything rac_my_contacts].each { |view| conn.execute("DROP VIEW IF EXISTS #{view}") }
        %w[rac_my_accounts rac_my_plain].each { |table| conn.execute("DROP TABLE IF EXISTS #{table}") }
      end

      before do
        described_class.reset_cache!
        RailsAiContext.configuration.query_allowed_columns = []
        stub_const("RacMysqlQueryRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
        RacMysqlQueryRecord.establish_connection(ENV.fetch(env))
        drop
        conn.execute("CREATE TABLE rac_my_accounts (id int, email varchar(50), passwd varchar(50), " \
          "shadow varchar(50) AS (passwd) VIRTUAL, kept varchar(60) AS (concat(shadow, '-kept')) STORED, shout varchar(50) AS (upper(email)) VIRTUAL)")
        conn.execute("INSERT INTO rac_my_accounts (id, email, passwd) VALUES (1, 'a@example.com', 'pw-value')")
        conn.execute("CREATE VIEW rac_my_renamed AS SELECT id, passwd AS p1 FROM rac_my_accounts")
        conn.execute("CREATE VIEW rac_my_nested AS SELECT p1 AS p2 FROM rac_my_renamed")
        conn.execute("CREATE VIEW rac_my_everything AS SELECT * FROM rac_my_accounts")
        conn.execute("CREATE VIEW rac_my_contacts AS SELECT id, email, shout FROM rac_my_accounts")
        allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
        allow(described_class).to receive(:cached_context).and_return(context)
      end

      after do
        drop
        RacMysqlQueryRecord.remove_connection
        RailsAiContext.configuration.query_timeout = 5
        RailsAiContext.configuration.query_allowed_columns = []
      end

      def answer(sql, **options)
        RailsAiContext::RunCache.around { described_class.call(sql: sql, **options) }
      end

      def text(sql, **options)
        answer(sql, **options).content.first[:text]
      end

      describe "a table in another database of the server" do
        def drop_others
          conn.execute("DROP VIEW IF EXISTS rac_my_across")
          %w[rac_my_other rac_my_third].each { |name| conn.execute("DROP DATABASE IF EXISTS #{name}") }
        end

        before do
          drop_others
          %w[rac_my_other rac_my_third].each { |name| conn.execute("CREATE DATABASE #{name}") }
          conn.execute("CREATE TABLE rac_my_other.acc (id int, email varchar(50), session_token varchar(50), passwd varchar(50))")
          conn.execute("INSERT INTO rac_my_other.acc VALUES (1, 'b@example.com', 'tok-value', 'pw2-value')")
          conn.execute("CREATE TABLE rac_my_third.far (id int, far_token varchar(50))")
          conn.execute("INSERT INTO rac_my_third.far VALUES (1, 'far-value')")
          conn.execute("CREATE VIEW rac_my_other.v AS SELECT id, passwd AS p FROM rac_my_other.acc")
          conn.execute("CREATE VIEW rac_my_other.chain AS SELECT far_token AS f FROM rac_my_third.far")
          conn.execute("CREATE VIEW rac_my_across AS SELECT id, session_token AS t FROM rac_my_other.acc")
        end

        after { drop_others }

        def refused(statements, start)
          statements.each do |sql|
            response = answer(sql)
            expect([ response.error?, response.content.first[:text] ]).to match([ true, a_string_starting_with(start) ]), sql
            expect(response.content.first[:text]).not_to include("tok-value", "pw2-value", "far-value"), sql
          end
        end

        it "refuses a statement that names its secret column, as it does for a table of the connection's database" do
          from = "FROM rac_my_other.acc"
          refused([ "SELECT session_token AS x #{from}", "SELECT upper(session_token) #{from}", "SELECT concat(session_token, '') AS d #{from}",
                    "SELECT d FROM (SELECT session_token AS d #{from}) s", "SELECT id #{from} WHERE session_token LIKE 'tok%'",
                    "SELECT max(session_token) AS m #{from}", "SELECT id #{from} ORDER BY session_token", "SELECT (SELECT session_token #{from} LIMIT 1) AS d",
                    "SELECT session_token AS x FROM `rac_my_other` . `acc`", "SELECT session_token AS x FROM rac_my_other/* c */.acc",
                    "SELECT a.email, o.session_token AS d FROM rac_my_accounts a JOIN rac_my_other.acc o ON o.id = a.id" ],
                  "Blocked: query references secret column `session_token`")
          refused([ "SELECT passwd AS x #{from}" ], "Blocked: query references secret column `passwd`")
          refused([ "SELECT * FROM (SELECT * #{from}) s", "SELECT s.id FROM (SELECT * #{from}) s WHERE s.email LIKE 'b%'" ], "Blocked: ")
        end

        it "refuses a view over it, in either database, and a view that leads to a third database" do
          refused([ "SELECT * FROM rac_my_across", "SELECT t FROM rac_my_across" ],
                  "Blocked: the view `rac_my_across` is not queried: its definition names the secret column `session_token`")
          refused([ "SELECT * FROM rac_my_other.v", "SELECT upper(p) AS u FROM rac_my_other.v" ],
                  "Blocked: the view `v` is not queried: its definition names the secret column `passwd`")
          refused([ "SELECT * FROM rac_my_other.chain" ], "Blocked: the view `chain` is not queried: its definition names the secret column `far_token`")
        end

        it "filters its secret columns in place, runs a join that reads none, and shows a refused view's definition" do
          listed = answer("SELECT * FROM rac_my_other.acc")
          expect([ listed.error?, listed.content.first[:text] ]).to match([ false, a_string_including("b@example.com", "[FILTERED]") ])
          expect(listed.content.first[:text]).not_to include("tok-value", "pw2-value")
          joined = answer("SELECT a.email, o.email AS other FROM rac_my_accounts a JOIN rac_my_other.acc o ON o.id = a.id")
          expect([ joined.error?, joined.content.first[:text] ]).to match([ false, a_string_including("a@example.com", "b@example.com") ])
          expect(answer("SHOW CREATE VIEW rac_my_other.v").error?).to be(false)
        end

        it "reads the other database's columns in the same budget, and no system schema" do
          sent = []
          subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| sent << payload[:sql] }
          answer("SELECT o.id FROM rac_my_other.acc o JOIN information_schema.TABLES t ON t.TABLE_NAME = 'acc'")
          ActiveSupport::Notifications.unsubscribe(subscriber)

          asked = sent.grep(/SCHEMATA/)
          expect(asked.size).to eq(2)
          expect(sent.grep(/TABLE_SCHEMA IN \('rac_my_other'\)/).size).to eq(3)
          expect(sent.grep(/TABLE_SCHEMA IN \('rac_my_third'\)/).size).to eq(3)
          expect(sent.grep(/TABLE_SCHEMA IN \('information_schema'\)/)).to be_empty
        end
      end

      it "refuses every spelling of a locking read and sends none" do
        allow(runtime).to receive(:read_only).and_call_original
        [ "LOCK IN SHARE MODE", "FOR SHARE", "FOR UPDATE", "FOR UPDATE NOWAIT", "FOR UPDATE SKIP LOCKED", "FOR SHARE OF rac_my_accounts",
          "FOR UPDATE WAIT 1", "LOCK IN SHARE MODE WAIT 1" ].each do |lock|
          response = answer("SELECT id FROM rac_my_accounts LIMIT 5 #{lock}")
          expect(response.error?).to be(true), lock
          expect(response.content.first[:text]).to start_with("Blocked: locking read"), lock
        end
        expect(text("SELECT id FROM rac_my_accounts WHERE email LIKE '%lock in share mode%'")).to start_with("Blocked: locking read")
        expect(runtime).not_to have_received(:read_only)
      end

      it "refuses a view that renames a secret column, a view built on it, and a view of every column" do
        {
          "rac_my_renamed" => "the view `rac_my_renamed` is not queried: its definition names the secret column `passwd`",
          "rac_my_nested" => "the view `rac_my_nested` is not queried: it reads the view `rac_my_renamed`",
          "rac_my_everything" => "the view `rac_my_everything` is not queried: its definition names the secret column `passwd`"
        }.each do |view, reason|
          response = answer("SELECT * FROM #{view}")
          expect(response.error?).to be(true), view
          expect(response.content.first[:text]).to include(reason, "on MySQL, so query the tables it reads")
          expect(response.content.first[:text]).not_to include("pw-value")
        end
      end

      def refused(statements, start)
        allow(runtime).to receive(:read_only).and_call_original
        statements.each do |sql|
          response = answer(sql)
          expect(response.error?).to be(true), sql
          expect(response.content.first[:text]).to start_with(start), sql
        end
        expect(runtime).not_to have_received(:read_only)
      end

      it "refuses a column-alias list in every spelling the server reads" do
        body = "(SELECT * FROM rac_my_accounts)"
        refused([
          "SELECT * FROM #{body} AS t (a, b, c, d, e, f)", "SELECT * FROM #{body} t (a, b, c, d, e, f)", "SELECT * FROM #{body}t(a,b,c,d,e,f)",
          "SELECT * FROM #{body} `t` (`a`, `b`, `c`, `d`, `e`, `f`)", "SELECT * FROM #{body} any (a, b, c, d, e, f)",
          "SELECT * FROM #{body} ilike (a, b, c, d, e, f)", "SELECT * FROM #{body} AS \u00e9 (\u00e9, b, c, d, e, f)",
          "SELECT * FROM (TABLE rac_my_accounts) AS t (a, b, c, d, e, f)", "SELECT * FROM (#{body}) t (a, b, c, d, e, f)",
          "SELECT * FROM rac_my_contacts, LATERAL #{body} AS t (a, b, c, d, e, f)", "SELECT * FROM rac_my_contacts, LATERAL #{body} t (a, b, c, d, e, f)",
          "WITH t (a, b, c, d, e, f) AS #{body} SELECT * FROM t", "WITH t (`a`, `b`, `c`, `d`, `e`, `f`) AS #{body} SELECT * FROM t",
          "WITH `t` (a, b, c, d, e, f) AS (TABLE rac_my_accounts) SELECT * FROM t", "WITH t (\u00e9, b, c, d, e, f) AS #{body} SELECT * FROM t",
          "WITH t(a,b,c,d,e,f)AS(SELECT*FROM rac_my_accounts)SELECT*FROM t", "WITH t /*!(a, b, c, d, e, f)*/ AS #{body} SELECT * FROM t",
          "WITH t (a, b, c, d, e, f) # note\n AS #{body} SELECT * FROM t", "WITH RECURSIVE t (a, b, c, d, e, f) AS #{body} SELECT * FROM t"
        ], "Blocked: a column-alias list")
        expect(text("SELECT * FROM (VALUES ROW(1, 'a')) AS v (id, name)")).not_to start_with("Blocked: a column-alias list")
      end

      it "refuses a wildcard inside a subquery over a table that holds a secret column" do
        guess = "(1, 'a@example.com', 'pw-valud', 'x', 'y', 'z')"
        refused([
          "SELECT #{guess} < (SELECT * FROM rac_my_accounts) AS o", "SELECT ROW#{guess} < (SELECT DISTINCTROW * FROM rac_my_accounts) AS o",
          "SELECT #{guess} < (SELECT SQL_NO_CACHE rac_my_accounts.* FROM rac_my_accounts) AS o", "SELECT * FROM (SELECT * FROM rac_my_accounts) x",
          "WITH x AS (SELECT * FROM rac_my_accounts) SELECT * FROM x"
        ], "Blocked: a `*` inside a subquery is not run in a statement that names `rac_my_accounts`, which holds the secret column `passwd`. On MySQL")
        refused([ "SELECT #{guess} < (TABLE rac_my_accounts) AS o", "SELECT 1 FROM rac_my_contacts WHERE #{guess} IN (TABLE rac_my_accounts)",
                  "SELECT * FROM (TABLE rac_my_accounts) x" ],
                "Blocked: `TABLE` inside a subquery is not run in a statement that names `rac_my_accounts`, which holds the secret column `passwd`.")
        expect(text("SELECT c.email FROM (SELECT * FROM rac_my_contacts) c WHERE c.email <> 'rac_my_accounts'")).to include("a@example.com")
      end

      it "reads the words for connection and a mysql host name inside a literal as data" do
        expect(text("SELECT email FROM rac_my_accounts WHERE email <> 'waiting for connection' AND email NOT LIKE '%@mysql.com'")).to include("a@example.com")
        expect(text("SELECT EXISTS (SELECT * FROM rac_my_accounts) AS found, (SELECT count(*) FROM rac_my_accounts) AS n")).to include("| 1     | 1 |")
      end

      it "filters both columns of a name a join returns twice, and has no derived table of duplicate names" do
        twice = text("SELECT * FROM rac_my_accounts a JOIN rac_my_accounts b ON 1 = 1")
        expect(twice).to include("a@example.com")
        expect(twice).not_to include("pw-value")
        conn.execute("CREATE TABLE rac_my_plain (id int, note varchar(10))")
        expect(text("SELECT * FROM (SELECT * FROM rac_my_plain a JOIN rac_my_plain b ON 1 = 1) x")).to start_with("SQL error:").and include("Duplicate column name")
      ensure
        conn.execute("DROP TABLE IF EXISTS rac_my_plain")
      end

      it "refuses a secret column named with a letter the server folds to a plain one" do
        conn.execute("ALTER TABLE rac_my_accounts ADD COLUMN api_key varchar(20)")
        conn.execute("UPDATE rac_my_accounts SET api_key = 'key-value'")
        [ "SELECT ap\u0130_key AS x FROM rac_my_accounts", "SELECT api_\u212Aey AS x FROM rac_my_accounts" ].each do |sql|
          # MariaDB folds neither letter, so there the statement names no column at all.
          expect(conn.select_value(sql)).to eq("key-value") unless conn.mariadb?
          expect(text(sql)).to start_with("Blocked: query references secret column `api_key`")
        end
      end

      it "refuses a WHERE clause on SHOW and sends nothing, and runs SHOW with a LIKE" do
        RailsAiContext.configuration.query_timeout = 1
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        refused([ "SHOW TABLES WHERE SLEEP(4) = 0", "SHOW COLUMNS FROM rac_my_accounts WHERE SLEEP(4) = 0", "SHOW STATUS WHERE SLEEP(4) = 0" ],
                "Blocked: SHOW with a WHERE clause is not run")
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
        expect(text("SHOW TABLES LIKE 'rac_my_acc%'")).to include("rac_my_accounts")
        expect(text("SHOW COLUMNS FROM rac_my_accounts LIKE 'ema%'")).to include("email")
      end

      it "refuses other sessions' statements, replication state and the stored password hashes" do
        other = conn.select_value("SELECT CONNECTION_ID()").to_i
        refused([ "SHOW FULL PROCESSLIST", "SHOW REPLICA STATUS", "SHOW ENGINE INNODB STATUS", "SHOW BINARY LOGS" ], "Blocked: sensitive SHOW command")
        refused([ "EXPLAIN FOR CONNECTION #{other}", "EXPLAIN FORMAT=JSON FOR CONNECTION #{other}", "DESCRIBE FOR CONNECTION #{other}" ],
                "Blocked: EXPLAIN FOR CONNECTION is not run.")
        refused([ "SELECT * FROM information_schema.processlist", "SELECT * FROM performance_schema.threads",
                  "SELECT * FROM information_schema.PROCESSL\u0130ST", "SELECT trx_query AS q FROM information_schema.innodb_trx",
                  "SELECT * FROM information_schema.INNODB_FT_INDEX_CACHE", "SELECT * FROM information_schema.profiling" ], "Blocked: `")
        refused([ "SELECT authentication_string AS a FROM mysql.user LIMIT 1", "SELECT User, Host FROM `mysql`.`user`", "SELECT * FROM mysql.servers",
                  "SELECT * FROM mysql . db" ], "Blocked: `mysql` is not read.")
        expect(text("SELECT authentication_string AS a FROM rac_my_accounts")).to start_with("Blocked: query references secret column")
        expect(text("SELECT table_name FROM information_schema.tables WHERE table_schema = 'mysql' LIMIT 1")).not_to start_with("Blocked")
      end

      it "refuses a function called by a quoted name" do
        refused([ "SELECT `get_lock`('rac_my', 0) AS l", "SELECT `release_all_locks`() AS r", "SELECT `sleep` (0) AS s" ],
                "Blocked: a quoted name is followed by a parenthesis")
        expect(conn.select_value("SELECT IS_USED_LOCK('rac_my')")).to be_nil
        expect(text("SELECT count(`id`) AS n FROM `rac_my_accounts` WHERE `id` IN (1, 2)")).to include("| 1 |")
      end

      it "runs a view that names no secret column, and shows a refused view's definition" do
        expect(text("SELECT * FROM rac_my_contacts")).to include("a@example.com", "A@EXAMPLE.COM")
        expect(text("SHOW CREATE VIEW rac_my_renamed")).to include("rac_my_accounts")
      end

      it "filters a generated column that reads a secret column, and refuses a statement naming it" do
        everything = text("SELECT * FROM rac_my_accounts")
        expect(everything).to include("a@example.com", "A@EXAMPLE.COM", "[FILTERED]")
        expect(everything).not_to include("pw-value")
        expect(text("SELECT shadow AS s FROM rac_my_accounts")).to include("`shadow` is a generated column that reads `passwd`")
        expect(text("SELECT kept AS k FROM rac_my_accounts")).to include("`kept` is a generated column that reads `shadow`")
      end

      it "releases a view and a generated column over a column the app allows" do
        RailsAiContext.configuration.query_allowed_columns = %w[passwd shadow]
        expect(text("SELECT * FROM rac_my_renamed")).to include("pw-value")
        expect(text("SELECT shadow FROM rac_my_accounts")).to include("pw-value")
      end

      context "when a model declares the column with encrypts" do
        let(:context) { { models: { "Account" => { encrypts: %w[passwd] } } } }

        it "keeps the view refused and the generated column secret, whatever the app allows" do
          RailsAiContext.configuration.query_allowed_columns = %w[passwd shadow kept]
          expect(answer("SELECT * FROM rac_my_renamed").error?).to be(true)
          expect(answer("SELECT shadow FROM rac_my_accounts").error?).to be(true)
          expect(text("SELECT * FROM rac_my_accounts")).not_to include("pw-value")
        end
      end

      it "refuses a view whose definition the account may not read" do
        allow(runtime).to receive(:view_definitions).and_wrap_original { |original, c| original.call(c).transform_values { "" } }
        expect(text("SELECT * FROM rac_my_contacts")).to include("the view `rac_my_contacts` is not queried: its definition could not be read")
      end

      it "answers a timeout as an error, inside the timeout" do
        RailsAiContext.configuration.query_timeout = 0.5
        response = nil
        took = seconds { response = answer("SELECT id FROM rac_my_accounts WHERE SLEEP(2) = 0") }

        expect(took).to be < 2
        expect(response.error?).to be(true)
        expect(response.content.first[:text]).to start_with("Query exceeded 0.5 second timeout")
      end

      it "answers the timeout inside twice query_timeout while another session holds the table, for a query and its EXPLAIN" do
        RailsAiContext.configuration.query_timeout = 1
        limits = "SELECT @@SESSION.lock_wait_timeout, @@SESSION.#{conn.mariadb? ? "max_statement_time" : "max_execution_time"}"
        before = conn.select_rows(limits)

        second_session(ENV.fetch(env)) do |locker|
          locker.execute("LOCK TABLES rac_my_accounts WRITE")

          [ false, true ].each do |explain|
            response = nil
            took = seconds { response = answer("SELECT id FROM rac_my_accounts", explain: explain) }

            expect(response.error?).to be(true), "explain: #{explain}"
            expect(response.content.first[:text]).to start_with("Query exceeded 1 second timeout")
            expect(took).to be_between(0.9, 2.5)
          end
        end
        expect(conn.select_rows(limits)).to eq(before)
      end

      it "names a database at a port nothing listens on, and says to start its server" do
        uri = URI(ENV.fetch(env))
        uri.port = 1
        configurations = ActiveRecord::DatabaseConfigurations.new(
          Rails.env => { "primary" => ActiveRecord::Base.connection_db_config.configuration_hash,
                         "closed" => { "url" => "#{uri}?connect_timeout=2" } }
        )
        allow(ActiveRecord::Base).to receive(:configurations).and_return(configurations)
        response = nil
        took = seconds { response = answer("SELECT 1", database: "closed") }

        expect(took).to be < 4
        expect(response.error?).to be(true)
        expect(response.content.first[:text]).to start_with("The closed database cannot be reached: ")
          .and end_with("Start its server, or fix its settings in config/database.yml.")
      end

      it "explains a statement, leaving a row with no table out of the summary" do
        expect(text("SELECT id FROM rac_my_accounts", explain: true)).to include("- **rac_my_accounts**: full table scan")
        plain = text("SELECT 1 AS one", explain: true)
        expect(plain).to include("## Raw Plan")
        expect(plain).not_to include("Scan Summary")
      end

      it "flags a failing EXPLAIN and a failing statement as errors" do
        expect(answer("SELECT nope FROM rac_my_accounts", explain: true).error?).to be(true)
        expect(text("SELECT nope FROM rac_my_accounts")).to start_with("SQL error:")
      end
    end
  end
end
