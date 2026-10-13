# frozen_string_literal: true

require "spec_helper"
require "delegate"

RSpec.describe RailsAiContext::SecretColumns do
  let(:config) { RailsAiContext.configuration }

  around do |example|
    redacted = config.query_redacted_columns
    allowed = config.query_allowed_columns
    config.query_redacted_columns = described_class::DEFAULT_REDACTED_COLUMNS.dup
    config.query_allowed_columns = []
    example.run
  ensure
    config.query_redacted_columns = redacted
    config.query_allowed_columns = allowed
  end

  def secrets(relations: {}, encrypted: [])
    described_class.new(relations: relations, encrypted: encrypted)
  end

  describe "#secret?" do
    it "is true for MySQL's stored password hash, and for a name with a letter MySQL folds to a plain one" do
      expect(secrets.secret?("authentication_string")).to be(true)
      expect(secrets.secret?("AP\u0130_KEY")).to be(true)
    end

    {
      "a name the app redacts" => "ssn_last_four",
      "a built-in secret name" => "otp_secret",
      "an encrypts column" => "tax_number",
      "a name the heuristic flags" => "auth_token",
      "Redaction's passwd" => "passwd",
      "Redaction's salt" => "salt",
      "Redaction's credentials" => "credentials",
      "Redaction's pepper" => "pepper"
    }.each do |label, name|
      it "is true for #{label} (#{name})" do
        config.query_redacted_columns += %w[ssn_last_four]
        expect(secrets(encrypted: %w[tax_number]).secret?(name)).to be(true)
      end
    end

    it "is true for a nonce or an initialization vector column" do
      %w[nonce otp_nonce nonce_value iv encrypted_ssn_iv Content_IV].each do |name|
        expect(secrets.secret?(name)).to be(true), name
      end
    end

    it "is false for ordinary columns" do
      %w[id email name status created_at user_id lock_version salt_length archive active private_ivy].each do |name|
        expect(secrets.secret?(name)).to be(false), name
      end
    end

    it "is false for a nonce or iv column the app allows by name" do
      config.query_allowed_columns = %w[otp_nonce content_iv]
      %w[otp_nonce content_iv].each { |name| expect(secrets.secret?(name)).to be(false), name }
      expect(secrets.secret?("session_nonce")).to be(true)
    end

    it "does not teach the shared redaction words nonce or iv" do
      expect(RailsAiContext::Redaction.secret_name?("content_security_policy_nonce_generator")).to be(false)
      expect(RailsAiContext::Redaction.secret_name?("iv")).to be(false)
    end

    it "is false for a name the app allows, whatever rule flags it" do
      config.query_allowed_columns = %w[OTP_SECRET auth_token salt]
      %w[otp_secret auth_token salt].each { |name| expect(secrets.secret?(name)).to be(false), name }
    end

    it "keeps an allowed encrypts column encrypted, so its values stay hidden" do
      config.query_allowed_columns = %w[tax_number]
      expect(secrets(encrypted: %w[tax_number]).encrypted?("TAX_NUMBER")).to be(true)
    end

    it "keeps an allowed encrypts column secret, so a statement naming it is refused" do
      config.query_allowed_columns = %w[tax_number]
      secrets = secrets(relations: { "users" => %w[id tax_number] }, encrypted: %w[tax_number])
      expect(secrets.secret?("tax_number")).to be(true)
      expect(secrets.named_in("select tax_number as t from users")).to eq("tax_number")
      expect(secrets.in_schema).to eq(%w[tax_number])
      expect(secrets.of_relation("users")).to eq(%w[tax_number])
    end

    it "names an allowed encrypts column the schema does not list" do
      config.query_allowed_columns = %w[tax_number]
      expect(secrets(encrypted: %w[tax_number]).named_in("select tax_number from users")).to eq("tax_number")
    end

    it "treats a word added to Redaction's secret words as secret with no other change" do
      allow(RailsAiContext::Redaction).to receive(:secret_name?).and_call_original
      allow(RailsAiContext::Redaction).to receive(:secret_name?).with("national_id").and_return(true)
      expect(secrets.secret?("national_id")).to be(true)
    end
  end

  describe "#named_in" do
    let(:relations) { { "users" => %w[id email auth_token], "keys" => %w[id salt] } }

    it "names a fixed secret name that is no real column" do
      expect(secrets.named_in("select upper(api_secret) from t")).to eq("api_secret")
    end

    it "names a real secret column the fixed list does not hold" do
      expect(secrets(relations: relations).named_in("select auth_token as c from users")).to eq("auth_token")
      expect(secrets(relations: relations).named_in("select s.salt from keys s")).to eq("salt")
    end

    it "matches whole words only, so a table or alias holding a secret word passes" do
      expect(secrets(relations: relations).named_in("select t.id from tokens t join salts on true")).to be_nil
    end

    it "passes a name the app allows" do
      config.query_allowed_columns = %w[api_secret auth_token]
      expect(secrets(relations: relations).named_in("select api_secret, auth_token from users")).to be_nil
    end
  end

  describe "per relation" do
    let(:secrets_by_schema) do
      secrets(relations: { "users" => %w[id password_digest api_token], "posts" => %w[id title] })
    end

    it "lists a relation's secret columns" do
      expect(secrets_by_schema.of_relation("USERS")).to contain_exactly("password_digest", "api_token")
      expect(secrets_by_schema.of_relation("posts")).to eq([])
      expect(secrets_by_schema.of_relation("missing")).to eq([])
    end

    it "says whether a relation holds a secret column" do
      expect(secrets_by_schema.relation_secret?("users")).to be(true)
      expect(secrets_by_schema.relation_secret?("posts")).to be(false)
    end

    it "lists the schema's secret columns" do
      expect(secrets_by_schema.in_schema).to contain_exactly("password_digest", "api_token")
    end
  end

  describe "#relation_named_in" do
    let(:held) { secrets(relations: { "users" => %w[id passwd], "posts" => %w[id title], "led$" => %w[api_token] }) }

    it "is the first relation holding a secret column that the text names, as a whole identifier in any quoting" do
      expect(held.relation_named_in("SELECT * FROM (SELECT * FROM Users) x")).to eq("users")
      expect(held.relation_named_in(%(SELECT * FROM (SELECT * FROM "users") x))).to eq("users")
      expect(held.relation_named_in("SELECT * FROM (SELECT * FROM led$) x")).to eq("led$")
    end

    it "is nil for a relation with no secret column and for a longer name" do
      expect(held.relation_named_in("SELECT * FROM (SELECT * FROM posts) x")).to be_nil
      expect(held.relation_named_in("SELECT * FROM (SELECT * FROM users_archive) x")).to be_nil
    end
  end

  describe "#refused_view_in" do
    let(:relations) { { "users" => %w[id email passwd tax_number], "posts" => %w[id title] } }

    def refused(views, sql, **options)
      described_class.new(relations: relations, views: views, **options).refused_view_in(sql)
    end

    it "refuses a view that renames a secret column, by the view and the column" do
      views = { "people" => "select `app`.`users`.`id` AS `id`,`app`.`users`.`passwd` AS `p1` from `app`.`users`" }
      expect(refused(views, "SELECT p1 FROM People")).to eq([ "people", "its definition names the secret column `passwd`" ])
    end

    it "refuses a view built on such a view, however deep" do
      views = { "third" => "SELECT * FROM second", "second" => "SELECT p1 FROM people", "people" => "SELECT passwd AS p1 FROM users" }
      expect(refused(views, "SELECT * FROM second")).to eq([ "second", "it reads the view `people`: its definition names the secret column `passwd`" ])
      expect(refused(views, "SELECT * FROM third").last).to start_with("it reads the view `second`: it reads the view `people`")
    end

    it "matches a view's name as an identifier, whatever characters it holds and however it is quoted" do
      definition = "SELECT passwd AS p1 FROM users"
      {
        "v$" => [ "SELECT * FROM v$", %(SELECT * FROM "v$" WHERE p1 > ''), "SELECT * FROM `V$`" ],
        "two  words" => [ %(SELECT * FROM "two words"), "SELECT * FROM [two words]", %(SELECT * FROM "two  words"), "SELECT * FROM `Two  Words`" ],
        'quo"ted' => [ %(SELECT * FROM "quo""ted") ],
        "back`tick" => [ "SELECT * FROM `back``tick`" ]
      }.each do |view, statements|
        statements.each { |sql| expect(refused({ view => definition }, sql)&.first).to eq(view), sql }
      end
      expect(refused({ "v$" => definition }, "SELECT * FROM v$x")).to be_nil
    end

    it "refuses a view whose definition has a wildcard and names a relation holding a secret column" do
      [ "SELECT * FROM users", "SELECT u.* FROM users u", "SELECT DISTINCT * FROM users", "SELECT id, * FROM users" ].each do |definition|
        expect(refused({ "everyone" => definition }, "SELECT * FROM everyone"))
          .to eq([ "everyone", "its definition has a wildcard and names `users`, which holds the secret column `passwd`" ]), definition
      end
    end

    it "runs a view that names no secret column" do
      views = { "titles" => "SELECT * FROM posts", "emails" => "SELECT id, email FROM users", "headcount" => "SELECT count(*) AS n FROM users" }
      %w[titles emails headcount].each { |view| expect(refused(views, "SELECT * FROM #{view}")).to be_nil, view }
    end

    it "runs a statement that names no refused view, and reads whole words only" do
      views = { "people" => "SELECT passwd AS p1 FROM users" }
      expect(refused(views, "SELECT id FROM posts")).to be_nil
      expect(refused(views, "SELECT id FROM people_archive")).to be_nil
    end

    it "runs a view over a column the app allows, and refuses one over an allowed encrypts column" do
      config.query_allowed_columns = %w[passwd tax_number]
      expect(refused({ "people" => "SELECT passwd AS p1 FROM users" }, "SELECT * FROM people")).to be_nil
      expect(refused({ "taxes" => "SELECT tax_number AS t FROM users" }, "SELECT * FROM taxes", encrypted: %w[tax_number]))
        .to eq([ "taxes", "its definition names the secret column `tax_number`" ])
    end

    it "refuses a view whose definition cannot be read when a relation holds a secret column" do
      [ nil, "", "  " ].each do |unreadable|
        expect(refused({ "opaque" => unreadable }, "SELECT * FROM opaque"))
          .to eq([ "opaque", "its definition could not be read, and this database holds secret columns" ]), unreadable.inspect
      end
      expect(described_class.new(relations: { "posts" => %w[id title] }, views: { "opaque" => nil }).refused_view_in("SELECT * FROM opaque")).to be_nil
    end

    it "refuses no view where the family traces a result column to its table column" do
      expect(refused(nil, "SELECT * FROM people")).to be_nil
    end
  end

  describe "a generated column" do
    let(:relations) { { "users" => %w[id email passwd tax_number shown hidden deeper] } }
    let(:generated) { { "users" => { "Hidden" => "`passwd`", "deeper" => "concat(`hidden`,'x')", "shown" => "upper(`email`)" } } }

    def secrets(**options)
      described_class.new(relations: relations, generated: generated, **options)
    end

    it "is secret when its expression reads a secret column, also through another generated column" do
      expect(%w[hidden deeper shown].map { |name| secrets.secret?(name) }).to eq([ true, true, false ])
      expect(secrets.of_relation("users")).to contain_exactly("passwd", "hidden", "deeper")
      expect(secrets.named_in("SELECT deeper FROM users")).to eq("deeper")
    end

    it "is secret on a relation whose column list leaves it out" do
      secrets = described_class.new(relations: { "users" => %w[id passwd] }, generated: generated)
      expect(secrets.of_relation("users")).to contain_exactly("passwd", "hidden", "deeper")
    end

    it "is released by name, unless it reads an encrypts column" do
      config.query_allowed_columns = %w[hidden]
      expect(secrets.secret?("hidden")).to be(false)

      taxed = { "users" => { "hidden" => "`tax_number`" } }
      secrets = described_class.new(relations: relations, generated: taxed, encrypted: %w[tax_number])
      expect([ secrets.secret?("hidden"), secrets.encrypted?("hidden") ]).to eq([ true, true ])
    end

    it "makes a view that names it a refused view" do
      secrets = secrets(views: { "people" => "SELECT hidden AS h FROM users" })
      expect(secrets.refused_view_in("SELECT h FROM people")).to eq([ "people", "its definition names the secret column `hidden`" ])
    end
  end

  describe "what a statement reaches on a server of several databases" do
    let(:conn) { ActiveRecord::Base.connection }
    let(:runtime) { RailsAiContext::DatabaseFamily::SqliteRuntime }
    # database => [its tables, its views]. far leads through d1, d2 and d3 to d4; near starts at d2.
    let(:server) do
      {
        "own" => [ { "notes" => %w[id body] }, { "far" => "SELECT x FROM d1.v", "near" => "SELECT x FROM d2.v", "peek" => "SELECT body FROM twin.notes" } ],
        "d1" => [ {}, { "v" => "SELECT x FROM d2.v" } ], "d2" => [ {}, { "v" => "SELECT x FROM d3.v" } ],
        "d3" => [ {}, { "v" => "SELECT door_token AS x FROM d4.t" } ], "d4" => [ { "t" => %w[id door_token] }, {} ],
        "twin" => [ { "notes" => %w[id body api_token] }, {} ]
      }
    end
    let(:read) { [] }

    before do
      held = ->(schemas, part) { schemas.map { |schema| server.fetch(schema)[part] }.reduce({}) { |all, found| all.merge(found) { |_, a, b| a + b } } }
      allow(runtime).to receive_messages(unqualified_schemas: %w[own], generated_columns: {}, index_tables: {})
      allow(runtime).to receive(:schemas_named) { |_conn, names| names & (server.keys - %w[own]) }
      allow(runtime).to receive(:relation_columns) { |_conn, schemas| read.concat(schemas) && held.call(schemas, 0) }
      allow(runtime).to receive(:view_definitions) { |_conn, schemas| held.call(schemas, 1) }
    end

    def rule(sql)
      RailsAiContext::RunCache.around { described_class.for(conn, context: {}, statement: sql) }
    end

    it "reads no other database for a statement that names none and no view" do
      rule("SELECT n.id FROM notes n")
      expect(read).to eq(%w[own])
      expect(rule("SELECT * FROM (SELECT * FROM notes) s").relation_secret?("notes")).to be(false)
    end

    it "reads the database a statement names, and holds a table of one name in both as one" do
      expect(rule("SELECT 1 FROM notes WHERE EXISTS (SELECT 1 FROM twin.notes)").of_relation("notes")).to eq(%w[api_token])
      expect(read).to eq(%w[own twin])
    end

    it "follows the view a statement names three databases deep, and judges it" do
      expect(rule("SELECT * FROM near").refused_view_in("select * from near"))
        .to eq([ "near", "it reads the view `v`: its definition names the secret column `door_token`" ])
      expect(read).to eq(%w[own d2 d3 d4])
    end

    it "refuses a statement that names a view which leads a fourth database deep, by the view" do
      expect { rule("SELECT * FROM far") }.to raise_error(
        described_class::Unreadable,
        "The view `far` leads through more databases than rails_query follows, so the secret columns it could read " \
        "cannot be told and no statement that names it runs."
      )
      expect { rule("SELECT * FROM d1.v") }.to raise_error(described_class::Unreadable, /\AThe view `v` leads through more databases/)
    end
  end

  describe ".for" do
    let(:conn) { ActiveRecord::Base.connection }
    let(:runtime) { RailsAiContext::DatabaseFamily::SqliteRuntime }

    # The app's connection as the connection of another of its databases: its pool answers that database's entry
    # and stays the real pool for the rest, so a reconnect inside an example still finds what it asks for.
    def as_database(name)
      pool = Class.new(SimpleDelegator) { attr_accessor :db_config }.new(conn.pool)
      pool.db_config = double(env_name: "test", name: name)
      allow(conn).to receive(:pool).and_return(pool)
      conn
    end

    let(:context) do
      {
        schema: { tables: {
          "widgets" => { columns: [ { name: "id" }, { name: "api_token" } ] },
          "ar_internal_metadata" => { columns: [ { name: "key" }, { name: "value" } ] }
        } },
        models: { "User" => { encrypts: %w[email] } }
      }
    end

    it "reads the family's view definitions and generated columns, once per run" do
      allow(runtime).to receive(:relation_columns).and_return("users" => %w[passwd])
      allow(runtime).to receive(:view_definitions).with(conn, %w[main temp]).and_return("people" => "SELECT passwd AS p FROM users")
      allow(runtime).to receive(:generated_columns).with(conn, %w[main temp]).and_return("users" => { "hidden" => "passwd" })

      RailsAiContext::RunCache.around do
        2.times do
          secrets = described_class.for(conn, context: context)
          expect(secrets.refused_view_in("SELECT * FROM people")&.first).to eq("people")
          expect(secrets.secret?("hidden")).to be(true)
        end
      end
      expect(runtime).to have_received(:view_definitions).once
      expect(runtime).to have_received(:generated_columns).once
    end

    it "names every view with no definition when the definitions cannot be read" do
      allow(RailsAiContext::DatabaseFamily::SqliteRuntime).to receive(:view_definitions).and_raise(ActiveRecord::StatementInvalid, "denied")
      allow(runtime).to receive(:relation_columns).and_return("users" => %w[passwd])
      allow(conn).to receive(:views).and_return(%w[people])

      expect(described_class.for(conn, context: context).refused_view_in("SELECT * FROM people")&.first).to eq("people")
    end

    it "reads a view's definition with its comments out, as the database runs it" do
      allow(runtime).to receive(:relation_columns).and_return("users" => %w[id passwd])
      allow(runtime).to receive(:view_definitions).and_return(
        "lined" => " SELECT -- note\n * FROM users", "blocked" => " SELECT /* note */ * FROM users", "plain" => " SELECT id -- passwd\n FROM users"
      )
      secrets = described_class.for(conn, context: context)

      expect(secrets.refused_view_in("SELECT * FROM lined")&.last).to start_with("its definition has a wildcard and names `users`")
      expect(secrets.refused_view_in("SELECT * FROM blocked")&.last).to start_with("its definition has a wildcard and names `users`")
      expect(secrets.refused_view_in("SELECT * FROM plain")).to be_nil
    end

    it "names a refused view, a table that is not read and a relation in a sentence as the database spells them" do
      secrets = described_class.new(relations: { "Hq_Users" => %w[id password_digest] },
                                    views: { "Hq  Odd View" => "SELECT id, password_digest AS s FROM Hq_Users", "Over It" => "SELECT s FROM `Hq  Odd View`" },
                                    index_tables: { "Raw_Pages" => [ :pages, nil ] })

      expect(secrets.refused_view_in("select s from `hq  odd view`")).to eq([ "Hq  Odd View", "its definition names the secret column `password_digest`" ])
      expect(secrets.refused_view_in("SELECT s FROM `over it`").last).to start_with("it reads the view `Hq  Odd View`: ")
      expect(secrets.unread_table_in("select data from raw_pages").first).to eq("Raw_Pages")
      expect(secrets.relation_named_in("select count(*) from hq_users")).to eq("Hq_Users")
    end

    it "reads the connection's schema once per run, however many checks ask" do
      allow(runtime).to receive(:relation_columns).and_return("users" => %w[api_token])
      RailsAiContext::RunCache.around do
        3.times do
          s = described_class.for(conn, context: context)
          s.named_in("select 1")
          s.of_relation("users")
          s.relation_secret?("posts")
          expect(s.in_schema).to eq(%w[api_token])
        end
      end
      expect(runtime).to have_received(:relation_columns).once
    end

    it "keeps one answer per database within a run" do
      allow(runtime).to receive_messages(unqualified_schemas: [], relation_columns: {}, view_definitions: {}, generated_columns: {}, index_tables: {})
      RailsAiContext::RunCache.around do
        primary = described_class.for(conn, context: context)
        expect(described_class.for(conn, context: context)).to be(primary)
        expect(described_class.for(as_database("queue"), context: context)).not_to be(primary)
      end
    end

    it "asks for every name a statement writes before a dot, in any quotes" do
      asked = []
      allow(runtime).to receive(:schemas_named) { |_conn, names| asked.concat(names) && [] }
      statement = %(SELECT a.id, `b``x`.id, "c""y".id, [d e].id, ünï$1.id, f  .id FROM t WHERE note = 'g.h' AND 1.5 > 0 AND `open)

      RailsAiContext::RunCache.around { described_class.for(conn, context: {}, statement: statement) }

      expect(asked).to include("a", "b`x", 'c"y', "ünï$1", "f", "g", "1")
      expect(asked).not_to include("id", "t", "note", "h", "5", "open", "d e", "e")
    end

    it "asks for a name that stands after a quote character written inside a string" do
      statements = {
        %(SELECT '"' AS q, v.id FROM far_one.v v WHERE '"' = '"') => "far_one",
        %(SELECT '`' AS q, id FROM `far_two`.`t`) => "far_two",
        %(SELECT 'a`b' AS q, id FROM `far_three`.t) => "far_three",
        %(SELECT '[' AS q, id FROM far_four.t WHERE ']' = ']') => "far_four",
        %(SELECT id FROM far_five.t WHERE '".c' <> 'x' AND '"' = '"') => "far_five",
        %(SELECT 'it''s [' AS q, id FROM far_six.t WHERE note <> ']') => "far_six",
        %(SELECT 'a"b' AS q, id FROM "far_seven".t) => "far_seven",
        %(SELECT '`' AS q, id FROM `far``eight`.t) => "far`eight",
        %(SELECT '`' AS q, id FROM ```far_nine`.t) => "`far_nine",
        %(SELECT '"' AS q, id FROM "far""ten"\n . t) => 'far"ten'
      }

      statements.each do |statement, name|
        asked = []
        allow(runtime).to receive(:schemas_named) { |_conn, names| asked.concat(names) && [] }
        RailsAiContext::RunCache.around { described_class.for(conn, context: {}, statement: statement) }

        expect(asked).to include(name), statement
      end
    end

    # A regexp over the whole text is quadratic on a Ruby with no match cache (before 3.2).
    it "reads those names in time that grows with the statement" do
      clock = Process.const_defined?(:CLOCK_PROCESS_CPUTIME_ID) ? Process::CLOCK_PROCESS_CPUTIME_ID : Process::CLOCK_MONOTONIC
      texts = [ "'#{"a" * 40_000}'", "`" * 40_001, "[a " * 13_000, "\"a " * 13_000, "'#{"é " * 20_000}'", "." * 40_000, "a ." * 13_000,
                "`a`." * 10_000, "\"\"." * 13_000, "`` a" * 10_000 + "`." ].map { |long| "SELECT #{long} FROM t WHERE t.id = 1" }
      allow(runtime).to receive(:schemas_named).and_return([])

      started = Process.clock_gettime(clock)
      texts.each { |text| RailsAiContext::RunCache.around { described_class.for(conn, context: {}, statement: text) } }

      expect(Process.clock_gettime(clock) - started).to be < 10
    end

    it "lists the schemas, reads the columns, the views and the generated columns in one statement each, and the virtual and shadow tables in two" do
      sent = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| sent << payload[:sql] }
      begin
        described_class.for(conn, context: {})
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # Rails before 7.2 asks the SQLite version here when no earlier example has.
      expect(sent.grep_v(/sqlite_version/).size).to eq(6)
      expect(runtime.relation_columns(conn)).to eq(conn.tables.sort.to_h { |table| [ table, conn.columns(table).map(&:name) ] })
    end

    it "raises a read the timeout ended, from the columns and from the view definitions, with no fallback" do
      stopped = ActiveRecord::QueryCanceled.new("canceling statement due to statement timeout")
      allow(conn).to receive(:views).and_raise("the views were listed")

      allow(runtime).to receive(:relation_columns).and_raise(stopped)
      expect { described_class.for(conn, context: context) }.to raise_error(ActiveRecord::QueryCanceled)

      allow(runtime).to receive(:relation_columns).and_return({})
      allow(runtime).to receive(:view_definitions).and_raise(stopped)
      expect { described_class.for(conn, context: context) }.to raise_error(ActiveRecord::QueryCanceled)
    end

    it "takes the encrypts columns from the context" do
      expect(described_class.for(conn, context: context).encrypted?("email")).to be(true)
    end

    it "falls back to the context's schema when the connection cannot be read, leaving bookkeeping tables out" do
      allow(runtime).to receive(:relation_columns).and_raise(ActiveRecord::StatementInvalid, "gone")
      secrets = described_class.for(conn, context: context)
      expect(secrets.of_relation("widgets")).to eq(%w[api_token])
      expect(secrets.relation_secret?("ar_internal_metadata")).to be(false)
      expect(secrets.named_in("select key from ar_internal_metadata")).to be_nil
    end

    it "raises for another database whose tables cannot be read, naming it, and reads no schema from the context" do
      allow(runtime).to receive(:relation_columns).and_raise(ActiveRecord::StatementInvalid, "gone")

      expect { described_class.for(as_database("queue"), context: context) }.to raise_error(
        described_class::Unreadable,
        "The columns of the queue database could not be read, so its secret columns cannot be told and no query runs on it."
      )
    end

    it "raises for the primary when neither the connection nor the context holds its tables" do
      allow(runtime).to receive(:relation_columns).and_raise(ActiveRecord::StatementInvalid, "gone")
      expect { described_class.for(conn, context: {}) }.to raise_error(described_class::Unreadable, /\AThe columns of the primary database/)
    end

    it "raises the same way when the generated columns, the virtual tables or the list of views cannot be read" do
      failed = ActiveRecord::StatementInvalid.new("SQLite3::IOException: disk I/O error")
      [ :generated_columns, :index_tables ].each do |read|
        allow(runtime).to receive(read).and_raise(failed)
        expect { described_class.for(conn, context: context) }.to raise_error(
          described_class::Unreadable, "The columns of the primary database could not be read, so its secret columns cannot be told and no query runs on it."
        ), read.to_s
        allow(runtime).to receive(read).and_call_original
      end
      allow(runtime).to receive(:view_definitions).and_raise(failed)
      allow(conn).to receive(:views).and_raise(failed)
      expect { described_class.for(conn, context: context) }.to raise_error(described_class::Unreadable, /\AThe columns of the primary database/)
    end

    it "raises for the primary when the connection cannot be read and the context's schema lists no table" do
      allow(runtime).to receive(:relation_columns).and_raise(ActiveRecord::StatementInvalid, "gone")
      expect { described_class.for(conn, context: { schema: { tables: {} } }) }
        .to raise_error(described_class::Unreadable, /\AThe columns of the primary database/)
    end

    it "raises a lost connection, from the columns and from the view definitions, with no fallback" do
      lost = [ ActiveRecord::ConnectionNotEstablished.new("server closed the connection") ]
      lost << ActiveRecord::ConnectionFailed.new("server has gone away") if defined?(ActiveRecord::ConnectionFailed)
      allow(conn).to receive(:views).and_raise("the views were listed")

      lost.each do |error|
        allow(runtime).to receive(:relation_columns).and_raise(error)
        expect { described_class.for(conn, context: context) }.to raise_error(error.class)
      end
      if defined?(ActiveRecord::ConnectionFailed)
        allow(runtime).to receive(:relation_columns).and_return({})
        allow(runtime).to receive(:view_definitions).and_raise(lost.last)
        expect { described_class.for(conn, context: context) }.to raise_error(ActiveRecord::ConnectionFailed)
      end
    end

    it "leaves bookkeeping tables out of a connection read" do
      allow(runtime).to receive(:relation_columns).and_return("users" => %w[id], "ar_internal_metadata" => %w[key])
      expect(described_class.for(conn, context: context).relation_secret?("ar_internal_metadata")).to be(false)
    end
  end
end
