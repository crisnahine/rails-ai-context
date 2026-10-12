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
        conn.execute("DROP TABLE IF EXISTS rac_my_accounts")
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
          "rac_my_renamed" => "the view `rac_my_renamed` is not queried: its definition names the sensitive column `passwd`",
          "rac_my_nested" => "the view `rac_my_nested` is not queried: it reads the view `rac_my_renamed`",
          "rac_my_everything" => "the view `rac_my_everything` is not queried: its definition names the sensitive column `passwd`"
        }.each do |view, reason|
          response = answer("SELECT * FROM #{view}")
          expect(response.error?).to be(true), view
          expect(response.content.first[:text]).to include(reason, "on MySQL, so query the tables it reads")
          expect(response.content.first[:text]).not_to include("pw-value")
        end
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
