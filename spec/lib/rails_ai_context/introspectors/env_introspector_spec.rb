# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::EnvIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns a Hash without error" do
      expect(result).to be_a(Hash)
      expect(result).not_to have_key(:error)
    end

    it "returns set as array" do
      expect(result[:set]).to be_an(Array)
    end

    it "returns unset as array" do
      expect(result[:unset]).to be_an(Array)
    end

    it "returns referenced_in_code as array" do
      expect(result[:referenced_in_code]).to be_an(Array)
    end

    context "with variables Rails reads and two it does not" do
      names = %w[RAILS_EAGER_LOAD RAILS_EVENT_REPORTER SECRET_KEY_BASE_DUMMY RAILS_DEVELOPMENT_HOSTS
                 RAILS_GROUPS RAILS_CACHE_ID RAILS_APP_VERSION SOLID_QUEUE_IN_PUMA]

      around do |example|
        saved = names.to_h { |name| [ name, ENV[name] ] }
        names.each { |name| ENV[name] = "1" }
        example.run
      ensure
        saved.each { |name, value| ENV[name] = value }
      end

      it "lists only the ones Rails reads" do
        set = result[:set].map { |entry| entry[:name] }
        expect(set).to include(*names.drop(2))
        expect(set).not_to include("RAILS_EAGER_LOAD", "RAILS_EVENT_REPORTER")
      end
    end

    context "when RAILS_ENV is explicitly set" do
      before do
        @original = ENV["RAILS_ENV"]
        ENV["RAILS_ENV"] = "test"
      end

      after { ENV["RAILS_ENV"] = @original }

      it "lists RAILS_ENV as set with value (safe category)" do
        entry = result[:set].find { |e| e[:name] == "RAILS_ENV" }
        expect(entry).not_to be_nil
        expect(entry[:value]).to eq("test")
        expect(entry[:category]).to eq("core")
      end
    end

    context "when a sensitive ENV var is set" do
      before do
        @original = ENV["SECRET_KEY_BASE"]
        ENV["SECRET_KEY_BASE"] = "this-should-never-appear-in-output"
      end

      after { ENV["SECRET_KEY_BASE"] = @original }

      it "lists it as set but redacted, never revealing the value" do
        entry = result[:set].find { |e| e[:name] == "SECRET_KEY_BASE" }
        expect(entry).not_to be_nil
        expect(entry[:redacted]).to eq(true)
        expect(entry).not_to have_key(:value)
        expect(result.inspect).not_to include("this-should-never-appear-in-output")
      end
    end

    context "when a custom ENV var is referenced in code" do
      let(:fixture_path) { File.join(Rails.root, "config/initializers/custom_env.rb") }

      before do
        FileUtils.mkdir_p(File.dirname(fixture_path))
        File.write(fixture_path, <<~RUBY)
          MY_CUSTOM_FLAG = ENV["MY_SPECIAL_APP_FLAG"]
        RUBY
      end

      after { FileUtils.rm_f(fixture_path) }

      it "reports the custom var via scan_env_references" do
        entry = result[:referenced_in_code].find { |e| e[:name] == "MY_SPECIAL_APP_FLAG" }
        expect(entry).not_to be_nil
        expect(entry[:files]).to include("config/initializers/custom_env.rb")
        expect(entry[:set]).to eq(false)
      end
    end

    # rails_get_env and the context JSON answered one question two ways: the
    # introspector read config/database.yml's ERB, the tool did not.
    context "beside rails_get_env" do
      let(:db_path) { File.join(Rails.root, "config/database_pa_s.yml") }

      before do
        File.write(db_path, %(default:\n  host: <%= ENV["PA_S_DATABASE_HOST"] %>\n))
      end

      after { FileUtils.rm_f(db_path) }

      it "reads its names through the tool's own reader" do
        tool_names = RailsAiContext::Introspectors::EnvReferences.scan(Rails.root.to_s).values.flatten.map { |v| v[:name] }
        introspected = result[:referenced_in_code].map { |e| e[:name] }

        expect(tool_names).to include("PA_S_DATABASE_HOST")
        expect(introspected).to include("PA_S_DATABASE_HOST")
      end
    end

    # Huginn's DATABASE_HOST and friends are read in database.yml's ERB tags.
    context "when a YAML file reads ENV in its ERB tags" do
      let(:fixture_path) { File.join(Rails.root, "config/pa_q_database.yml") }

      before do
        File.write(fixture_path, <<~YAML)
          # host: <%= ENV["COMMENTED_OUT_HOST"] %>
          default:
            host: <%= ENV["PA_Q_DATABASE_HOST"] || "localhost" %>
            port: <%= ENV.fetch("PA_Q_DATABASE_PORT", 5432) %>
            socket: <%#= ENV["PA_Q_ERB_COMMENT"] %>
        YAML
      end

      after { FileUtils.rm_f(fixture_path) }

      it "reports the vars the tags read" do
        names = result[:referenced_in_code].map { |e| e[:name] }

        expect(names).to include("PA_Q_DATABASE_HOST", "PA_Q_DATABASE_PORT")
        expect(names).not_to include("PA_Q_ERB_COMMENT")
        entry = result[:referenced_in_code].find { |e| e[:name] == "PA_Q_DATABASE_HOST" }
        expect(entry[:files]).to include("config/pa_q_database.yml")
      end
    end
  end
end

# Canvas keeps 126MB of locale YAML, half of it spelling "ENV" as text, and
# the scan read and parsed every file: 11s of a static run for no answer.
RSpec.describe RailsAiContext::Introspectors::EnvReferences do
  it "reads no locale file and parses no YAML without an ERB tag" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config", "locales"))
      File.write(File.join(dir, "config", "locales", "en.yml"), "en:\n  env: \"ENV\"\n")
      File.write(File.join(dir, "config", "plain.yml"), "key: ENV_NAME\n")
      File.write(File.join(dir, "config", "database.yml"), "url: <%= ENV[\"DATABASE_URL\"] %>\n")
      read = []
      allow(RailsAiContext::SafeFile).to receive(:read).and_wrap_original do |original, path, *rest|
        read << File.basename(path.to_s)
        original.call(path, *rest)
      end
      allow(RailsAiContext::ErbSource).to receive(:ruby_in_place).and_call_original

      found = described_class.scan(dir)

      expect(found.values.flatten.map { |ref| ref[:name] }).to eq([ "DATABASE_URL" ])
      expect(read).not_to include("en.yml")
      expect(RailsAiContext::ErbSource).to have_received(:ruby_in_place).once
    end
  end
end
