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

      it "keeps refusing a column named like a configured secret one but for case past ASCII, and filters it" do
        RailsAiContext.configuration.query_redacted_columns += [ "\u00c9" ]
        conn.execute("DROP TABLE IF EXISTS rac_my_accents")
        conn.execute("CREATE TABLE rac_my_accents (id int, `\u00e9` varchar(20))")
        conn.execute("INSERT INTO rac_my_accents VALUES (1, 'lower-secret')")

        [ "SELECT `\u00e9` FROM rac_my_accents", "SELECT `\u00c9` FROM rac_my_accents", "SELECT \u00c9 AS x FROM rac_my_accents" ].each do |sql|
          expect(text(sql)).to start_with("Blocked: query references secret column"), sql
        end
        expect(text("SELECT * FROM rac_my_accents")).to include("[FILTERED]").and(satisfy { |t| !t.include?("lower-secret") })
      ensure
        RailsAiContext.configuration.query_redacted_columns -= [ "\u00c9" ]
        conn.execute("DROP TABLE IF EXISTS rac_my_accents")
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
            expect([ response.error?, response.content.first[:text] ]).to match([ true, start.is_a?(Regexp) ? start : a_string_starting_with(start) ]), sql
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

        it "refuses it the same when a string in the statement holds a quote character" do
          from = "FROM rac_my_other.acc"
          refused([ %(SELECT '"' AS q, session_token AS x #{from} WHERE '"' = '"'), "SELECT '`' AS q, session_token AS x FROM `rac_my_other`.`acc`",
                    "SELECT 'a`b' AS q, session_token AS x FROM `rac_my_other`.acc", "SELECT '[' AS q, session_token AS x #{from} WHERE ']' = ']'",
                    %(SELECT session_token AS x #{from} WHERE '".c' <> 'x' AND '"' = '"') ],
                  "Blocked: query references secret column `session_token`")
          refused([ %(SELECT '"' AS q, v.* FROM rac_my_other.v v WHERE '"' = '"'), "SELECT '`' AS q, p FROM `rac_my_other`.`v`",
                    "SELECT '[' AS q, upper(p) AS u FROM rac_my_other.v WHERE ']' = ']'" ],
                  "Blocked: the view `v` is not queried: its definition names the secret column `passwd`")
          refused([ %(SELECT '"' AS q, f FROM rac_my_other.chain WHERE '"' = '"') ],
                  "Blocked: the view `chain` is not queried: its definition names the secret column `far_token`")
        end

        it "refuses a view over it, in either database, and a view that leads to a third database" do
          refused([ "SELECT * FROM rac_my_across", "SELECT t FROM rac_my_across" ],
                  "Blocked: the view `rac_my_across` is not queried: its definition names the secret column `session_token`")
          refused([ "SELECT * FROM rac_my_other.v", "SELECT upper(p) AS u FROM rac_my_other.v" ],
                  "Blocked: the view `v` is not queried: its definition names the secret column `passwd`")
          refused([ "SELECT * FROM rac_my_other.chain" ], "Blocked: the view `chain` is not queried: its definition names the secret column `far_token`")
        end

        it "refuses a view over it whatever the view's name holds: two spaces in a row, one, a tab, a newline, a backtick, capitals" do
          views = [ "rac my  far", "rac my far", "rac my\tfar", "rac my\nfar", "rac my`far", "Rac_My_FAR" ]
          names = views.map { |name| "`#{name.gsub("`", "``")}`" }
          names.each { |name| conn.execute("CREATE VIEW #{name} AS SELECT id, session_token AS t FROM rac_my_other.acc") }
          names.zip(views) do |name, view|
            # Two names that differ by a run of spaces alone are one name to the rule, which names the first it read.
            shown = views.select { |other| other.squeeze(" ") == view.squeeze(" ") }
            refused([ "SELECT * FROM #{name}", "SELECT t FROM #{name}", "SELECT f.t FROM #{name} f" ], /\ABlocked: the view `#{Regexp.union(shown)}` is not queried/)
          end
        ensure
          names.each { |name| conn.execute("DROP VIEW IF EXISTS #{name}") }
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
          ActiveSupport::Notifications.subscribed(->(*, payload) { sent << payload[:sql] }, "sql.active_record") do
            answer("SELECT o.id FROM rac_my_other.acc o JOIN information_schema.TABLES t ON t.TABLE_NAME = 'acc'")
          end

          expect(sent.grep(/SCHEMATA/).size).to eq(1)
          expect(sent.grep(/TABLE_SCHEMA IN \('rac_my_other'\)/).size).to eq(3)
          expect(sent.grep(/TABLE_SCHEMA IN \('rac_my_third'\)/)).to be_empty
          expect(sent.grep(/TABLE_SCHEMA IN \('information_schema'\)/)).to be_empty
        end

        it "reads a third database when the statement names the view that leads there" do
          sent = []
          ActiveSupport::Notifications.subscribed(->(*, payload) { sent << payload[:sql] }, "sql.active_record") { answer("SELECT f FROM rac_my_other.chain") }

          expect(sent.grep(/TABLE_SCHEMA IN \('rac_my_third'\)/).size).to eq(3)
        end
      end

      describe "views that lead through other databases" do
        let(:databases) { %w[rac_my_c1 rac_my_c2 rac_my_c3 rac_my_c4 rac_my_twin] }

        def drop_chain
          %w[rac_my_far rac_my_near rac_my_peek].each { |view| conn.execute("DROP VIEW IF EXISTS #{view}") }
          conn.execute("DROP TABLE IF EXISTS rac_my_notes")
          databases.each { |name| conn.execute("DROP DATABASE IF EXISTS #{name}") }
        end

        before do
          drop_chain
          databases.each { |name| conn.execute("CREATE DATABASE #{name}") }
          conn.execute("CREATE TABLE rac_my_c4.t (id int, door_token varchar(50))")
          conn.execute("INSERT INTO rac_my_c4.t VALUES (1, 'door-value')")
          conn.execute("CREATE VIEW rac_my_c3.v AS SELECT id, door_token AS x FROM rac_my_c4.t")
          conn.execute("CREATE VIEW rac_my_c2.v AS SELECT id, x FROM rac_my_c3.v")
          conn.execute("CREATE VIEW rac_my_c1.v AS SELECT id, x FROM rac_my_c2.v")
          conn.execute("CREATE VIEW rac_my_far AS SELECT id, x FROM rac_my_c1.v")
          conn.execute("CREATE VIEW rac_my_near AS SELECT id, x FROM rac_my_c2.v")
          conn.execute("CREATE TABLE rac_my_notes (id int, body varchar(50))")
          conn.execute("INSERT INTO rac_my_notes VALUES (1, 'public note')")
          conn.execute("CREATE TABLE rac_my_twin.rac_my_notes (id int, body varchar(50), api_token varchar(50))")
          conn.execute("INSERT INTO rac_my_twin.rac_my_notes VALUES (1, 'other note', 'door-value')")
          conn.execute("CREATE VIEW rac_my_peek AS SELECT id, body FROM rac_my_twin.rac_my_notes")
        end

        after { drop_chain }

        def sent
          statements = []
          subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
          yield
          statements
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        def refused(statements, start)
          statements.each do |sql|
            response = answer(sql)
            expect([ response.error?, response.content.first[:text] ]).to match([ true, a_string_starting_with(start) ]), sql
            expect(response.content.first[:text]).not_to include("door-value"), sql
          end
        end

        it "runs a statement that names none of them, after the reads of its own database alone" do
          [ "SELECT 1 AS one", "SELECT a.id, a.email FROM rac_my_accounts a WHERE a.id = 1" ].each do |sql|
            response = nil
            statements = sent { response = answer(sql) }
            expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("| 1 ") ]), sql
            expect(statements.grep(/rac_my_c\d|rac_my_twin/)).to be_empty, sql
          end
          expect(sent { answer("SELECT id, email FROM rac_my_accounts WHERE id = 1") }.size).to eq(17)
        end

        it "refuses a statement that names a view four databases from the rows, by the view" do
          refused([ "SELECT * FROM rac_my_far", "SELECT x FROM rac_my_far", "SELECT f.id FROM rac_my_accounts a JOIN rac_my_far f ON f.id = a.id" ],
                  "The view `rac_my_far` leads through more databases than rails_query follows, so the secret columns it could " \
                  "read cannot be told and no statement that names it runs.")
          refused([ "SELECT * FROM rac_my_c1.v" ], "The view `v` leads through more databases than rails_query follows, so the")
        end

        it "follows a view three databases from the rows, and refuses it for the secret column it renames" do
          refused([ "SELECT * FROM rac_my_near", "SELECT upper(x) FROM rac_my_near" ],
                  "Blocked: the view `rac_my_near` is not queried: it reads the view `v`: its definition names the secret column `door_token`.")
        end

        it "runs a wildcard subquery over its own table, and refuses it when the statement names the database of a table of that name" do
          [ "SELECT * FROM (SELECT * FROM rac_my_notes) s", "WITH c AS (SELECT * FROM rac_my_notes) SELECT * FROM c" ].each do |sql|
            response = answer(sql)
            expect([ response.error?, response.content.first[:text] ]).to match([ false, a_string_including("public note") ]), sql
          end
          refused([ "SELECT * FROM (SELECT * FROM rac_my_notes) s WHERE EXISTS (SELECT 1 FROM rac_my_twin.rac_my_notes)" ],
                  "Blocked: a `*` inside a subquery is not run in a statement that names `rac_my_notes`, which holds the secret column `api_token`.")
          peeked = answer("SELECT * FROM rac_my_peek")
          expect([ peeked.error?, peeked.content.first[:text] ]).to match([ false, a_string_including("other note") ])
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

      it "refuses what either reading of a backslash refuses, whether or not the session's sql_mode holds NO_BACKSLASH_ESCAPES" do
        default = conn.select_value("SELECT @@SESSION.sql_mode")
        guess = "(1, 'a@example.com', 'pw-valud', 'x', 'y', 'z')"
        # mysql2 cannot quote a string once the session is in this mode, so on it no call gets as far as the checks.
        modes = [ default, ("#{default},NO_BACKSLASH_ESCAPES" unless conn.adapter_name == "Mysql2") ].compact
        modes.each do |mode|
          conn.execute("SET SESSION sql_mode = '#{mode}'")
          { %q(SELECT '\' , user, host, plugin FROM mysql.user -- ') => "Blocked: `mysql` is not read.",
            %q(SELECT '\' , db, user FROM mysql.db -- ') => "Blocked: `mysql` is not read.",
            %q(SELECT '\' , thd_id, conn_id FROM sys.session -- ') => "Blocked: `sys` is not read.",
            %q(SELECT '\' , thread_id FROM performance_schema.threads -- ') => "Blocked: `performance_schema` is not read.",
            %(SELECT '\\' , #{guess} < (SELECT * FROM rac_my_accounts) AS o -- ') => "Blocked: a `*` inside a subquery" }.each do |sql, start|
            response = answer(sql)
            expect([ response.error?, response.content.first[:text] ]).to match([ true, a_string_starting_with(start) ]), "#{mode}: #{sql}"
          end
          expect(text("SELECT email FROM rac_my_accounts WHERE email NOT LIKE '%@mysql.com'")).to include("a@example.com"), mode
        end
        conn.execute("SET SESSION sql_mode = '#{default}'")
        expect(text(%q(SELECT 'it\'s' AS v, email FROM rac_my_accounts))).to include("it's", "a@example.com")
        expect(text(%q(SELECT 'a\\\\b' AS v))).to include("a\\b")
      ensure
        conn.execute("SET SESSION sql_mode = '#{default}'") if default
      end

      it "refuses the server's own schema after a comment that holds a backslash and a quote, under NO_BACKSLASH_ESCAPES" do
        skip "mysql2 cannot quote a string once the session is in this mode" if conn.adapter_name == "Mysql2"
        default = conn.select_value("SELECT @@SESSION.sql_mode")
        conn.execute("SET SESSION sql_mode = '#{default},NO_BACKSLASH_ESCAPES'")
        response = answer(%q(SELECT '\' /* \' */ , user, host FROM mysql.user -- '))
        expect([ response.error?, response.content.first[:text] ]).to match([ true, a_string_starting_with("Blocked: `mysql` is not read.") ])
      ensure
        conn.execute("SET SESSION sql_mode = '#{default}'") if default
      end

      it "refuses a square bracket when the session's sql_mode holds MSSQL, where it quotes a name", if: server == "MariaDB" do
        default = conn.select_value("SELECT @@SESSION.sql_mode")
        conn.execute("SET SESSION sql_mode = 'MSSQL'")
        [ "SELECT [User], [Host] FROM [mysql].[user]", "SELECT 1 AS ['], passwd AS x FROM rac_my_accounts -- ']",
          "SELECT 1 AS ['], User, Host FROM mysql.user -- ']", "SELECT [passwd] AS x FROM [rac_my_accounts]", "SELECT [p1] FROM [rac_my_renamed]" ].each do |sql|
          response = answer(sql)
          expect([ response.error?, response.content.first[:text] ]).to match([ true, a_string_starting_with("Blocked: a `[` outside a string") ]), sql
        end
        expect(text("SELECT email FROM rac_my_accounts WHERE email <> '[x]'")).to include("a@example.com")
      ensure
        conn.execute("SET SESSION sql_mode = '#{default}'") if default
      end

      it "leaves no user variable and no LAST_INSERT_ID value on the app's connection" do
        expect(answer("SELECT @rac_my_v := 5 AS v").error?).to be(true)
        expect(answer("SELECT LAST_INSERT_ID(7) AS v").error?).to be(true)

        expect(conn.select_rows("SELECT @rac_my_v, LAST_INSERT_ID()").first.map(&:to_s)).to eq([ "", "0" ])
        expect(text("SELECT LAST_INSERT_ID() AS v")).to include("| 0 |")
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
        took = seconds do
          refused([ "SHOW TABLES WHERE SLEEP(4) = 0", "SHOW COLUMNS FROM rac_my_accounts WHERE SLEEP(4) = 0", "SHOW STATUS WHERE SLEEP(4) = 0" ],
                  "Blocked: SHOW with a WHERE clause is not run")
        end
        expect(took).to be < 2
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

      it "says the statement limit and lock_wait_timeout it shows are its own, and gives the session's" do
        RailsAiContext.configuration.query_timeout = 2
        limit, own = conn.mariadb? ? [ "max_statement_time", "50.0" ] : [ "max_execution_time", "50000" ]
        conn.execute("SET SESSION #{limit} = #{conn.mariadb? ? 50 : 50_000}, lock_wait_timeout = 600")
        note = "#{limit} and lock_wait_timeout here are the values rails_query sets for each statement it runs. " \
          "The session's own: #{limit} #{own}, lock_wait_timeout 600."

        expect(text("SELECT @@#{limit} AS l, @@lock_wait_timeout AS w")).to include(note)
        expect(text("SHOW VARIABLES LIKE '%wait_timeout'")).to match(/\| lock_wait_timeout +\| 2 /).and include("lock_wait_timeout here is the value")
        expect(text("SHOW VARIABLES LIKE 'version'")).not_to include("rails_query sets")
        expect(text("SELECT 1 AS lock_wait_timeout")).not_to include("rails_query sets")
        expect(text("SELECT @@GLOBAL.lock_wait_timeout AS w")).not_to include("rails_query sets")
        expect(text("SELECT '@@lock_wait_timeout' AS w")).not_to include("rails_query sets")
        expect(text("SELECT @@LOCAL.lock_wait_timeout AS w")).to include("rails_query sets")
        expect(text("SELECT @@`lock_wait_timeout` AS w")).to include("rails_query sets")
        expect(text("SELECT @@SESSION.`lock_wait_timeout` AS w")).to include("rails_query sets")
        expect(text("SELECT @@session . lock_wait_timeout AS w")).to include("rails_query sets")
        expect(text("SHOW SESSION VARIABLES LIKE 'lock_wait_timeout'")).to include("rails_query sets")
        expect(text("SHOW GLOBAL VARIABLES LIKE 'lock_wait_timeout'")).not_to include("rails_query sets")
        if conn.mariadb?
          read = "SELECT VARIABLE_VALUE FROM information_schema.%s WHERE VARIABLE_NAME = 'LOCK_WAIT_TIMEOUT'"
          expect(text(format(read, "SESSION_VARIABLES"))).to include("lock_wait_timeout here is the value")
          expect(text(format(read, "`SESSION_VARIABLES`"))).to include("lock_wait_timeout here is the value")
          expect(text(format(read, "GLOBAL_VARIABLES"))).not_to include("rails_query sets")
        end
      ensure
        conn.execute("SET SESSION #{limit} = 0, lock_wait_timeout = 31536000")
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
