# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::SqlGate do
  let(:families) do
    { sqlite: RailsAiContext::DatabaseFamily::SQLITE, mysql: RailsAiContext::DatabaseFamily::MYSQL,
      postgresql: RailsAiContext::DatabaseFamily::POSTGRESQL }
  end
  let(:relations) { {} }
  let(:views) { nil }
  let(:generated) { {} }
  let(:encrypted) { [] }
  let(:connection) { double("connection", quote: nil, select_values: []) }
  let(:plan) { { "Node Type" => "Result" } }

  around do |example|
    config = RailsAiContext.configuration
    redacted = config.query_redacted_columns
    allowed = config.query_allowed_columns
    config.query_redacted_columns = RailsAiContext::SecretColumns::DEFAULT_REDACTED_COLUMNS.dup
    config.query_allowed_columns = []
    example.run
  ensure
    config.query_redacted_columns = redacted
    config.query_allowed_columns = allowed
  end

  before do
    allow(connection).to receive(:quote) { |name| "'#{name}'" }
    allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:plan) { plan }
    allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:bounded) { |_connection, _timeout, &reads| reads.call }
  end

  def check(sql, family = :sqlite)
    secrets = RailsAiContext::SecretColumns.new(relations: relations, views: views, generated: generated, encrypted: encrypted)
    # The text checks get minutes: these examples read verdicts, and a megabyte takes seconds on a loaded machine.
    described_class.new(family: families.fetch(family), secrets: secrets, connection: connection, budget: described_class::Budget.new(5),
                        text_timeout: 600).check(sql)
  end

  def refusal(sql, family = :sqlite)
    check(sql, family).refusal
  end

  def runs?(sql, family = :sqlite)
    !check(sql, family).refused?
  end

  describe "a statement it runs" do
    it "answers the text to run" do
      verdict = check("SELECT 1 AS test")
      expect(verdict.refused?).to be(false)
      expect(verdict.sql).to eq("SELECT 1 AS test")
      expect(verdict).to be_frozen
    end

    it "runs a CTE, EXPLAIN, DESCRIBE, INTERSECT and EXCEPT" do
      [
        "WITH active AS (SELECT * FROM users WHERE active = 1) SELECT * FROM active",
        "EXPLAIN SELECT * FROM users", "DESCRIBE users",
        "SELECT id FROM posts INTERSECT SELECT id FROM posts", "SELECT id FROM posts EXCEPT SELECT id FROM posts",
        "SELECT * FROM users WHERE active = true OR admin = true"
      ].each { |sql| expect(runs?(sql)).to be(true), sql }
    end
  end

  describe "refusals" do
    it "refuses no statement at all" do
      expect(refusal(nil)).to include("required")
      expect(refusal("  ")).to include("required")
    end

    %w[INSERT UPDATE DELETE DROP ALTER TRUNCATE CREATE GRANT].each do |keyword|
      it "refuses #{keyword}" do
        sql = {
          "INSERT" => "INSERT INTO users (email) VALUES ('x')", "UPDATE" => "UPDATE users SET email = 'x'",
          "DELETE" => "DELETE FROM users", "DROP" => "DROP TABLE users", "ALTER" => "ALTER TABLE users ADD COLUMN age INTEGER",
          "TRUNCATE" => "TRUNCATE users", "CREATE" => "CREATE TABLE evil (id INTEGER)", "GRANT" => "GRANT ALL ON users TO evil"
        }.fetch(keyword)
        expect(refusal(sql)).to include("Blocked").and include(keyword)
      end
    end

    it "refuses a statement over the length it checks, and checks one just under it" do
      long = "SELECT id FROM posts WHERE body = '#{"x" * described_class::MAX_BYTES}'"
      %i[sqlite mysql postgresql].each do |family|
        expect(refusal(long, family)).to eq("Blocked: the statement is #{long.bytesize} bytes long, and rails_query checks a statement of 1000000 bytes at most.")
      end
      expect(runs?("SELECT id FROM posts WHERE id IN (#{(1..142_000).to_a.join(",")})")).to be(true)
    end

    it "reads a run of opening brackets and a nest of VALUES lists in time that grows with their length" do
      cpu = Process.const_defined?(:CLOCK_PROCESS_CPUTIME_ID) ? Process::CLOCK_PROCESS_CPUTIME_ID : Process::CLOCK_MONOTONIC
      nest = 200_000 / 23
      [ "SELECT 1 AS v, #{"[" * 200_000}", "SELECT * FROM #{"(VALUES (" * nest}1#{")) AS t(a)" * nest}" ].each do |sql|
        families.each do |key, family|
          gate = described_class.new(family: family, secrets: RailsAiContext::SecretColumns.new, connection: connection,
                                     budget: described_class::Budget.new(5), text_timeout: 600)
          started = Process.clock_gettime(cpu)
          gate.check(sql)
          # Quadratic, either shape took minutes at this length.
          expect(Process.clock_gettime(cpu) - started).to be < 20, "#{key}: #{sql[0, 30]}"
        end
      end
    end

    it "gives up with a refusal of its own when the text checks run past the time they have" do
      gate = described_class.new(family: families.fetch(:sqlite), secrets: RailsAiContext::SecretColumns.new, connection: connection,
                                 budget: described_class::Budget.new(5), text_timeout: 0.01)
      expect(gate.check("SELECT #{"(" * 450_000}1#{")" * 450_000} AS v").refusal).to eq(
        "Blocked: the checks on the statement's text ran longer than query_timeout (0.01 seconds), so the statement was not run. " \
        "Send a shorter statement."
      )
      expect(gate.check("SELECT 1 AS v").refused?).to be(false)
    end

    it "refuses a statement that starts with anything but a read" do
      expect(refusal("VACUUM users")).to include("Only SELECT, WITH, SHOW, EXPLAIN, DESCRIBE allowed")
    end

    it "refuses a second statement, also one after a literal holding a comment marker or a hash" do
      [ "SELECT 1; DROP TABLE users", "SELECT '--' AS m; SELECT 2 AS hidden", "SELECT '#'; DROP TABLE users",
        "SELECT $$a$$ AS v; DROP TABLE users" ].each do |sql|
        expect(refusal(sql)).to include("multiple statements"), sql
      end
    end

    it "refuses a second statement between two dollar signs off PostgreSQL, where a dollar quotes nothing" do
      sql = "SELECT $a$; DROP TABLE users; SELECT $a$"
      %i[sqlite mysql].each { |family| expect(refusal(sql, family)).to include("multiple statements"), family.to_s }
    end

    it "refuses a DO block as a statement it does not run" do
      expect(refusal("DO $$ BEGIN PERFORM 1; END $$", :postgresql)).to include("Only SELECT")
    end

    it "refuses SELECT INTO and a disk write" do
      expect(refusal("SELECT * INTO new_table FROM users")).to include("SELECT INTO creates a table")
      expect(refusal("SELECT 1 INTO OUTFILE '/tmp/leak.txt'")).to eq("Blocked: SELECT INTO OUTFILE / DUMPFILE writes to disk")
      expect(refusal("SELECT id FROM orders INTO OUTFILE '/tmp/x'", :mysql)).to include("OUTFILE")
    end

    it "refuses a sensitive SHOW and every SHOW CREATE but a table or view" do
      expect(refusal("SHOW GRANTS FOR 'root'", :mysql)).to include("sensitive SHOW command")
      expect(refusal("SHOW CREATE USER 'rt'@'%'", :mysql)).to include("CREATE")
      expect(refusal("SHOW CREATE DATABASE app", :mysql)).to include("CREATE")
      expect(runs?("SHOW CREATE TABLE orders", :mysql)).to be(true)
      expect(runs?("SHOW CREATE VIEW order_totals", :mysql)).to be(true)
    end

    it "refuses every SHOW that tells of other sessions, replication or a log" do
      [ "SHOW PROCESSLIST", "SHOW FULL PROCESSLIST", "show  full\nprocesslist", "SHOW REPLICA STATUS", "SHOW REPLICAS", "SHOW SLAVE STATUS",
        "SHOW SLAVE HOSTS", "SHOW ALL SLAVES STATUS", "SHOW ALL REPLICAS STATUS", "SHOW MASTER STATUS", "SHOW BINARY LOGS",
        "SHOW BINARY LOG STATUS", "SHOW BINLOG EVENTS", "SHOW BINLOG STATUS", "SHOW RELAYLOG EVENTS", "SHOW ENGINE INNODB STATUS",
        "SHOW PROFILE", "SHOW PROFILES", "SHOW OPEN TABLES", "SHOW EXPLAIN FOR 12", "SHOW ANALYZE FOR 12", "SHOW USER_STATISTICS",
        "SHOW CLIENT_STATISTICS", "SHOW WSREP_STATUS" ].each do |sql|
        expect(refusal(sql, :mysql)).to eq("Blocked: sensitive SHOW command"), sql
      end
    end

    it "refuses another session's plan in every spelling MySQL and MariaDB read" do
      [ "EXPLAIN FOR CONNECTION 12", "EXPLAIN FORMAT=JSON FOR CONNECTION 12", "DESCRIBE FOR CONNECTION 12", "DESC FORMAT=TREE FOR CONNECTION 12",
        "explain for\nconnection 12", "EXPLAIN /*!50000 FOR CONNECTION */ 12", "EXPLAIN FOR /* x */ CONNECTION 12" ].each do |sql|
        expect(refusal(sql, :mysql))
          .to eq("Blocked: EXPLAIN FOR CONNECTION is not run. It shows the plan of the statement another session is running."), sql
      end
      expect(runs?("EXPLAIN SELECT id FROM orders", :mysql)).to be(true)
    end

    it "reads the words for connection as data in a literal and in any statement that is no EXPLAIN" do
      [ "SELECT id FROM notes WHERE body = 'waiting for connection'", "SELECT id AS for_connection FROM notes",
        "EXPLAIN SELECT id FROM notes WHERE body = 'for connection'" ].each do |sql|
        %i[sqlite mysql postgresql].each { |family| expect(runs?(sql, family)).to be(true), "#{family}: #{sql}" }
      end
    end

    it "refuses each list's names on the family that has them, and reads them as plain names on the others" do
      { "SELECT * FROM pg_stats" => :postgresql, "SELECT * FROM pg_authid" => :postgresql, "SELECT table_to_xml('users', true, false, '')" => :postgresql,
        "SELECT pg_read_file('notes.txt')" => :postgresql, "SELECT pg_notify('a', 'b')" => :postgresql,
        "SELECT name FROM jobs WHERE archive_command = 'x'" => :postgresql, "SELECT current_setting(name) FROM names" => :postgresql,
        "SELECT * FROM slow_log" => :mysql, "SELECT load_file('notes.txt')" => :mysql, "SELECT get_lock('a', 1)" => :mysql, "SHOW PROCESSLIST" => :mysql,
        "SELECT sys.id FROM systems sys" => :mysql, "SELECT * FROM sqlite_stat1" => :sqlite, "SELECT load_extension('x')" => :sqlite }.each do |sql, owner|
        %i[sqlite mysql postgresql].each do |family|
          expect(check(sql, family).refused?).to be(family == owner), "#{family}: #{sql}"
        end
      end
    end

    it "runs the SHOW statements that list the schema" do
      [ "SHOW TABLES", "SHOW FULL TABLES", "SHOW FULL COLUMNS FROM orders", "SHOW ENGINES", "SHOW TABLES LIKE 'ord%'",
        "SHOW COLUMNS FROM orders LIKE '%where%'", "SHOW INDEX FROM orders", "SHOW TABLE STATUS", "SHOW ALL" ].each do |sql|
        expect(runs?(sql, :mysql)).to be(true), sql
      end
    end

    it "refuses a WHERE clause on SHOW and names the listing to SELECT from" do
      [ "SHOW TABLES WHERE SLEEP(4) = 0", "SHOW FULL TABLES FROM app WHERE 1 = 1", "show columns from orders\nwhere Field = 'id'",
        "SHOW STATUS WHERE Variable_name = 'Uptime'", "SHOW TABLES /* x */ WHERE 1" ].each do |sql|
        %i[mysql sqlite postgresql].each do |family|
          expect(refusal(sql, family)).to start_with("Blocked: SHOW with a WHERE clause is not run")
            .and(include("SHOW ... LIKE runs", "SELECT table_name FROM information_schema.tables")), "#{family}: #{sql}"
        end
      end
    end

    it "refuses a function that returns a whole table as one value" do
      %w[table_to_xml query_to_xml schema_to_xml database_to_xml cursor_to_xml table_to_xmlschema query_to_xml_and_xmlschema].each do |fn|
        expect(refusal("SELECT #{fn}('users', true, false, '')", :postgresql))
          .to eq("Blocked: function #{fn} returns a whole table as one value, secret columns included. " \
                 "SELECT the columns you need from the table itself."), fn
      end
    end

    def unread(name)
      "Blocked: `#{name}` is not read. It holds values sampled from other tables, other sessions' statements " \
        "or stored credentials, and rails_query cannot tell which of them are secret."
    end

    it "refuses a relation that holds sampled values, other sessions' statements or stored credentials" do
      {
        "SELECT histogram_bounds FROM pg_stats WHERE tablename = 'users'" => [ :postgresql, "pg_stats" ],
        "SELECT stavalues1 FROM pg_catalog.pg_statistic" => [ :postgresql, "pg_statistic" ],
        "SELECT query FROM pg_stat_activity" => [ :postgresql, "pg_stat_activity" ],
        "SELECT query FROM pg_stat_statements" => [ :postgresql, "pg_stat_statements" ],
        "SELECT * FROM information_schema.PROCESSLIST" => [ :mysql, "PROCESSLIST" ],
        "SELECT sql_text FROM performance_schema.events_statements_history" => [ :mysql, "performance_schema" ],
        "SELECT histogram FROM information_schema.column_statistics" => [ :mysql, "column_statistics" ],
        "SELECT priv FROM global_priv" => [ :mysql, "global_priv" ],
        "SELECT sample FROM sqlite_stat4" => [ :sqlite, "sqlite_stat4" ],
        "SELECT sql FROM sqlite_stmt" => [ :sqlite, "sqlite_stmt" ]
      }.each { |sql, (family, name)| expect(refusal(sql, family)).to eq(unread(name)), sql }
      expect(runs?("SELECT sys_id, processlists FROM systems sys_log", :mysql)).to be(true)
    end

    it "answers the file that lists the settings as a relation that is not read" do
      expect(refusal("SELECT name, setting FROM pg_file_settings", :postgresql)).to eq("#{unread("pg_file_settings")} To read one setting, run SHOW with its name.")
    end

    it "refuses MySQL's own schemas with string literals read as data, and an alias of either name with the remedy" do
      remedy = ->(name) { "#{unread(name)} A name before a dot is read as that schema, so an alias named `#{name}` needs another name." }
      { "SELECT * FROM `sys`.`session`" => "sys", "SELECT User FROM mysql.user" => "mysql", "SELECT sys.id FROM systems sys" => "sys",
        "SELECT mysql.id FROM engines AS mysql" => "mysql" }.each { |sql, name| expect(refusal(sql, :mysql)).to eq(remedy.call(name)), sql }
      [ "SELECT id FROM users WHERE email LIKE '%@mysql.com'", "SELECT id FROM hosts WHERE name = 'sys.internal'" ].each do |sql|
        %i[sqlite mysql postgresql].each { |family| expect(runs?(sql, family)).to be(true), "#{family}: #{sql}" }
      end
    end

    it "refuses a double-quoted text that holds either schema's name before a dot, and says what a double-quoted text can be" do
      quoted = ->(name) do
        "#{unread(name)} The name stands before a dot inside double-quoted text, which MySQL reads as a name when the session's sql_mode " \
          "holds ANSI_QUOTES, and rails_query does not read the session's mode. Write the text in single quotes."
      end
      expect(refusal(%(SELECT id FROM posts WHERE title LIKE "%@mysql.com"), :mysql)).to eq(quoted.call("mysql"))
      expect(refusal(%(SELECT id FROM hosts WHERE name = "sys.internal"), :mysql)).to eq(quoted.call("sys"))
      expect(refusal(%(SELECT User FROM "mysql".user), :mysql)).to end_with("so an alias named `mysql` needs another name.")
    end

    it "refuses a square bracket outside a string or a quoted name on the MySQL family, where MariaDB's MSSQL mode reads it as a name's quote" do
      bracket = "Blocked: a `[` outside a string or a quoted name is not run. MariaDB reads it as the start of a quoted name when the " \
        "session's sql_mode holds MSSQL, and rails_query does not read the session's mode. Quote a name in backticks."
      [ "SELECT [User] FROM [mysql].[user]", "SELECT 1 AS ['], User, Host FROM mysql.user -- ']", "SELECT id FROM [users]",
        "SELECT 'it''s' AS q, [id] FROM users", "SELECT `a` , [b] FROM users" ].each { |sql| expect(refusal(sql, :mysql)).to eq(bracket), sql }
      [ "SELECT '[' AS q, id FROM users WHERE note <> ']'", "SELECT `a[b` FROM users", %(SELECT id FROM users WHERE note = "[x]") ].each do |sql|
        expect(runs?(sql, :mysql)).to be(true), sql
      end
      expect(runs?("SELECT [id] FROM [users]", :sqlite)).to be(true)
      expect(runs?("SELECT tags[1] FROM posts", :postgresql)).to be(true)
    end

    it "refuses the PostgreSQL relations that hold a stored credential" do
      %w[pg_user_mapping pg_user_mappings pg_subscription pg_authid pg_shadow pg_db_role_setting pg_foreign_server pg_foreign_data_wrapper
         pg_foreign_table pg_hba_file_rules pg_ident_file_mappings].each do |name|
        expect(refusal("SELECT * FROM #{name}", :postgresql)).to eq(unread(name)), name
        expect(refusal("SELECT * FROM pg_catalog.#{name} x", :postgresql)).to eq(unread(name)), name
      end
      expect(refusal("SELECT * FROM information_schema.user_mapping_options", :postgresql)).to eq(unread("user_mapping_options"))
      expect(runs?("SELECT subname FROM pg_subscription_rel_names", :postgresql)).to be(true)
    end

    it "refuses the relations and functions that list every setting, and says how one setting is read" do
      { "SELECT name, setting FROM pg_settings" => "pg_settings", "SELECT * FROM pg_show_all_settings()" => "pg_show_all_settings",
        "SELECT * FROM pg_show_all_file_settings()" => "pg_show_all_file_settings" }.each do |sql, name|
        expect(refusal(sql, :postgresql)).to eq("#{unread(name)} To read one setting, run SHOW with its name."), sql
      end
    end

    it "refuses the mysql schema whole, however its name is quoted" do
      [ "SELECT User, Host FROM mysql.user", "SELECT * FROM `mysql`.`servers`", "SELECT * FROM mysql . slave_master_info",
        "SELECT * FROM mysql/* x */.password_history", 'SELECT * FROM "mysql"."user"', "SELECT * FROM MYSQL.db" ].each do |sql|
        expect(refusal(sql, :mysql)).to start_with("Blocked: `mysql` is not read.").or(start_with("Blocked: `MYSQL` is not read.")), sql
      end
      expect(runs?("SELECT id FROM mysql_versions", :mysql)).to be(true)
    end

    it "refuses the information_schema tables that hold statements, locked rows or indexed words" do
      { "SELECT trx_query FROM information_schema.INNODB_TRX" => "INNODB_TRX", "SELECT * FROM information_schema.innodb_locks" => "innodb_locks",
        "SELECT * FROM information_schema.innodb_lock_waits" => "innodb_lock_waits",
        "SELECT * FROM `information_schema`.`INNODB_FT_INDEX_TABLE`" => "INNODB_FT_INDEX_TABLE",
        "SELECT * FROM information_schema . innodb_ft_index_cache" => "innodb_ft_index_cache",
        "SELECT * FROM information_schema.USER_STATISTICS" => "USER_STATISTICS",
        "SELECT * FROM information_schema.client_statistics" => "client_statistics",
        "SELECT * FROM information_schema.PROFILING" => "PROFILING", "SELECT * FROM information_schema.optimizer_trace" => "optimizer_trace" }.each do |sql, name|
        expect(refusal(sql, :mysql)).to eq(unread(name)), sql
      end
      expect(runs?("SELECT id FROM user_statistics", :mysql)).to be(true)
      expect(runs?("SELECT * FROM information_schema.innodb_metrics", :mysql)).to be(true)
    end

    it "refuses a relation named with a letter the server folds to a plain one" do
      expect(refusal("SELECT * FROM information_schema.PROCESSL\u0130ST", :mysql)).to eq(unread("processlist"))
      expect(refusal("SELECT * FROM information_schema.column_stat\u0130st\u0130cs", :mysql)).to eq(unread("column_statistics"))
    end

    describe "a setting" do
      def secret_setting(name)
        "Blocked: the setting `#{name}` is not read. It can hold a password, a key or a command line that carries one."
      end

      it "refuses the settings that can hold a password or a command line, however they are read" do
        %w[primary_conninfo ssl_passphrase_command archive_command restore_command archive_cleanup_command recovery_end_command].each do |name|
          [ "SHOW #{name}", "show #{name.upcase};", "SELECT current_setting('#{name}')", "SELECT current_setting('#{name}', true) AS v" ].each do |sql|
            expect(refusal(sql, :postgresql)).to match(/\ABlocked: the setting `#{name}` is not read\./i), sql
          end
        end
        expect(refusal("SHOW primary_conninfo", :postgresql)).to eq(secret_setting("primary_conninfo"))
      end

      it "refuses a setting whose own name says it holds a secret" do
        expect(refusal("SHOW app.jwt_secret", :postgresql)).to eq(secret_setting("app.jwt_secret"))
        expect(refusal("SELECT current_setting('app.settings.api_key') AS k", :postgresql)).to eq(secret_setting("app.settings.api_key"))
      end

      it "refuses SHOW ALL and a quoted name on PostgreSQL, and leaves SHOW ALL to MySQL" do
        expect(refusal("SHOW ALL", :postgresql)).to eq(
          "Blocked: SHOW ALL is not run. It lists every setting, the ones that can hold a password among them. SHOW one setting by its name."
        )
        [ %(SHOW "work_mem"), %(SHOW U&"work\\005Fmem"), "SHOW $$x$$" ].each do |sql|
          expect(refusal(sql, :postgresql)).to eq(
            "Blocked: SHOW takes a setting's plain name on PostgreSQL, with no quotes around it, for example `SHOW work_mem`."
          ), sql
        end
        expect(runs?("SHOW ALL", :mysql)).to be(true)
      end

      it "refuses current_setting with a name that is not one plain string" do
        [ "SELECT current_setting('primary' || '_conn' || 'info') AS v", "SELECT current_setting(name) FROM settings_names",
          "SELECT current_setting(E'work_mem')", "SELECT current_setting ( $$work_mem$$ )", "SELECT current_setting('work' '_mem')",
          "SELECT * FROM (VALUES (current_setting(lower('WORK_MEM'))), ('x')) v" ].each do |sql|
          expect(refusal(sql, :postgresql)).to eq(
            "Blocked: current_setting runs only with the setting's name written as one plain string, " \
            "for example `current_setting('work_mem')`, so that rails_query can read which setting it returns."
          ), sql
        end
      end

      it "runs SHOW and current_setting for any other setting" do
        [ "SHOW server_version", "SHOW work_mem;", "SHOW TIME ZONE", "SHOW TRANSACTION ISOLATION LEVEL", "SHOW search_path",
          "SELECT current_setting('work_mem') AS m", "SELECT current_setting( 'server_version_num' , true )::int AS v" ].each do |sql|
          expect(runs?(sql, :postgresql)).to be(true), sql
        end
      end
    end

    it "refuses a quoted name followed by a parenthesis, in every quote a database reads" do
      { postgresql: [ %(SELECT "table_to_xml"('users', true, false, '')), %(SELECT pg_catalog."upper"('x')),
                      %(SELECT U&"table\\005Fto\\005Fxml"('users', true, false, '')), %(SELECT U&"t!0061ble_to_xml" UESCAPE '!' ('users', true, false, '')),
                      %(SELECT * FROM (VALUES ("lo_get"(1)), (NULL)) v) ],
        mysql: [ "SELECT `get_lock`('x', 1)", "SELECT `release_all_locks` ()", "SELECT `sleep`/* x */(1)" ],
        sqlite: [ %(SELECT "load_extension"('x')), "SELECT [abs](1)" ] }.each do |family, statements|
        statements.each do |sql|
          expect(refusal(sql, family)).to start_with("Blocked: ").and(satisfy { |text|
            text.include?("a quoted name is followed by a parenthesis") || text.include?("dangerous function")
          }), "#{family}: #{sql}"
        end
      end
      expect(refusal("SELECT `get_lock`('x', 1)", :mysql)).to eq(
        "Blocked: a quoted name is followed by a parenthesis, the way a function is called. rails_query reads " \
        "a function's name to decide whether it runs, so write the name without quotes."
      )
      [ %(SELECT count("id") FROM "users" WHERE "id" IN (1, 2)), "SELECT `id` FROM `users` JOIN `posts` USING (`id`)",
        %(SELECT "a" FROM "t" WHERE ("a") = (1)) ].each { |sql| expect(runs?(sql, :mysql)).to be(true), sql }
    end

    it "reads a write keyword or INTO inside a literal as data, and the replace() function as a function" do
      expect(runs?("SELECT count(*) FROM orders WHERE notes LIKE '%update%'")).to be(true)
      expect(runs?("SELECT count(*) FROM orders WHERE notes = 'put into box'")).to be(true)
      expect(runs?("SELECT replace(name, 'Product ', 'P-') AS short FROM products")).to be(true)
      expect(refusal("REPLACE INTO products VALUES (1)")).to include("REPLACE")
      expect(refusal("WITH x AS (DELETE FROM orders RETURNING id) SELECT * FROM x")).to include("DELETE")
    end

    { "pg_read_file" => :postgresql, "pg_read_binary_file" => :postgresql, "pg_ls_dir" => :postgresql, "pg_stat_file" => :postgresql,
      "lo_import" => :postgresql, "load_extension" => :sqlite }.each do |fn, family|
      it "refuses the file function #{fn}" do
        expect(refusal("SELECT #{fn}('/etc/passwd')", family)).to include("dangerous function #{fn}")
        expect(refusal("SELECT id FROM notes WHERE body = '#{fn}(x)'", family)).to include("dangerous function #{fn}")
      end
    end

    it "refuses dblink, LOAD_FILE and LOAD DATA" do
      expect(refusal("SELECT * FROM dblink('host=evil.com', 'SELECT 1') AS t(a int)", :postgresql)).to include("dblink")
      expect(refusal("SELECT LOAD_FILE('/etc/passwd')", :mysql)).to match(/load_file/i)
      expect(refusal("LOAD DATA INFILE '/etc/passwd' INTO TABLE users", :mysql)).to match(/LOAD.*DATA/i)
      expect(refusal("LOAD DATA LOCAL INFILE '/etc/passwd' INTO TABLE users", :mysql)).to match(/LOAD.*DATA/i)
    end

    it "refuses a file function inside a MySQL executable comment" do
      [ "SELECT /*!50000 LOAD_FILE('/etc/passwd') */ AS x", "SELECT /*! load_file('/etc/passwd') */ AS x" ].each do |sql|
        expect(refusal(sql, :mysql)).to start_with("Blocked: dangerous function"), sql
      end
    end

    %w[
      pg_terminate_backend pg_cancel_backend pg_reload_conf pg_stat_reset
      pg_create_restore_point pg_logical_emit_message pg_advisory_lock
      pg_notify set_config txid_current pg_switch_wal pg_promote
      pg_drop_replication_slot pg_replication_origin_create
    ].each do |fn|
      it "refuses the PostgreSQL administrative function #{fn}" do
        expect(refusal("SELECT #{fn}(1)", :postgresql)).to include("administrative function #{fn}")
      end
    end

    %w[GET_LOCK RELEASE_LOCK RELEASE_ALL_LOCKS IS_FREE_LOCK IS_USED_LOCK].each do |fn|
      it "refuses the MySQL session function #{fn}" do
        expect(refusal("SELECT #{fn}('x')", :mysql)).to include("session function #{fn}")
      end
    end

    it "does not trip on a name that merely contains a refused function's name" do
      expect(runs?("SELECT lock_version, set_configuration FROM widgets")).to be(true)
    end

    [
      "SELECT name FROM users UNION SELECT password FROM users",
      "SELECT 1 UNION ALL SELECT 2",
      "SELECT *, 1, 2 FROM posts UNION DISTINCT SELECT * FROM users",
      "SELECT *, 1, 2 FROM posts UNION (SELECT * FROM users)",
      "SELECT *, 1, 2 FROM posts\nunion\n\tall (SELECT * FROM users)",
      "WITH RECURSIVE r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT n FROM r"
    ].each do |sql|
      it "refuses a UNION on every family: #{sql.lines.first.strip[0, 60]}" do
        %i[mysql sqlite postgresql].each do |family|
          expect(refusal(sql, family)).to start_with("Blocked: UNION is not run."), family.to_s
        end
      end
    end

    it "reads a union inside a string literal as data on PostgreSQL alone" do
      sql = "SELECT id FROM posts WHERE title = 'European Union'"
      expect(runs?(sql, :postgresql)).to be(true)
      expect(runs?(sql, :mysql)).to be(false)
    end
  end

  describe "SQLite pragma functions" do
    let(:relations) { { "pragma_notes" => %w[id body] } }

    it "runs every one that describes the schema or the database file, and refuses the rest on SQLite alone" do
      %w[table_info table_xinfo table_list index_list index_info index_xinfo foreign_key_list foreign_key_check integrity_check quick_check
         user_version application_id schema_version page_size page_count freelist_count encoding auto_vacuum journal_mode compile_options
         pragma_list].each { |name| expect(runs?("SELECT * FROM pragma_#{name}")).to be(true), name }
      %w[foreign_keys busy_timeout cache_size query_only synchronous database_list function_list collation_list data_version].each do |name|
        expect(refusal("SELECT * FROM pragma_#{name}")).to start_with("Blocked: `pragma_#{name}` tells of the connection that runs it."), name
      end
      %i[mysql postgresql].each do |family|
        expect(runs?("SELECT changes() AS n, id FROM pragma_foreign_keys", family)).to be(true), family.to_s
      end
      expect(runs?("SELECT changes, total_changes FROM counters")).to be(true)
      expect(runs?("SELECT id, body FROM pragma_notes")).to be(true)
    end
  end

  describe "locking clauses" do
    %w[UPDATE SHARE].push("NO KEY UPDATE").each do |lock|
      it "refuses FOR #{lock} on every family" do
        %i[sqlite mysql postgresql].each do |family|
          expect(refusal("SELECT * FROM users FOR #{lock}", family)).to include("FOR UPDATE/SHARE"), family.to_s
        end
      end
    end

    it "refuses every other spelling of a locking read on every family" do
      [ "LOCK IN SHARE MODE", "lock  in\nshare mode", "LOCK IN SHARE MODE NOWAIT", "LOCK IN SHARE MODE WAIT 1", "FOR UPDATE NOWAIT",
        "FOR UPDATE SKIP LOCKED", "FOR SHARE OF users", "FOR UPDATE WAIT 1", "FOR KEY SHARE" ].each do |lock|
        %i[sqlite mysql postgresql].each do |family|
          expect(refusal("SELECT id FROM users LIMIT 5 #{lock}", family)).to include("FOR UPDATE/SHARE"), "#{lock} on #{family}"
        end
      end
    end

    it "reads one inside a literal as data on PostgreSQL, whose read-only transaction refuses locking reads" do
      expect(runs?("SELECT id FROM orders WHERE notes LIKE '%ready for update%'", :postgresql)).to be(true)
      expect(runs?("SELECT id FROM orders WHERE notes LIKE '%lock in share mode%'", :postgresql)).to be(true)
    end

    it "reads the raw text on MySQL, whose read-only transaction allows FOR SHARE and LOCK IN SHARE MODE" do
      expect(refusal("SELECT id FROM orders WHERE notes LIKE '%ready for share%'", :mysql)).to include("FOR UPDATE/SHARE")
      expect(refusal("SELECT id FROM orders WHERE notes LIKE '%lock in share mode%'", :mysql)).to include("FOR UPDATE/SHARE")
    end
  end

  describe "literals that read like injection" do
    it "runs OR 1=1 inside a literal and as written: the caller writes the whole statement" do
      expect(runs?("SELECT id FROM posts WHERE body LIKE '%OR 1=1%'")).to be(true)
      expect(runs?("SELECT * FROM users WHERE active = false OR true")).to be(true)
    end
  end

  describe "column-alias lists" do
    let(:body) { "(SELECT * FROM users)" }

    # A bracket is refused first on the MySQL family, whatever stands in the brackets.
    def refused_everywhere(statements)
      statements.each do |sql|
        %i[sqlite mysql postgresql].each do |family|
          start = family == :mysql && sql.include?("[") ? "Blocked: a `[` outside a string" : "Blocked: a column-alias list"
          expect(refusal(sql, family)).to start_with(start), "#{family}: #{sql}"
        end
      end
    end

    it "says secret columns would leave under harmless names" do
      expect(refusal("WITH t(a,b,c) AS (SELECT * FROM users) SELECT * FROM t")).to eq(
        "Blocked: a column-alias list (e.g. `t(a, b, c)`) renames the columns a wildcard returns, so secret columns " \
        "would leave under harmless names. Name the columns you want in the SELECT list instead."
      )
    end

    it "refuses one on a CTE, whatever quotes its names" do
      lists = [ "(a, b, c)", '("a", "b", "c")', "(`a`, `b`, `c`)", "([a], [b], [c])", "('a', 'b', 'c')", "(\u00e9, \u00fc, \u00f1)",
                "(\u{1F600}, b, c)", "(a\u00a0b, b, c)", '(a, "b", `c`)', '("a""x", b, c)', "('it''s', b, c)", "(a)", '("a")', "( a ,b\n,\tc )" ]
      refused_everywhere(lists.map { |list| "WITH t #{list} AS #{body} SELECT * FROM t" })
    end

    it "refuses one on a CTE, however the CTE is named and marked" do
      refused_everywhere([
        "WITH t(a, b) AS MATERIALIZED #{body} SELECT * FROM t",
        "WITH t(a, b) AS NOT MATERIALIZED #{body} SELECT * FROM t",
        "WITH t(a, b) as\nnot  materialized\n#{body} SELECT * FROM t",
        'WITH t("a", "b") AS MATERIALIZED (SELECT * FROM users) SELECT * FROM t',
        %(WITH "t"(a, b) AS #{body} SELECT * FROM "t"), "WITH `t`(a, b) AS #{body} SELECT * FROM `t`",
        "WITH [t](a, b) AS #{body} SELECT * FROM [t]", "WITH 't'(a, b) AS #{body} SELECT * FROM 't'",
        "WITH key(a, b) AS #{body} SELECT * FROM key", "WITH \u00e9t\u00e9(a, b) AS #{body} SELECT * FROM \u00e9t\u00e9",
        "WITH t(a,b)AS(SELECT*FROM users)SELECT*FROM t", "WITH RECURSIVE t(a, b) AS #{body} SELECT * FROM t",
        "WITH x AS (SELECT 1 AS one), t(a, b) AS #{body} SELECT * FROM t",
        "WITH t(a, b) AS (WITH u AS #{body} SELECT * FROM u) SELECT * FROM t",
        "SELECT * FROM (WITH t(a, b) AS #{body} SELECT * FROM t) x",
        "WITH t /* x */ (a, b) -- y\n AS /* z */ #{body} SELECT * FROM t"
      ])
    end

    it "refuses one on a derived table, with AS and with none" do
      refused_everywhere([
        "SELECT * FROM #{body} AS t(a,b,c)", "SELECT * FROM #{body} AS t (a)", "SELECT * FROM #{body} t (a, b, c)", "SELECT * FROM #{body}t(a,b,c)",
        "SELECT * FROM #{body} `t` (`a`, `b`)", %(SELECT * FROM #{body} "t" ("a", "b")), "SELECT * FROM #{body} AS \u00e9 (\u00e9, b)",
        "SELECT * FROM #{body} ilike (a, b)", "SELECT * FROM #{body} any (a, b)", "SELECT * FROM #{body} against (a, b)", "SELECT * FROM #{body} t (a)",
        "SELECT * FROM (#{body}) t (a)", "SELECT * FROM (TABLE users) t (a, b)", "SELECT * FROM (WITH u AS #{body} SELECT * FROM u) t (a, b)",
        "SELECT * FROM posts, LATERAL #{body} AS t (a, b)", "SELECT * FROM posts, LATERAL #{body} t (a)",
        "SELECT * FROM posts JOIN #{body} t (a, b) ON t.a = posts.id"
      ])
    end

    it "refuses one on a table, on a join and on a function's rows" do
      refused_everywhere([
        "SELECT * FROM users AS u(a,b,c,d,e)", "SELECT * FROM users AS u (a)", "SELECT * FROM users u(a,b,c,d)", "SELECT * FROM users u (a)",
        %(SELECT * FROM "users" "u" ("a", "b")), "SELECT * FROM public.users u (a, b)", "SELECT * FROM ONLY users u (a, b)",
        "SELECT * FROM users * u (a, b)", "SELECT * FROM posts JOIN users u (a, b) ON u.a = posts.id",
        "SELECT * FROM (users a CROSS JOIN posts p) AS j (a, b, c)", "SELECT * FROM ROWS FROM (f(1), g(2)) AS t (a, b)",
        "SELECT * FROM unnest(xs, ys) AS t (a, b)", "SELECT * FROM generate_series(1, 2) WITH ORDINALITY AS t (a, b)",
        "SELECT * FROM generate_series(1, 2) WITH ORDINALITY t (a, b)"
      ])
    end

    it "refuses one over a VALUES body that also reads rows" do
      refused_everywhere([
        "WITH t(a, b) AS (VALUES (1, 2) EXCEPT SELECT * FROM users) SELECT * FROM t",
        "WITH t(a, b) AS (VALUES (1, (SELECT * FROM users))) SELECT * FROM t",
        "SELECT * FROM (VALUES (1, 2) INTERSECT TABLE users) AS t (a, b)"
      ])
    end

    it "runs a type modifier, a function call, a typed record list, one name on a function and a VALUES body" do
      [
        "SELECT CAST(amount AS numeric(10,2)) AS a FROM orders",
        "SELECT id::varchar(255) AS v FROM users",
        "SELECT coalesce(first_name, last_name) AS nm FROM users",
        "SELECT * FROM json_to_recordset('[]') AS t(a int, b text)",
        "SELECT * FROM generate_series(1,5) AS g(n)",
        "SELECT * FROM (VALUES (1,'a'),(2,'b')) AS v(id, name)",
        "SELECT * FROM (VALUES (1,'a'),(2,'b')) v (id, name)",
        "SELECT * FROM (VALUES ROW(1,'a'), ROW(2,'b')) AS v (id, name)",
        "WITH v(id, name) AS (VALUES (1,'a'),(2,'b')) SELECT * FROM v",
        "WITH v(id, name) AS MATERIALIZED (VALUES (1,'a'),(2,'b')) SELECT * FROM v",
        "SELECT * FROM (VALUES ('x)y', 1),('z', 2)) AS v(a, b)"
      ].each { |sql| %i[sqlite mysql postgresql].each { |family| expect(runs?(sql, family)).to be(true), "#{family}: #{sql}" } }
    end

    it "runs a parenthesised list of names that is no alias list" do
      [
        "SELECT a.id FROM a JOIN b USING (x, y)", "SELECT a.id FROM a JOIN b USING (x)", "SELECT a.id FROM a NATURAL JOIN b",
        "SELECT id FROM t WHERE (a, b) IN (SELECT a, b FROM u)", "SELECT id FROM t WHERE (a, b) IN ((1, 2), (3, 4))",
        "SELECT id FROM t WHERE a IN (b, c)", "SELECT id FROM t WHERE a IN (1, 2)", "SELECT id FROM t WHERE a NOT IN (b, c)",
        "SELECT a.id FROM a JOIN b ON (a.id = b.id)", "SELECT a.id FROM a JOIN b ON (flag)", "SELECT a.id FROM a JOIN (b, c) ON (flag)",
        "SELECT id FROM t WHERE (a) BETWEEN (b) AND (c)", "SELECT id FROM t WHERE lower(a) LIKE (b)", "SELECT id FROM t WHERE (a) OR (b)",
        "SELECT id FROM t WHERE (SELECT max(a) FROM u) IN (b, c)", "SELECT id FROM t WHERE (SELECT max(a) FROM u) LIKE (b)",
        "SELECT a MOD (b), (a) DIV (b), (a) XOR (b) FROM t", "SELECT id FROM t WHERE (a) REGEXP (b)",
        "SELECT id FROM t WHERE MATCH (title, body) AGAINST (term)", "SELECT id FROM t PARTITION (p0, p1)",
        "SELECT id FROM t USE INDEX (by_a, by_b)", "SELECT id FROM t FORCE INDEX (by_a) WHERE a = 1",
        "SELECT count(a) OVER (w) FROM t WINDOW w AS (PARTITION BY b)", "SELECT count(*) FILTER (WHERE a) FROM t",
        "SELECT id FROM t GROUP BY (a, b) HAVING (a) > 0 ORDER BY (a)", "SELECT id FROM t GROUP BY ROLLUP (a, b)",
        "SELECT DISTINCT ON (a, b) id FROM t", "SELECT CASE WHEN (a) THEN (b) ELSE (c) END FROM t",
        "SELECT greatest(a, b) AS g, least(a, b) l FROM t", "SELECT max(a) AS m FROM t", "SELECT f(a, b) FROM g(c, d)",
        "SELECT extract(year FROM age(a, b)) FROM t", "SELECT id FROM t WHERE a = ANY (ids)", "SELECT ARRAY[a, b] FROM t",
        "SELECT (a, b) = (c, d) FROM t", "SELECT ROW(a, b) FROM t", "SELECT id FROM t CROSS JOIN LATERAL f(a, b)",
        "WITH u AS (SELECT a, b FROM t) SELECT coalesce(a, b) AS c FROM u", "SELECT id FROM (SELECT id FROM t) x JOIN u USING (id)",
        "SELECT * FROM (SELECT id FROM t) x WHERE (id) IN (id)", "SELECT x.id FROM (SELECT id FROM t) AS x ORDER BY (id)"
      ].each do |sql|
        families = sql.include?("[") ? %i[sqlite postgresql] : %i[sqlite mysql postgresql]
        families.each { |family| expect(runs?(sql, family)).to be(true), "#{family}: #{sql}" }
      end
    end

    it "still refuses a secret name inside a VALUES body" do
      expect(refusal("SELECT * FROM (VALUES (password_digest)) AS v(a, b)")).to include("secret column `password_digest`")
    end
  end

  describe "a wildcard inside a subquery, with no plan to read" do
    let(:relations) { { "users" => %w[id email passwd], "creds" => %w[passwd], "we$" => %w[id api_token], "posts" => %w[id title] } }

    it "refuses it when the statement names a relation that holds a secret column, by the relation and the column" do
      %i[sqlite mysql].each do |family|
        expect(refusal("SELECT (1, 'a@example.com', 'pw') < (SELECT * FROM users) AS o", family)).to eq(
          "Blocked: a `*` inside a subquery is not run in a statement that names `users`, which holds the secret column `passwd`. " \
          "On #{families.fetch(family).name} a value read through such a wildcard can be compared or renamed past the redaction, " \
          "so name the columns in the subquery."
        )
      end
      expect(refusal("SELECT 1 FROM posts WHERE (1, 'a', 'pw') IN (TABLE users)", :mysql)).to eq(
        "Blocked: `TABLE` inside a subquery is not run in a statement that names `users`, which holds the secret column `passwd`. " \
        "`TABLE t` reads every column of `t`, and on MySQL a value read that way can be compared or renamed " \
        "past the redaction, so SELECT the columns you need in the subquery."
      )
    end

    it "has no TABLE rule on SQLite, which has no TABLE statement" do
      [ "SELECT 1 < (TABLE creds)", "SELECT 1 FROM posts WHERE (1, 'a', 'pw') IN (TABLE users)", "SELECT * FROM (TABLE users) t" ].each do |sql|
        expect(runs?(sql)).to be(true), sql
      end
    end

    it "holds IN before a relation's name to the wildcard rule on SQLite, in every spelling of the name" do
      [ "SELECT (1, 'a@example.test', 'x') IN users AS o", "SELECT (1, 'a', 'x') NOT IN users AS o", %(SELECT (1, 'a', 'x') IN "users" AS o),
        "SELECT (1, 'a', 'x') IN [users] AS o", "SELECT (1, 'a', 'x') IN `users` AS o", "SELECT (1, 'a', 'x') IN main.users AS o",
        "SELECT 'pw' IN creds AS o", "SELECT id FROM posts WHERE 'pw' IN creds", "SELECT EXISTS (SELECT 1 FROM posts WHERE 'pw' IN creds) AS o",
        "SELECT 'pw'IN\ncreds AS o" ].each do |sql|
        expect(refusal(sql)).to start_with("Blocked: `IN` before a table's name is not run in a statement that names `"), sql
      end
      expect(refusal("SELECT 'pw' IN creds AS o")).to eq(
        "Blocked: `IN` before a table's name is not run in a statement that names `creds`, which holds the secret column `passwd`. " \
        "`x IN t` is SQLite's shorthand for `x IN (SELECT * FROM t)`, and a value read through such a wildcard can be compared past the " \
        "redaction, so write the subquery with its columns named."
      )
      expect(refusal("SELECT (1, 'a', 'x') IN 'users' AS o")).to eq(
        "Blocked: `IN` before a table's name is not run in a statement that holds the string 'users'. SQLite reads a string as a table's name " \
        "where a name can stand, and the table `users` holds the secret column `passwd`. `x IN t` is SQLite's shorthand for " \
        "`x IN (SELECT * FROM t)`, and a value read through such a wildcard can be compared past the redaction, so write the subquery with " \
        "its columns named."
      )
    end

    it "runs IN before a list or a subquery in parentheses, and IN before a relation's name where no relation named holds a secret column" do
      [ "SELECT id FROM users WHERE id IN (1, 2)", "SELECT id FROM posts WHERE id IN (SELECT id FROM users)", "SELECT id FROM posts WHERE id NOT IN (1)",
        "SELECT id FROM posts WHERE title IN ('users')", "SELECT 1 IN posts AS o", "SELECT id FROM posts WHERE title = 'x IN users'" ].each do |sql|
        expect(runs?(sql)).to be(true), sql
      end
      expect(refusal("SELECT 'pw' IN creds AS o", :mysql).to_s).not_to include("`IN` before")
    end

    it "says what it tests when the wildcard reads another relation than the one that holds the secret column" do
      expect(refusal("SELECT u.id FROM users u WHERE u.id IN (SELECT * FROM posts)"))
        .to start_with("Blocked: a `*` inside a subquery is not run in a statement that names `users`, which holds the secret column `passwd`.")
    end

    it "reads a relation's name inside a string literal as data on MySQL" do
      [ "SELECT * FROM (SELECT * FROM posts) p WHERE title = 'creds'", "SELECT * FROM (SELECT * FROM posts) p WHERE title LIKE '%users%'",
        "SELECT 'users' AS label, p.* FROM (SELECT * FROM posts) p", "SELECT 1 < (SELECT * FROM ('users'))" ].each do |sql|
        expect(runs?(sql, :mysql)).to be(true), sql
      end
    end

    it "reads a string equal to the relation's name as that name on SQLite, wherever the string stands" do
      row = "SELECT (1, 'a@example.test', 'M') < (SELECT * FROM"
      [ "#{row} ('users')) AS o", "#{row} (('users'))) AS o", "#{row} ('users') AS u) AS o", "#{row} ('users' u)) AS o",
        "#{row} ('users' NOT INDEXED)) AS o", "#{row} posts CROSS JOIN ('users')) AS o", "#{row} posts LEFT JOIN ('users') ON 1) AS o",
        "#{row} (posts), ('users')) AS o", "#{row} 'users') AS o", "#{row} main.'USERS') AS o", "#{row} posts, 'creds') AS o",
        "#{row} ('we$')) AS o", "SELECT * FROM (SELECT * FROM posts) p WHERE title = 'creds'",
        "SELECT 'users' AS label, p.* FROM (SELECT * FROM posts) p" ].each do |sql|
        expect(refusal(sql)).to start_with("Blocked: a `*` inside a subquery is not run in a statement that holds the string '"), sql
      end
      expect(refusal("SELECT 1 < (SELECT * FROM ('users'))")).to eq(
        "Blocked: a `*` inside a subquery is not run in a statement that holds the string 'users'. SQLite reads a string as a table's name " \
        "where a name can stand, and the table `users` holds the secret column `passwd`. A value read through such a wildcard can be " \
        "compared or renamed past the redaction, so name the columns in the subquery."
      )
    end

    it "runs a wildcard subquery on SQLite when no string of the statement equals such a relation's name" do
      [ "SELECT * FROM (SELECT * FROM posts) p WHERE title LIKE '%users%'", "SELECT * FROM (SELECT * FROM posts) p WHERE title = 'the users'",
        "SELECT * FROM (SELECT * FROM posts) p WHERE title = 'it''s'", "SELECT * FROM (SELECT * FROM ('posts')) p",
        "SELECT title FROM posts WHERE title = 'users'" ].each do |sql|
        expect(runs?(sql)).to be(true), sql
      end
    end

    it "refuses it in a row or scalar comparison, a derived table, a CTE body and under any select modifier" do
      [
        "SELECT 'pw' < (SELECT * FROM creds) AS o", "SELECT 'pw' IN (SELECT * FROM creds) AS o",
        "SELECT id FROM posts WHERE (1, 'a', 'pw') < (SELECT * FROM users)", "SELECT id FROM posts WHERE (1, 'a', 'pw') < (SELECT users.* FROM users)",
        "SELECT 1 < (SELECT DISTINCT * FROM creds)", "SELECT 1 < (SELECT ALL u.* FROM creds u)", "SELECT 1 < (SELECT DISTINCTROW * FROM creds)",
        "SELECT 1 < (SELECT SQL_NO_CACHE * FROM creds)", "SELECT 1 < (SELECT STRAIGHT_JOIN creds.* FROM creds)",
        "SELECT 1 < (SELECT /* c */ * FROM creds)", "SELECT 1 < (SELECT\n*\nFROM creds)", "SELECT 1 < (SELECT*FROM creds)",
        "SELECT 1 < (SELECT 1, * FROM creds)", "SELECT 1 < (SELECT *, 1 FROM creds)", "SELECT 1 < (SELECT `creds`.* FROM `creds`)",
        "SELECT * FROM (SELECT * FROM users) x", "SELECT x.* FROM (SELECT u.* FROM users u) x", "WITH x AS (SELECT * FROM users) SELECT * FROM x",
        "SELECT * FROM (SELECT * FROM users a JOIN users b ON 1) x", "SELECT * FROM posts WHERE EXISTS (SELECT 1 FROM posts WHERE 'pw' < (SELECT * FROM creds))",
        "SELECT x.* FROM (SELECT * FROM `we$`) x", "SELECT x.* FROM (SELECT * FROM we$) x", %(SELECT x.* FROM (SELECT * FROM "USERS") x)
      ].each do |sql|
        %i[sqlite mysql].each { |family| expect(refusal(sql, family)).to start_with("Blocked: a `*` inside a subquery"), "#{family}: #{sql}" }
      end
      [ "SELECT 1 < (TABLE creds)", "SELECT 1 FROM posts WHERE (1, 'a', 'pw') IN (TABLE users)", "SELECT * FROM (TABLE users) t" ].each do |sql|
        expect(refusal(sql, :mysql)).to start_with("Blocked: `TABLE` inside a subquery"), sql
      end
    end

    it "runs a wildcard at the top, EXISTS, count(*), a product, and a subquery over relations with no secret column" do
      [
        "SELECT * FROM users", "SELECT u.* FROM users u JOIN posts p ON p.id = u.id", "SELECT * FROM users a JOIN users b ON 1",
        "SELECT * FROM (users)", "SELECT EXISTS (SELECT * FROM users) AS e", "SELECT id FROM posts WHERE NOT EXISTS (SELECT * FROM users)",
        "SELECT (SELECT count(*) FROM users) AS n", "SELECT id FROM posts WHERE id IN (SELECT id FROM users)",
        "SELECT (SELECT max(id * 2) FROM users) AS m", "SELECT id FROM posts WHERE id > (SELECT count( * ) FROM users)",
        "SELECT * FROM (SELECT * FROM posts) p", "WITH p AS (SELECT * FROM posts) SELECT * FROM p", "SELECT 1 < (SELECT * FROM (SELECT 2) x)"
      ].each do |sql|
        %i[sqlite mysql].each { |family| expect(refusal(sql, family).to_s).not_to include("inside a subquery"), "#{family}: #{sql}" }
      end
    end

    it "leaves the statement to the plan checks where there is a plan" do
      expect(runs?("SELECT * FROM (SELECT * FROM users) x", :postgresql)).to be(true)
    end
  end

  describe "a backslash before a quote on MySQL, which the session's sql_mode reads in one of two ways" do
    let(:relations) { { "users" => %w[id email passwd], "posts" => %w[id title] } }
    let(:mode) do
      " That is how MySQL reads the statement when the session's sql_mode holds NO_BACKSLASH_ESCAPES, and rails_query does not read " \
        "the session's mode. Write a quote inside a string doubled, so that both readings agree."
    end

    it "refuses a statement that either reading refuses, and says which reading it was" do
      { %q(SELECT '\' , user, host, plugin FROM mysql.user -- ') => "Blocked: `mysql` is not read.",
        %q(SELECT '\' , thd_id, conn_id FROM sys.session -- ') => "Blocked: `sys` is not read.",
        %q(SELECT '\' , (1, 'a@example.test', 'M') < (SELECT * FROM users) AS o -- ') => "Blocked: a `*` inside a subquery",
        %q(SELECT '\' , id FROM posts; SELECT 2 -- ') => "Blocked: multiple statements",
        %q(SELECT '\' , id INTO @v FROM posts -- ') => "Blocked: SELECT INTO creates a table",
        %q(SELECT "\" , id FROM posts; SELECT 2 -- ") => "Blocked: multiple statements" }.each do |sql, start|
        expect(refusal(sql, :mysql)).to start_with(start).and(end_with(mode)), sql
      end
    end

    it "reads a comment as the second reading does: one that holds a backslash and a quote after a string that ends in a backslash" do
      { %q(SELECT '\' /* \' */ , user, host FROM mysql.user -- ') => "Blocked: `mysql` is not read.",
        %q(SELECT '\' /* \' */ , t.a FROM (SELECT * FROM users) t (a, b, c) -- ') => "Blocked: a column-alias list" }.each do |sql, start|
        expect(refusal(sql, :mysql)).to start_with(start).and(end_with(mode)), sql
      end
    end

    it "reads a statement that holds no backslash once, and one that holds a backslash under both readings" do
      reads = 0
      allow_any_instance_of(described_class).to receive(:text_refusal).and_wrap_original do |original, *args|
        reads += 1
        original.call(*args)
      end
      counts = [ "SELECT id FROM posts WHERE title = 'x' OR title = 'y'", %q(SELECT id FROM posts WHERE title = 'a\\b') ].map do |sql|
        reads = 0
        expect(runs?(sql, :mysql)).to be(true), sql
        reads
      end
      expect(counts).to eq([ 1, 2 ])
    end

    it "ends the refusal with a full stop before it names the reading" do
      expect(refusal(%q(SELECT '\' , id FROM posts; SELECT 2 -- '), :mysql)).to eq("Blocked: multiple statements (no semicolons).#{mode}")
      expect(refusal(%q(SELECT '\' , user FROM mysql.user -- '), :mysql)).to include("needs another name. That is how MySQL reads")
    end

    it "keeps a refusal both readings give as it was" do
      expect(refusal("SELECT user FROM mysql.user", :mysql)).not_to include("NO_BACKSLASH_ESCAPES")
      expect(refusal(%q(SELECT '\' , x FROM performance_schema.threads -- '), :mysql)).to start_with("Blocked: `performance_schema` is not read.")
      expect(refusal(%q(SELECT '\' , passwd AS x FROM users -- '), :mysql)).to start_with("Blocked: query references secret column `passwd`")
    end

    it "runs a statement with an escaped quote or an escaped backslash in a string, and reads the other families as before" do
      [ %q(SELECT 'it\'s' AS v), %q(SELECT 'a\\b' AS v), %q(SELECT id FROM posts WHERE title = 'it\'s' AND id > 1),
        "SELECT id FROM posts WHERE title LIKE '%@mysql.com'", %q(SELECT "say \"hi\"" AS v) ].each do |sql|
        expect(runs?(sql, :mysql)).to be(true), sql
      end
      expect(refusal(%q(SELECT '\' , id FROM posts; SELECT 2 -- '), :sqlite)).to eq("Blocked: multiple statements (no semicolons)")
    end
  end

  describe "secret columns named in the text" do
    it "refuses a secret name however the statement uses it" do
      [
        "SELECT id, email, password_digest FROM users", "SELECT password_digest AS x FROM users LIMIT 50",
        "SELECT substring(password_digest, 1, 60) FROM users", "SELECT v FROM (SELECT password_digest AS v FROM users) sub",
        "SELECT CASE WHEN id > 0 THEN password_digest END FROM users"
      ].each { |sql| expect(refusal(sql)).to include("secret column `password_digest`"), sql }
      expect(refusal("SELECT md5(session_data) FROM sessions")).to include("session_data")
    end

    it "refuses one that follows a comment marker in a string literal" do
      expect(refusal("SELECT '--' AS m, api_key AS x FROM (SELECT 'leak' AS api_key) t")).to include("secret column `api_key`")
    end

    it "lets the app exempt a name, case-insensitively, and only that name" do
      RailsAiContext.configuration.query_allowed_columns = %w[API_SECRET]
      expect(runs?("SELECT api_secret FROM oauth_applications")).to be(true)
      expect(refusal("SELECT password_digest FROM users")).to include("password_digest")
    end

    it "refuses a configured query_redacted_columns name" do
      RailsAiContext.configuration.query_redacted_columns = %w[custom_secret_field]
      expect(refusal("SELECT custom_secret_field AS y FROM tenants")).to include("custom_secret_field")
    end

    it "matches word-bounded" do
      expect(runs?("SELECT id, keyword, description FROM tags")).to be(true)
    end

    it "refuses a name spelled with a letter MySQL folds to a plain one" do
      [ "SELECT ap\u0130_key AS x FROM t", "SELECT api_\u212Aey AS x FROM t", "SELECT AP\u0130_KEY AS x FROM t" ].each do |sql|
        expect(refusal(sql, :mysql)).to include("secret column `api_key`"), sql
      end
    end

    it "refuses MySQL's stored password hash by its column name" do
      expect(refusal("SELECT user, authentication_string AS a FROM user", :mysql)).to include("secret column `authentication_string`")
    end

    context "with a schema whose columns the heuristic flags" do
      let(:relations) { { "users" => %w[id email name api_token auth_token] } }

      it "refuses them through an alias, an expression and a subquery" do
        expect(refusal("SELECT api_token AS c FROM users")).to include("api_token")
        expect(refusal("SELECT upper(auth_token) FROM users")).to include("auth_token")
        expect(refusal("SELECT (SELECT api_token FROM users LIMIT 1) AS leaked")).to include("api_token")
        expect(runs?("SELECT id, email, name FROM users")).to be(true)
        expect(runs?("SELECT t.id FROM tokens t WHERE t.id > 0")).to be(true)
      end
    end

    it "refuses a name inside a literal off PostgreSQL" do
      expect(refusal("SELECT id FROM posts WHERE body LIKE '%secret%'")).to include("secret")
    end

    context "on PostgreSQL" do
      let(:sql) { "SELECT id FROM posts WHERE body LIKE '%secret%'" }

      it "runs a name inside a literal when the plan vouches" do
        expect(runs?(sql, :postgresql)).to be(true)
        expect(runs?("SELECT id FROM posts WHERE body = E'\\'api_key'", :postgresql)).to be(true)
        expect(runs?("SELECT $t$ api_key $t$ AS v", :postgresql)).to be(true)
      end

      it "refuses it in a statement that has no plan" do
        expect(refusal("DESCRIBE 'api_key'", :postgresql)).to include("the plan could not be obtained")
      end

      it "still refuses a real identifier beside a literal, a quoted identifier and a positional parameter" do
        expect(refusal("SELECT 'x' || api_secret AS y FROM t", :postgresql)).to include("api_secret")
        expect(refusal('SELECT "api_key" FROM t', :postgresql)).to include("api_key")
        expect(refusal(%(SELECT 1 AS "a'b", upper(api_key), 'x' FROM users), :postgresql)).to include("api_key")
        expect(refusal("SELECT id FROM t WHERE id = $1 AND api_key = $1", :postgresql)).to include("api_key")
      end
    end
  end

  describe "a view the database cannot redact" do
    let(:relations) { { "users" => %w[id email passwd] } }
    let(:views) { { "people" => "SELECT id, passwd AS p1 FROM users", "emails" => "SELECT id, email FROM users" } }

    it "refuses a statement that names it, by the view and the column, and points at the tables" do
      %i[sqlite mysql].each do |family|
        text = refusal("SELECT * FROM people", family)
        expect(text).to start_with("Blocked: the view `people` is not queried: its definition names the secret column `passwd`."), family.to_s
        expect(text).to include("A view can rename a column past the redaction on #{families.fetch(family).name}", "query the tables it reads")
      end
    end

    it "refuses it in a join, a subquery and an EXPLAIN, and reads a literal as the raw text" do
      [ "SELECT e.id FROM emails e JOIN people p ON p.id = e.id", "SELECT (SELECT p1 FROM people LIMIT 1) AS x",
        "EXPLAIN SELECT * FROM people", "SELECT 'people' AS x" ].each { |sql| expect(refusal(sql)).to include("the view `people`"), sql }
    end

    it "runs a view that names no secret column, and the definition of a refused one" do
      expect(runs?("SELECT * FROM emails")).to be(true)
      expect(runs?("SHOW CREATE VIEW people", :mysql)).to be(true)
    end
  end

  describe "a generated column that reads a secret column" do
    let(:relations) { { "users" => %w[id email passwd tax_number] } }
    let(:generated) { { "users" => { "shadow" => "`passwd`", "taxed" => "`tax_number`" } } }
    let(:encrypted) { %w[tax_number] }

    it "refuses a statement naming it and says how to release it" do
      text = refusal("SELECT shadow FROM users")
      expect(text).to include("secret column `shadow`", "`shadow` is a generated column that reads `passwd`")
      expect(text).to include('add "shadow" to config.query_allowed_columns')
    end

    it "says one that reads an encrypts column is not released" do
      expect(refusal("SELECT taxed FROM users"))
        .to include("`taxed` is a generated column that reads `tax_number`", "config.query_allowed_columns does not release it")
    end
  end

  describe RailsAiContext::SqlGate::Budget do
    let(:clock) { [ 100.0 ] }

    before do
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.first }
    end

    it "charges each read the time it took itself, and nothing for the time between reads" do
      budget = described_class.new(1)
      expect(budget.spend { |left| left }).to eq(1)
      budget.spend { clock[0] += 0.25 }
      clock[0] += 0.5
      expect(budget.spend { |left| left }).to eq(0.75)
    end

    it "charges a read that raised, and raises the timeout once nothing is left" do
      budget = described_class.new(0.5)
      expect { budget.spend { (clock[0] += 0.5) && raise("boom") } }.to raise_error("boom")
      expect(budget.spent?).to be(true)
      expect { budget.spend { :never } }.to raise_error(RailsAiContext::DatabaseFamily::TimedOut)
    end
  end

  describe "the text to run" do
    def text(sql, family = :sqlite)
      check(sql, family).sql
    end

    it "takes comments out and keeps everything else as written" do
      expect(text("SELECT /* DROP */ 1 AS test")).to eq("SELECT   1 AS test")
      expect(text("SELECT 7 AS n /* a */ -- why")).to eq("SELECT 7 AS n")
      expect(text("SELECT 1 /* open")).to eq("SELECT 1")
      expect(text("SELECT 'a  b' AS v")).to eq("SELECT 'a  b' AS v")
    end

    it "keeps a comment marker inside a literal, a quoted identifier or a dollar quote" do
      [
        "SELECT 'it''s -- fine' AS v", %(SELECT "a--b", `c/*d*/e` FROM t), "SELECT 'see /* draft */ end' AS v",
        "SELECT E'\\'', 'x /* y */ z'", "SELECT data\n  #>> '{a,b}' AS v FROM t"
      ].each { |sql| expect(text(sql)).to eq(sql) }
      [ "SELECT $tag$a -- b$tag$ AS v", "SELECT $$a /* b */ c$$ AS v", "SELECT $é$a -- b$é$ AS v" ].each do |sql|
        expect(text(sql, :postgresql)).to eq(sql)
      end
    end

    it "keeps a comment marker inside a bracketed name on SQLite, where brackets quote a name" do
      expect(text("SELECT [a /* x */ b], [c--d] FROM t")).to eq("SELECT [a /* x */ b], [c--d] FROM t")
      expect(text("SELECT [a /* x */ b] FROM t", :postgresql)).to eq("SELECT [a   b] FROM t")
    end

    it "reads an E as a string prefix only when it is a word of its own, in the text to run and in every check" do
      hidden = "SELECT 1 AS \u00a0e'a\\' AS v; SELECT 2 --'"
      %i[sqlite postgresql].each { |family| expect(refusal(hidden, family)).to eq("Blocked: multiple statements (no semicolons)"), family.to_s }
      expect(text("SELECT e'a\\' /* kept */ ' AS v")).to eq("SELECT e'a\\' /* kept */ ' AS v")
      expect(text("SELECT me'a\\' /* out */ AS v")).to eq("SELECT me'a\\'   AS v")
    end

    it "reads a string prefix letter that follows a non-ASCII character as the end of a name on PostgreSQL" do
      [ "SELECT id FROM posts WHERE title = E'x'", "SELECT id AS idée'x' FROM posts", "SELECT 1 AS 名B'1010'",
        "SELECT 1 AS 名x'1F'", "SELECT 1 AS 名U&'x'" ].each do |sql|
        expect(check(sql, :postgresql).sql).to eq(sql), sql
      end
    end

    it "reads a dollar as no quote off PostgreSQL, so a comment after one is taken out" do
      %i[sqlite mysql].each { |family| expect(text("SELECT $t$ -- x $t$ AS v\nFROM t", family)).to eq("SELECT $t$  \nFROM t") }
    end

    it "does not read a dollar inside an identifier as a quote" do
      expect(text("SELECT a$b$ -- x $b$\nFROM t")).to eq("SELECT a$b$  \nFROM t")
    end

    it "takes a version comment out whole off MySQL, and keeps what it holds on MySQL" do
      expect(text("SELECT 1 /*!50000 , 2 */")).to eq("SELECT 1")
      expect(text("SELECT 1 /*!50000 , 2 */", :mysql)).to eq("SELECT 1   , 2")
    end

    it "reads a hash comment and a dash-dash needing a space on MySQL alone" do
      expect(text("SELECT 7 AS n # why")).to eq("SELECT 7 AS n # why")
      expect(text("SELECT 7 AS n # why", :mysql)).to eq("SELECT 7 AS n")
      expect(text("SELECT 1 # note\nFROM t", :mysql)).to eq("SELECT 1  \nFROM t")
      expect(text("SELECT 5--3 AS v", :mysql)).to eq("SELECT 5--3 AS v")
      expect(text("SELECT 'it\\'s -- fine' AS v", :mysql)).to eq("SELECT 'it\\'s -- fine' AS v")
    end
  end

  describe "PostgreSQL plan checks" do
    let(:relations) { { "users" => %w[id email password_digest api_token], "posts" => %w[id title] } }

    def plan_refusal(top)
      allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:plan).and_return(top)
      refusal("SELECT * FROM users", :postgresql)
    end

    def scan(output, extra = {})
      { "Node Type" => "Seq Scan", "Relation Name" => "users", "Alias" => "u", "Output" => output }.merge(extra)
    end

    it "refuses a whole row of a relation holding a secret column" do
      expect(plan_refusal(scan([ "row_to_json(u.*)" ]))).to include("whole row of `users`")
    end

    it "runs a whole row of a relation with none" do
      expect(plan_refusal(scan([ "row_to_json(p.*)" ], "Relation Name" => "posts", "Alias" => "p"))).to be_nil
    end

    it "refuses a whole row under a quoted alias" do
      expect(plan_refusal(scan([ %(row_to_json("X y".*)) ], "Alias" => "X y"))).to include("whole row of `users`")
      expect(plan_refusal(scan([ %(("T".*)::text) ], "Alias" => "T"))).to include("whole row of `users`")
    end

    it "runs a quoted mixed-case secret column as a plain pass-through output, for redaction to filter" do
      expect(plan_refusal(scan([ "u.id", %(u."Password_Digest") ]))).to be_nil
    end

    it "refuses a quoted secret column a child passes through under a quoted alias" do
      top = { "Node Type" => "Result", "Output" => [ "(ROW(1, 'x') < ROW($0, $1))" ],
              "Plans" => [ { "Node Type" => "Seq Scan", "Relation Name" => "users", "Alias" => "X y",
                             "Output" => [ %("X y".id), %("X y"."Api_Token") ] } ] }
      expect(plan_refusal(top)).to include("passes the secret column `api_token` through")
    end

    it "refuses a relation the text did not name when the plan reads it" do
      top = { "Node Type" => "Hash Join", "Output" => [ "s.stavalues1" ],
              "Plans" => [ { "Node Type" => "Seq Scan", "Relation Name" => "pg_statistic", "Alias" => "s", "Output" => [ "s.stavalues1" ] } ] }
      expect(plan_refusal(top)).to start_with("Blocked: `pg_statistic` is not read.")
      activity = { "Node Type" => "Function Scan", "Function Name" => "pg_stat_get_activity", "Alias" => "a", "Output" => [ "a.query" ] }
      expect(plan_refusal(activity)).to start_with("Blocked: `pg_stat_get_activity` is not read.")
    end

    it "refuses a function the plan calls that the text did not name, by what the function returns" do
      set = { "Node Type" => "ProjectSet", "Output" => [ "pg_show_all_settings()" ], "Plans" => [ { "Node Type" => "Result", "Parent Relationship" => "Outer" } ] }
      expect(plan_refusal(set)).to start_with("Blocked: `pg_show_all_settings` is not read.").and end_with("run SHOW with its name.")
      activity = { "Node Type" => "Result", "Output" => [ "(pg_stat_get_activity(NULL::integer)).query" ] }
      expect(plan_refusal(activity)).to start_with("Blocked: `pg_stat_get_activity` is not read.")
      dump = { "Node Type" => "Result", "Output" => [ "table_to_xml('users'::regclass, true, false, ''::text)" ] }
      expect(plan_refusal(dump)).to start_with("Blocked: function table_to_xml returns a whole table as one value")
    end

    it "refuses the catalogs of stored credentials and the settings functions a view reads" do
      { "pg_user_mapping" => "Relation Name", "pg_subscription" => "Relation Name", "pg_foreign_server" => "Relation Name",
        "pg_show_all_settings" => "Function Name", "pg_hba_file_rules" => "Function Name" }.each do |name, key|
        node = { "Node Type" => "Seq Scan", key => name, "Alias" => "a", "Output" => [ "a.x" ] }
        expect(plan_refusal(node)).to start_with("Blocked: `#{name}` is not read."), name
      end
    end

    it "refuses a setting the plan reads that can hold a password, and one whose name the plan does not show" do
      expect(plan_refusal({ "Node Type" => "Result", "Output" => [ "current_setting('primary_conninfo'::text)" ] }))
        .to start_with("Blocked: the setting `primary_conninfo` is not read.")
      expect(plan_refusal({ "Node Type" => "Result", "Output" => [ "current_setting('app.jwt_secret'::text, true)" ] }))
        .to start_with("Blocked: the setting `app.jwt_secret` is not read.")
      expect(plan_refusal({ "Node Type" => "Seq Scan", "Relation Name" => "posts", "Alias" => "p", "Output" => [ "current_setting(p.title)" ] }))
        .to start_with("Blocked: current_setting runs only with the setting's name written as one plain string")
      expect(plan_refusal({ "Node Type" => "Result", "Output" => [ "current_setting('work_mem'::text)", "current_setting('x'::text, true)" ] })).to be_nil
    end

    it "asks pg_proc about a function the text calls where the plan prints no expression" do
      allow(connection).to receive(:select_values).and_return([ "lo_get" ])
      values = { "Node Type" => "Values Scan", "Alias" => "*VALUES*", "Output" => [ %("*VALUES*".column1) ] }
      allow(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to receive(:plan).and_return(values)
      expect(refusal("SELECT * FROM (VALUES (lo_get(1)), (NULL)) v", :postgresql)).to include("function lo_get is VOLATILE")
      expect(connection).to have_received(:select_values).with(a_string_including("'lo_get'"))
    end

    describe "the catalog columns that hold a stored credential" do
      let(:relations) { RailsAiContext::SecretColumns::CATALOG_CREDENTIALS }

      def authid(output, extra = {})
        { "Node Type" => "Seq Scan", "Relation Name" => "pg_authid", "Alias" => "pg_authid", "Output" => output }.merge(extra)
      end

      it "runs a view over pg_authid that reads no password, as PostgreSQL 16 plans pg_roles and information_schema.schemata" do
        expect(plan_refusal(authid([ "pg_authid.rolname" ]))).to be_nil
        every = %w[pg_authid.oid pg_authid.rolname pg_authid.rolsuper pg_authid.rolpassword pg_authid.rolvaliduntil]
        counted = { "Node Type" => "Aggregate", "Output" => [ "count(*)" ], "Plans" => [ authid(every, "Parent Relationship" => "Outer") ] }
        expect(plan_refusal(counted)).to be_nil
        schemata = { "Node Type" => "Hash Join", "Output" => [ "(n.nspname)::information_schema.sql_identifier" ], "Hash Cond" => "(pg_authid.oid = n.nspowner)",
                     "Plans" => [ authid(every, "Parent Relationship" => "Outer"),
                                  { "Node Type" => "Hash", "Parent Relationship" => "Inner", "Output" => [ "n.nspname", "n.nspowner" ] } ] }
        expect(plan_refusal(schemata)).to be_nil
      end

      it "refuses an expression over the password hash and over the stored settings, as pg_shadow and pg_roles are planned" do
        expect(plan_refusal(authid([ "upper(pg_authid.rolpassword)" ], "Filter" => "pg_authid.rolcanlogin")))
          .to include("plan uses the secret column `rolpassword`")
        stored = { "Node Type" => "Seq Scan", "Relation Name" => "pg_db_role_setting", "Alias" => "s", "Output" => [ "array_to_string(s.setconfig, ','::text)" ] }
        expect(plan_refusal(stored)).to include("plan uses the secret column `setconfig`")
      end

      it "names both columns as secret columns, whatever the schema holds" do
        secrets = RailsAiContext::SecretColumns.new
        expect(%w[rolpassword setconfig].map { |name| secrets.secret?(name) }).to eq([ true, true ])
        expect(refusal("SELECT rolpassword AS p FROM anything", :postgresql)).to include("secret column `rolpassword`")
      end
    end

    it "refuses a secret column the planner expanded into a ROW()" do
      expect(plan_refusal(scan([ "ROW(id, email, password_digest, api_token)" ]))).to include("plan uses the secret column `password_digest`")
    end

    it "runs a secret column as a plain pass-through output, for redaction to filter" do
      expect(plan_refusal(scan([ "id", "email", "password_digest", "u.api_token" ]))).to be_nil
    end

    it "refuses a secret column used as a filter, and ignores a secret word inside a plan literal" do
      expect(plan_refusal(scan([ "u.id" ], "Filter" => [ "(u.api_token = 'x'::text)" ]))).to include("`api_token`")
      expect(plan_refusal(scan([ "u.id" ], "Filter" => [ "(body ~~ '%api_token%'::text)", "x ~~ 'it''s a secret'::text" ]))).to be_nil
    end

    context "with a secret column whose name ends in a character no word holds" do
      let(:relations) { { "users" => [ "id", "api token$" ] } }

      it "refuses it as a filter and inside an expression" do
        expect(plan_refusal(scan([ "u.id" ], "Filter" => [ %((u."api token$" = 'x'::text)) ]))).to include("`api token$`")
        expect(plan_refusal(scan([ %(upper(u."Api Token$")) ]))).to include("`api token$`")
      end
    end

    it "refuses a secret column a child passes through that the top node does not expose" do
      top = { "Node Type" => "CTE Scan", "Output" => [ "c.id", "c.t" ],
              "Plans" => [ { "Node Type" => "Seq Scan", "Relation Name" => "users", "Alias" => "users",
                             "Output" => [ "users.id", "users.api_token" ] } ] }
      expect(plan_refusal(top)).to include("through a CTE, subquery or set operation")
    end

    # Plans PostgreSQL 16 gave for `SELECT (<subquery>) AS n` over users (id, email, api_token), a secret column last.
    describe "a subquery over a relation that holds a secret column" do
      let(:relations) { { "users" => %w[id email api_token] } }
      let(:columns) { %w[users.id users.email users.api_token] }

      def users_scan(extra = {})
        { "Node Type" => "Seq Scan", "Parent Relationship" => "Outer", "Relation Name" => "users", "Alias" => "users", "Output" => columns }.merge(extra)
      end

      def init_plan(node, returns = "$0")
        { "Node Type" => "Result", "Output" => [ "$0" ],
          "Plans" => [ node.merge("Parent Relationship" => "InitPlan", "Subplan Name" => "InitPlan 1 (returns #{returns})") ] }
      end

      def aggregate(output, child = users_scan, extra = {})
        { "Node Type" => "Aggregate", "Strategy" => "Plain", "Output" => output, "Plans" => [ child ] }.merge(extra)
      end

      it "runs an aggregate that names no secret column, over a scan that hands it every column" do
        [ "count(*)", "count(users.id)", "max(users.id)" ].each do |output|
          expect(plan_refusal(init_plan(aggregate([ output ])))).to be_nil, output
        end
        filtered = users_scan("Filter" => "(users.email ~~ 'a%'::text)")
        expect(plan_refusal(init_plan(aggregate([ "max(users.id)" ], filtered)))).to be_nil
      end

      it "runs EXISTS, whose scan returns no column" do
        scan = { "Node Type" => "Seq Scan", "Relation Name" => "users", "Alias" => "users" }
        expect(plan_refusal(init_plan(scan))).to be_nil
      end

      it "runs a join that names no secret column, over a scan that hands it every column" do
        top = { "Node Type" => "Hash Join", "Output" => [ "p.title" ], "Hash Cond" => "(users.id = p.user_id)",
                "Plans" => [ users_scan, { "Node Type" => "Hash", "Parent Relationship" => "Inner", "Output" => [ "p.title", "p.user_id" ],
                                           "Plans" => [ { "Node Type" => "Seq Scan", "Parent Relationship" => "Outer", "Relation Name" => "posts",
                                                          "Alias" => "p", "Output" => [ "p.title", "p.user_id" ] } ] } ] }
        expect(plan_refusal(top)).to be_nil
      end

      it "refuses an aggregate over the secret column" do
        [ "max(users.api_token)", "count(users.api_token)", "string_agg(users.api_token, ','::text)" ].each do |output|
          expect(plan_refusal(init_plan(aggregate([ output ])))).to include("plan uses the secret column `api_token`"), output
        end
      end

      it "refuses a whole row, alone, in a function and in an aggregate" do
        whole = { "Node Type" => "Seq Scan", "Relation Name" => "users", "Alias" => "users" }
        expect(plan_refusal(init_plan(whole.merge("Output" => [ "row_to_json(users.*)" ])))).to include("whole row of `users`")
        expect(plan_refusal(init_plan(whole.merge("Output" => [ "users.*" ])))).to include("whole row of `users`")
        counted = aggregate([ "count(users.*)" ], whole.merge("Parent Relationship" => "Outer", "Output" => [ "users.*" ]))
        expect(plan_refusal(init_plan(counted))).to include("whole row of `users`")
      end

      it "refuses a subquery the aggregate reads by position" do
        compared = users_scan("Parent Relationship" => "InitPlan", "Subplan Name" => "InitPlan 1 (returns $0,$1,$2)")
        generated = { "Node Type" => "Function Scan", "Parent Relationship" => "Outer", "Function Name" => "generate_series", "Alias" => "g", "Output" => [ "g.g" ] }
        top = { "Node Type" => "Aggregate", "Output" => [ "count(*) FILTER (WHERE (ROW(1, 'a'::text, 'b'::text) < ROW($0, $1, $2)))" ],
                "Plans" => [ compared, generated ] }
        expect(plan_refusal(top)).to include("passes the secret column `api_token` through")
      end

      it "refuses a scan whose columns a node between it and the aggregate passes on" do
        sorted = { "Node Type" => "Sort", "Parent Relationship" => "Outer", "Output" => columns, "Sort Key" => %w[users.id users.email], "Plans" => [ users_scan ] }
        unique = { "Node Type" => "Unique", "Parent Relationship" => "Outer", "Output" => columns, "Plans" => [ sorted ] }
        expect(plan_refusal(init_plan(aggregate([ "count(*)" ], unique)))).to include("passes the secret column `api_token` through")
      end

      it "refuses an aggregate that names the secret column in a grouping set" do
        grouped = aggregate([ "count(*)" ], users_scan, "Grouping Sets" => [ { "Group Keys" => [ [ "users.api_token" ] ] } ])
        expect(plan_refusal(init_plan(grouped))).to include("passes the secret column `api_token` through")
      end
    end

    # PostgreSQL 16 numbers the second use of an alias: `p_1` is the `p` of a subquery.
    describe "an alias that ends in an underscore and digits" do
      let(:relations) { { "posts" => %w[id title], "users" => %w[id email api_token], "ev" => %w[id note], "ev_2" => %w[id api_token] } }

      def scan_as(relation, as, extra = {})
        { "Node Type" => "Seq Scan", "Parent Relationship" => "Outer", "Relation Name" => relation, "Alias" => as, "Output" => [ "#{as}.*" ] }.merge(extra)
      end

      def over(output, *children)
        { "Node Type" => "Nested Loop", "Output" => output, "Plans" => children }
      end

      it "runs a whole row of a relation with no secret column whose alias a subquery uses again for one that holds one" do
        again = scan_as("users", "p_1", "Parent Relationship" => "InitPlan", "Subplan Name" => "InitPlan 1 (returns $0)", "Filter" => "(p_1.id = 1)").except("Output")
        expect(plan_refusal({ "Node Type" => "Result", "Output" => [ "row_to_json(p.*)" ], "One-Time Filter" => "$0", "Plans" => [ again, scan_as("posts", "p") ] })).to be_nil
      end

      it "runs a whole row of a table beside a table named like its numbered alias" do
        expect(plan_refusal(over([ "to_json(ev.*)" ], scan_as("ev", "ev"), scan_as("ev_2", "ev_2", "Output" => [ "ev_2.id" ])))).to be_nil
      end

      it "refuses the whole row a subquery reads under the numbered alias, by the relation it reads" do
        inner = scan_as("users", "p_1", "Parent Relationship" => "InitPlan", "Subplan Name" => "InitPlan 1 (returns $0)", "Output" => [ "row_to_json(p_1.*)" ])
        expect(plan_refusal(scan_as("posts", "p", "Output" => [ "$0" ], "Plans" => [ inner ]))).to include("whole row of `users`")
      end

      it "refuses a whole row of the relation that holds a secret column when a relation with none is scanned first under a numbered alias" do
        plan = over([ "row_to_json(x.*)" ], scan_as("posts", "x_7", "Output" => %w[x_7.id x_7.title]), scan_as("users", "x", "Parent Relationship" => "Inner"))
        expect(plan_refusal(plan)).to include("whole row of `users`")
      end

      it "refuses a whole row a node over an Append reads when the member that holds the secret column is scanned second" do
        members = [ scan_as("posts", "p_1", "Parent Relationship" => "Member", "Output" => %w[p_1.id p_1.title]),
                    scan_as("users", "p_2", "Parent Relationship" => "Member", "Output" => %w[p_2.id p_2.email]) ]
        plan = { "Node Type" => "Result", "Output" => [ "row_to_json(p.*)" ], "Plans" => [ { "Node Type" => "Append", "Parent Relationship" => "Outer", "Plans" => members } ] }
        expect(plan_refusal(plan)).to include("whole row of `users`")
      end
    end

    # Plans PostgreSQL 16 gave over rac_p (id, email, salt), partitioned in two, and over an inheritance parent.
    describe "a partitioned table or an inheritance parent that holds a secret column" do
      let(:relations) do
        %w[rac_p_a rac_p_b rac_parent rac_child].flat_map { |name| [ name, "public.#{name}" ] }.to_h { |name| [ name, %w[id email salt] ] }
      end

      def member(relation, as, columns = %w[id email salt], extra = {})
        { "Node Type" => "Seq Scan", "Parent Relationship" => "Member", "Relation Name" => relation, "Schema" => "public", "Alias" => as,
          "Output" => columns.map { |column| "#{as}.#{column}" } }.merge(extra)
      end

      def append(as = "rac_p", extra = {})
        { "Node Type" => "Append", "Subplans Removed" => 0, "Plans" => [ member("rac_p_a", "#{as}_1"), member("rac_p_b", "#{as}_2") ] }.merge(extra)
      end

      it "runs a wildcard over every partition, over a sorted and limited read, and over a parent with its child, for redaction to filter" do
        expect(plan_refusal(append)).to be_nil
        sorted = { "Node Type" => "Sort", "Parent Relationship" => "Outer", "Output" => %w[rac_p.id rac_p.email rac_p.salt], "Sort Key" => [ "rac_p.id" ],
                   "Plans" => [ append("rac_p", "Parent Relationship" => "Outer") ] }
        expect(plan_refusal({ "Node Type" => "Limit", "Output" => %w[rac_p.id rac_p.email rac_p.salt], "Plans" => [ sorted ] })).to be_nil
        inherited = { "Node Type" => "Append", "Plans" => [ member("rac_parent", "rac_parent_1"), member("rac_child", "rac_parent_2") ] }
        expect(plan_refusal(inherited)).to be_nil
      end

      it "names the table column behind each result column of the partitions" do
        sources = RailsAiContext::DatabaseFamily::PostgresqlRuntime.planned_sources(append)
        expect(sources).to eq([ [ 0, "id", "public.rac_p_a" ], [ 1, "email", "public.rac_p_a" ], [ 2, "salt", "public.rac_p_a" ] ])
      end

      # `SELECT *, id + 1 AS next`, `SELECT tableoid::regclass, *` and `SELECT 1 AS one, *` over the partitioned table.
      def beside(as = "rac_p")
        [ ->(name) { [ "#{name}.id", "#{name}.email", "#{name}.salt", "(#{name}.id + 1)" ] },
          ->(name) { [ "(#{name}.tableoid)::regclass", "#{name}.id", "#{name}.email", "#{name}.salt" ] },
          ->(name) { [ "1", "#{name}.id", "#{name}.email", "#{name}.salt" ] } ].map do |output|
          { "Node Type" => "Append", "Subplans Removed" => 0,
            "Plans" => [ member("rac_p_a", "#{as}_1").merge("Output" => output.call("#{as}_1")), member("rac_p_b", "#{as}_2").merge("Output" => output.call("#{as}_2")) ] }
        end
      end

      it "runs an expression beside the wildcard, and names the table column behind each plain result column" do
        beside.each { |plan| expect(plan_refusal(plan)).to be_nil, plan.dig("Plans", 0, "Output").inspect }
        sources = beside.map { |plan| RailsAiContext::DatabaseFamily::PostgresqlRuntime.planned_sources(plan).map { |i, column, _| [ i, column ] } }
        expect(sources).to eq([ [ [ 0, "id" ], [ 1, "email" ], [ 2, "salt" ] ], [ [ 1, "id" ], [ 2, "email" ], [ 3, "salt" ] ], [ [ 1, "id" ], [ 2, "email" ], [ 3, "salt" ] ] ])

        sorted = { "Node Type" => "Sort", "Parent Relationship" => "Outer", "Output" => [ "rac_p.id", "rac_p.email", "rac_p.salt", "((rac_p.id + 1))" ],
                   "Sort Key" => [ "rac_p.id" ], "Plans" => [ beside.first.merge("Parent Relationship" => "Outer") ] }
        expect(plan_refusal({ "Node Type" => "Limit", "Output" => sorted["Output"], "Plans" => [ sorted ] })).to be_nil
      end

      it "refuses an expression over the secret column beside the wildcard, and an expression in one member where the other hands up a column" do
        over = ->(name) { [ "#{name}.id", "#{name}.email", "#{name}.salt", "upper(#{name}.salt)" ] }
        named = { "Node Type" => "Append",
                  "Plans" => [ member("rac_p_a", "rac_p_1").merge("Output" => over.call("rac_p_1")), member("rac_p_b", "rac_p_2").merge("Output" => over.call("rac_p_2")) ] }
        expect(plan_refusal(named)).to include("plan uses the secret column `salt`")
        uneven = { "Node Type" => "Append",
                   "Plans" => [ member("rac_p_a", "t_1"), member("rac_p_a", "t_2").merge("Output" => [ "t_2.id", "upper(t_2.email)", "t_2.salt" ]) ] }
        expect(plan_refusal(uneven)).to include("passes the secret column `salt` through")
      end

      it "still refuses the secret column as a sort key, through a materialized CTE and through a set operation" do
        by_salt = { "Node Type" => "Sort", "Output" => %w[x.id x.email x.salt], "Sort Key" => [ "x.salt" ], "Plans" => [ append("x", "Parent Relationship" => "Outer") ] }
        expect(plan_refusal(by_salt)).to include("plan uses the secret column `salt`")
        cte = { "Node Type" => "CTE Scan", "CTE Name" => "c", "Alias" => "c", "Output" => %w[c.id c.email c.salt],
                "Plans" => [ append("rac_p", "Parent Relationship" => "InitPlan", "Subplan Name" => "CTE c") ] }
        expect(plan_refusal(cte)).to include("passes the secret column `salt` through")
        first = { "Node Type" => "Subquery Scan", "Parent Relationship" => "Member", "Alias" => "*SELECT* 1",
                  "Output" => [ %("*SELECT* 1".id), %("*SELECT* 1".email), %("*SELECT* 1".salt), "0" ], "Plans" => [ append("rac_p", "Parent Relationship" => "Subquery") ] }
        second = { "Node Type" => "Subquery Scan", "Parent Relationship" => "Member", "Alias" => "*SELECT* 2", "Output" => [ "0", "''::text", "''::text", "1" ],
                   "Plans" => [ { "Node Type" => "Result", "Parent Relationship" => "Subquery", "Output" => [ "0", "''::text", "''::text" ] } ] }
        except = { "Node Type" => "SetOp", "Command" => "Except", "Output" => [ %("*SELECT* 1".id), %("*SELECT* 1".email), %("*SELECT* 1".salt), "(0)" ],
                   "Plans" => [ { "Node Type" => "Append", "Parent Relationship" => "Outer", "Plans" => [ first, second ] } ] }
        expect(plan_refusal(except)).to include("passes the secret column `salt` through")
      end

      it "refuses members that hand up the secret column in another place, as a view over a UNION ALL plans them" do
        swapped = { "Node Type" => "Append", "Plans" => [ member("rac_p_a", "t_1"), member("rac_p_a", "t_2", %w[id salt email]) ] }
        expect(plan_refusal(swapped)).to include("passes the secret column `salt` through")
      end

      it "reads members that hand up the same columns in the same places alike, whatever their aliases" do
        mixed = { "Node Type" => "Append", "Plans" => [ member("rac_p_a", "a"), member("rac_p_b", "b") ] }
        expect(plan_refusal(mixed)).to be_nil
        expect(RailsAiContext::DatabaseFamily::PostgresqlRuntime.planned_sources(mixed).map { |i, column, _| [ i, column ] })
          .to eq([ [ 0, "id" ], [ 1, "email" ], [ 2, "salt" ] ])
      end

      it "refuses a whole row of the partitions under any alias, in a member and in a node over them" do
        [ "e", "pev", "e_1", "E x" ].each do |as|
          row = ->(name) { [ "row_to_json((#{name.match?(/\W/) ? %("#{name}") : name}.*)::rac_p)" ] }
          members = [ member("rac_p_a", "#{as}_1").merge("Output" => row.call("#{as}_1")), member("rac_p_b", "#{as}_2").merge("Output" => row.call("#{as}_2")) ]
          expect(plan_refusal({ "Node Type" => "Append", "Plans" => members })).to include("whole row of `rac_p_a`"), as
        end
        over = { "Node Type" => "Result", "Output" => [ "row_to_json(p.*)" ],
                 "Plans" => [ { "Node Type" => "Append", "Parent Relationship" => "Outer",
                                "Plans" => [ member("rac_parent", "p_1", [ "*" ]), member("rac_child", "p_2", [ "*" ]) ] } ] }
        expect(plan_refusal(over)).to include("whole row of `rac_parent`")
      end
    end

    # Plans PostgreSQL 16 gave for views over `SELECT id, <the whole row> FROM logs_2023 UNION ALL SELECT ... FROM logs_2024`.
    describe "a view over a UNION ALL of tables, one of which holds a secret column" do
      let(:relations) do
        { "logs_2023" => %w[id label], "logs_2024" => %w[id label api_token], "logs_2025" => %w[id label api_token],
          "logs_a" => %w[id label], "logs_b" => %w[id label api_token] }.flat_map { |name, columns| [ [ name, columns ], [ "public.#{name}", columns ] ] }.to_h
      end

      def scan_of(table, output, extra = {})
        { "Node Type" => "Seq Scan", "Parent Relationship" => "Member", "Relation Name" => table, "Schema" => "public", "Alias" => table,
          "Output" => output.map { |expr| format(expr, table) } }.merge(extra)
      end

      def union(tables, output, extra = {})
        { "Node Type" => "Append", "Plans" => tables.map { |table| scan_of(table, output) } }.merge(extra)
      end

      it "refuses the whole row of the table that holds the secret column, wherever that table stands among the members" do
        { %w[logs_2023 logs_2024] => "logs_2024", %w[logs_2023 logs_2024 logs_2025] => "logs_2024", %w[logs_2024 logs_2023] => "logs_2024",
          %w[logs_a logs_b] => "logs_b" }.each do |tables, held|
          [ "to_jsonb(%s.*)", "(%s.*)::text" ].each do |row|
            expect(plan_refusal(union(tables, [ "%s.id", row ]))).to include("whole row of `#{held}`"), "#{tables} #{row}"
          end
        end
      end

      it "refuses the whole row read through an operator, and compared in a filter the aggregate counts" do
        read = { "Node Type" => "Result", "Output" => [ "((to_jsonb(logs_2023.*)) ->> 'api_token'::text)" ],
                 "Plans" => [ union(%w[logs_2023 logs_2024], [ "to_jsonb(%s.*)" ], "Parent Relationship" => "Outer") ] }
        expect(plan_refusal(read)).to include("whole row of `logs_2024`")
        filtered = %w[logs_2023 logs_2024].map do |table|
          scan_of(table, [], "Filter" => "((#{table}.*)::text ~~ '%FAKE%'::text)").except("Output")
        end
        counted = { "Node Type" => "Aggregate", "Output" => [ "count(*)" ], "Plans" => [ { "Node Type" => "Append", "Parent Relationship" => "Outer", "Plans" => filtered } ] }
        expect(plan_refusal(counted)).to include("whole row of `logs_2024`")
      end

      it "runs the whole rows of tables that hold no secret column, and the plain columns of the ones that do" do
        expect(plan_refusal(union(%w[logs_2023 logs_a], [ "%s.id", "to_jsonb(%s.*)" ]))).to be_nil
        expect(plan_refusal(union(%w[logs_2023 logs_2024], [ "%s.id", "%s.label" ]))).to be_nil
      end

      it "names the secret column behind a result column when any member hands it up there, and refuses members that differ" do
        same = union(%w[logs_2024 logs_b], [ "%s.id", "%s.label", "%s.api_token" ])
        expect(plan_refusal(same)).to be_nil
        expect(RailsAiContext::DatabaseFamily::PostgresqlRuntime.planned_sources(same).map { |i, column, _| [ i, column ] })
          .to eq([ [ 0, "id" ], [ 1, "label" ], [ 2, "api_token" ] ])
        differing = { "Node Type" => "Append", "Plans" => [ scan_of("logs_2023", [ "%s.id", "%s.label", "'x'::text" ]),
                                                             scan_of("logs_2024", [ "%s.id", "%s.label", "%s.api_token" ]) ] }
        expect(plan_refusal(differing)).to include("passes the secret column `api_token` through")
      end
    end

    it "refuses an unlisted VOLATILE function as VOLATILE" do
      allow(connection).to receive(:select_values).and_return([ "nextval" ])
      expect(plan_refusal({ "Node Type" => "Result", "Output" => [ "nextval('s'::regclass)" ] }))
        .to include("function nextval is VOLATILE (pg_proc.provolatile = 'v')")
        .and include("not on rails_query's list of read-only VOLATILE functions")
    end

    it "asks pg_proc nothing when every function named only reads" do
      top = { "Node Type" => "Result", "Output" => [ "pg_total_relation_size('orders')", "pg_database_size('app')", "pg_is_in_recovery()" ] }
      expect(plan_refusal(top)).to be_nil
      expect(connection).not_to have_received(:select_values)
    end

    it "plans the statement a leading EXPLAIN ANALYZE would run" do
      refusal("EXPLAIN ANALYZE SELECT 1 AS x", :postgresql)
      expect(RailsAiContext::DatabaseFamily::PostgresqlRuntime).to have_received(:plan).with(connection, "SELECT 1 AS x", a_value_within(1).of(5))
    end

    it "plans nothing off PostgreSQL" do
      check("SELECT 1 AS x", :mysql)
      expect(RailsAiContext::DatabaseFamily::PostgresqlRuntime).not_to have_received(:plan)
    end

    it "answers the plan with the verdict" do
      expect(check("SELECT 1 AS x", :postgresql).plan).to eq(plan)
    end

    describe "a plan that cannot be read" do
      let(:runtime) { RailsAiContext::DatabaseFamily::PostgresqlRuntime }

      it "refuses the statement when planning answers no plan" do
        allow(runtime).to receive(:plan).and_return(nil)
        [ "SELECT * FROM users", "WITH u AS (SELECT * FROM users) SELECT * FROM u", "EXPLAIN ANALYZE SELECT * FROM users" ].each do |sql|
          expect(refusal(sql, :postgresql)).to include("its plan could not be read"), sql
        end
      end

      it "raises planning's timeout and planning's SQL error for the caller to answer" do
        allow(runtime).to receive(:plan).and_raise(RailsAiContext::DatabaseFamily::TimedOut, "stopped")
        expect { check("SELECT row_to_json(u) FROM users u", :postgresql) }.to raise_error(RailsAiContext::DatabaseFamily::TimedOut)

        allow(runtime).to receive(:plan).and_raise(ActiveRecord::StatementInvalid, "boom")
        expect { check("SELECT nope FROM users", :postgresql) }.to raise_error(ActiveRecord::StatementInvalid)
      end

      it "raises an error from a plan check" do
        allow(connection).to receive(:select_values).and_raise(ActiveRecord::StatementInvalid, "pg_proc unreadable")
        allow(runtime).to receive(:plan).and_return({ "Node Type" => "Result", "Output" => [ "nextval('s'::regclass)" ] })
        expect { check("SELECT nextval('s')", :postgresql) }.to raise_error(ActiveRecord::StatementInvalid)
      end

      it "gives the plan and the pg_proc lookup one budget between them, and leaves the caller what they did not use" do
        allow(runtime).to receive(:plan) do
          sleep 0.2
          { "Node Type" => "Result", "Output" => [ "nextval('s'::regclass)" ] }
        end
        budget = described_class::Budget.new(2)
        described_class.new(family: families.fetch(:postgresql), secrets: RailsAiContext::SecretColumns.new, connection: connection, budget: budget)
          .check("SELECT nextval('s')")

        expect(runtime).to have_received(:plan).with(connection, "SELECT nextval('s')", a_value_within(0.1).of(2))
        expect(runtime).to have_received(:bounded).with(connection, a_value_between(1, 1.8))
        expect(budget.spend { |left| left }).to be_between(1, 1.8)
      end

      it "raises the timeout when the plan used all of it" do
        allow(runtime).to receive(:plan) do
          sleep 0.06
          { "Node Type" => "Result", "Output" => [ "nextval('s'::regclass)" ] }
        end
        gate = described_class.new(family: families.fetch(:postgresql), secrets: RailsAiContext::SecretColumns.new, connection: connection, budget: described_class::Budget.new(0.05))

        expect { gate.check("SELECT nextval('s')") }.to raise_error(RailsAiContext::DatabaseFamily::TimedOut)
        expect(connection).not_to have_received(:select_values)
      end

      it "plans whatever a leading EXPLAIN would run, in either spelling of its options" do
        [ "EXPLAIN VALUES (1)", "EXPLAIN (ANALYZE, VERBOSE) VALUES (1)", "EXPLAIN ANALYZE VERBOSE VALUES (1)" ].each { |sql| check(sql, :postgresql) }
        expect(runtime).to have_received(:plan).with(connection, "VALUES (1)", a_value_within(1).of(5)).exactly(3).times

        check("EXPLAIN (ANALYZE) (SELECT 1)", :postgresql)
        expect(runtime).to have_received(:plan).with(connection, "(SELECT 1)", a_value_within(1).of(5))
      end

      # SHOW reads a setting and PostgreSQL has no DESCRIBE, so neither has a plan to read.
      it "runs SHOW, DESCRIBE and DESC with no plan" do
        [ "SHOW server_version", "DESCRIBE users", "DESC users" ].each do |sql|
          verdict = check(sql, :postgresql)
          expect([ verdict.refused?, verdict.plan ]).to eq([ false, nil ]), sql
        end
        expect(runtime).not_to have_received(:plan)
      end
    end
  end
end
