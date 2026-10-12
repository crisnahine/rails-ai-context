# frozen_string_literal: true

require "spec_helper"

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

    it "is false for ordinary columns" do
      %w[id email name status created_at user_id lock_version salt_length].each do |name|
        expect(secrets.secret?(name)).to be(false), name
      end
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

  describe ".for" do
    let(:conn) { ActiveRecord::Base.connection }
    let(:context) do
      {
        schema: { tables: {
          "widgets" => { columns: [ { name: "id" }, { name: "api_token" } ] },
          "ar_internal_metadata" => { columns: [ { name: "key" }, { name: "value" } ] }
        } },
        models: { "User" => { encrypts: %w[email] } }
      }
    end

    it "reads the connection's schema once per run, however many checks ask" do
      allow(conn).to receive(:tables).and_return(%w[users])
      allow(conn).to receive(:columns).with("users").and_return([ double(name: "api_token") ])
      RailsAiContext::RunCache.around do
        3.times do
          s = described_class.for(conn, context: context)
          s.named_in("select 1")
          s.of_relation("users")
          s.relation_secret?("posts")
          expect(s.in_schema).to eq(%w[api_token])
        end
      end
      expect(conn).to have_received(:columns).with("users").once
    end

    it "keeps one answer per database within a run" do
      other = conn.dup
      allow(other).to receive(:pool).and_return(double(db_config: double(env_name: "test", name: "queue")))
      allow(other).to receive(:tables).and_return([])
      RailsAiContext::RunCache.around do
        expect(described_class.for(conn, context: context)).to be(described_class.for(conn, context: context))
        expect(described_class.for(other, context: context)).not_to be(described_class.for(conn, context: context))
      end
    end

    it "takes the encrypts columns from the context" do
      expect(described_class.for(conn, context: context).encrypted?("email")).to be(true)
    end

    it "falls back to the context's schema when the connection cannot be read, leaving bookkeeping tables out" do
      allow(conn).to receive(:tables).and_raise(ActiveRecord::StatementInvalid, "gone")
      secrets = described_class.for(conn, context: context)
      expect(secrets.of_relation("widgets")).to eq(%w[api_token])
      expect(secrets.relation_secret?("ar_internal_metadata")).to be(false)
      expect(secrets.named_in("select key from ar_internal_metadata")).to be_nil
    end

    it "reads no schema from the context for another database whose tables cannot be read" do
      other = conn.dup
      allow(other).to receive(:pool).and_return(double(db_config: double(env_name: "test", name: "queue")))
      allow(other).to receive(:tables).and_raise(ActiveRecord::StatementInvalid, "gone")
      secrets = described_class.for(other, context: context)
      expect(secrets.of_relation("widgets")).to eq([])
      expect(secrets.in_schema).to eq([])
    end

    it "leaves bookkeeping tables out of a connection read" do
      allow(conn).to receive(:tables).and_return(%w[users ar_internal_metadata])
      allow(conn).to receive(:columns).with("users").and_return([ double(name: "id") ])
      allow(conn).to receive(:columns).with("ar_internal_metadata").and_return([ double(name: "key") ])
      expect(described_class.for(conn, context: context).relation_secret?("ar_internal_metadata")).to be(false)
    end
  end
end
