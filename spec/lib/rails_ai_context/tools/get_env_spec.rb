# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Tools::GetEnv do
  before { described_class.reset_cache! }

  let(:root) { Rails.root.to_s }

  # Simulate env_vars as returned by scan_env_vars: { file_path => [{ name:, line:, default: }] }
  let(:env_vars) do
    {
      "#{root}/config/initializers/ruby_llm.rb" => [
        { name: "GEMINI_API_KEY", line: 3 },
        { name: "OPENAI_API_KEY", line: 5 }
      ],
      "#{root}/app/clients/gmail.rb" => [
        { name: "IMAP_ADDRESS", line: 10 },
        { name: "MAIL_ADDRESS", line: 11 },
        { name: "MAIL_PASSWORD", line: 12 }
      ],
      "#{root}/config/puma.rb" => [
        { name: "PORT", line: 1, default: "3000" },
        { name: "WEB_CONCURRENCY", line: 5 },
        { name: "RAILS_MAX_THREADS", line: 8, default: "5" }
      ],
      "#{root}/config/environments/production.rb" => [
        { name: "OTEL_EXPORTER_OTLP_ENDPOINT", line: 42 },
        { name: "RAILS_LOG_LEVEL", line: 15 }
      ],
      "#{root}/app/services/push_notification_service.rb" => [
        { name: "WEB_PUSH_VAPID_EXPIRATION_SECONDS", line: 7 }
      ],
      "#{root}/config/initializers/youtube.rb" => [
        { name: "YOUTUBE_API_KEY", line: 2 }
      ],
      "#{root}/config/boot.rb" => [
        { name: "BUNDLE_GEMFILE", line: 1 }
      ]
    }
  end

  let(:env_example) { [] }
  let(:dockerfile_vars) { [] }
  let(:external_services) { [] }
  let(:credentials_keys) { [] }
  let(:encrypted_columns) { {} }

  before do
    allow(described_class).to receive(:scan_env_vars).and_return(env_vars)
    allow(described_class).to receive(:scan_env_example).and_return(env_example)
    allow(described_class).to receive(:scan_dockerfile).and_return(dockerfile_vars)
    allow(described_class).to receive(:detect_external_services).and_return(external_services)
    allow(described_class).to receive(:detect_credentials_keys).and_return(credentials_keys)
    allow(described_class).to receive(:detect_encrypted_columns).and_return(encrypted_columns)
  end

  # Three files read one variable three ways: a nil-defaulting fetch, a real
  # fallback, and a fetch with no default that raises KeyError when the
  # variable is unset. One label for all three said the variable is optional.
  describe "a variable whose call sites disagree about the default" do
    let(:env_vars) do
      {
        "#{root}/app/services/billing/audit_log.rb" => [ { name: "SITE_URL", line: 4, default: "nil" } ],
        "#{root}/app/services/billing/mailer_link.rb" => [ { name: "SITE_URL", line: 4, default: "https://example.com" } ],
        "#{root}/app/services/billing/oauth_link.rb" => [ { name: "SITE_URL", line: 4 } ]
      }
    end

    it "does not label the variable with one site's default" do
      text = described_class.call.content.first[:text]

      expect(text).to include("`SITE_URL`")
      expect(text).not_to include("SITE_URL` (default: `nil`)")
      expect(text).to include("defaults differ")
    end

    it "names each site's default in full detail" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("app/services/billing/audit_log.rb:4 default: `nil`")
      expect(text).to include("app/services/billing/mailer_link.rb:4 default: `https://example.com`")
      expect(text).to include("app/services/billing/oauth_link.rb:4 no default")
    end

    it "keeps the single label when every site agrees" do
      allow(described_class).to receive(:scan_env_vars).and_return(
        "#{root}/a.rb" => [ { name: "PORT", line: 1, default: "3000" } ],
        "#{root}/b.rb" => [ { name: "PORT", line: 2, default: "3000" } ]
      )

      text = described_class.call.content.first[:text]

      expect(text).to include("`PORT` (default: `3000`)")
      expect(text).not_to include("defaults differ")
    end
  end

  # A fetch whose fallback is an expression has a default all the same: it
  # never raises, so labelling it "no default" named the wrong site as the
  # one that raises KeyError.
  describe "a fetch whose fallback is an expression" do
    let(:env_vars) do
      {
        "#{root}/config/puma.rb" => RailsAiContext::Introspectors::EnvReferences.references(%(port ENV.fetch("PORT", defaults[:port])\n)),
        "#{root}/config/web.rb" => RailsAiContext::Introspectors::EnvReferences.references(%(ENV.fetch("PORT", "3000")\n)),
        "#{root}/config/strict.rb" => RailsAiContext::Introspectors::EnvReferences.references(%(ENV.fetch("PORT")\n))
      }
    end

    it "says the site has a default it cannot print" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("config/puma.rb:1 default computed at runtime")
      expect(text).to include("config/web.rb:1 default: `3000`")
      expect(text).to include("config/strict.rb:1 no default")
    end

    # A bracket read returns nil when the variable is unset and never raises,
    # which is the one thing "no default" is there to warn about.
    it "tells a bracket read from a fetch that raises" do
      allow(described_class).to receive(:scan_env_vars).and_return(
        "#{root}/config/web.rb" => RailsAiContext::Introspectors::EnvReferences.references(%(ENV.fetch("PORT", "3000")\n)),
        "#{root}/config/strict.rb" => RailsAiContext::Introspectors::EnvReferences.references(%(ENV.fetch("PORT")\n)),
        "#{root}/config/loose.rb" => RailsAiContext::Introspectors::EnvReferences.references(%(ENV["PORT"]\n))
      )

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("config/strict.rb:1 no default")
      expect(text).to include("config/loose.rb:1 nil when unset")
    end

    # Neither raises and both answer nil, so they agree.
    it "does not call a bracket read and a nil fetch a disagreement" do
      allow(described_class).to receive(:scan_env_vars).and_return(
        "#{root}/config/a.rb" => RailsAiContext::Introspectors::EnvReferences.references(%(ENV["SITE"]\n)),
        "#{root}/config/b.rb" => RailsAiContext::Introspectors::EnvReferences.references(%(ENV.fetch("SITE", nil)\n))
      )

      expect(described_class.call.content.first[:text]).not_to include("defaults differ")
      expect(described_class.call(detail: "full").content.first[:text]).not_to include("defaults differ")
    end

    it "prints no default when that is every site's" do
      allow(described_class).to receive(:scan_env_vars).and_return(
        "#{root}/config/puma.rb" => RailsAiContext::Introspectors::EnvReferences.references(%(ENV.fetch("PORT", defaults[:port])\n))
      )

      text = described_class.call.content.first[:text]

      expect(text).to include("- `PORT`\n")
      expect(text).not_to include("computed")
    end
  end

  describe "categorize_env_var" do
    it "categorizes API key variables" do
      result = described_class.send(:categorize_env_var, "GEMINI_API_KEY")
      expect(result).to eq("API Keys & Secrets")
    end

    it "categorizes SECRET variables" do
      result = described_class.send(:categorize_env_var, "RAILS_SECRET_KEY_BASE")
      expect(result).to eq("API Keys & Secrets")
    end

    it "categorizes TOKEN variables" do
      result = described_class.send(:categorize_env_var, "AUTH_TOKEN")
      expect(result).to eq("API Keys & Secrets")
    end

    it "categorizes MAIL variables" do
      result = described_class.send(:categorize_env_var, "MAIL_ADDRESS")
      expect(result).to eq("Mail")
    end

    it "categorizes IMAP variables" do
      result = described_class.send(:categorize_env_var, "IMAP_ADDRESS")
      expect(result).to eq("Mail")
    end

    it "categorizes SMTP variables" do
      result = described_class.send(:categorize_env_var, "SMTP_HOST")
      expect(result).to eq("Mail")
    end

    it "categorizes DATABASE variables" do
      result = described_class.send(:categorize_env_var, "DATABASE_URL")
      expect(result).to eq("Database")
    end

    it "categorizes REDIS variables" do
      result = described_class.send(:categorize_env_var, "REDIS_URL")
      expect(result).to eq("Database")
    end

    it "categorizes PORT variables" do
      result = described_class.send(:categorize_env_var, "PORT")
      expect(result).to eq("Infrastructure")
    end

    it "categorizes CONCURRENCY variables" do
      result = described_class.send(:categorize_env_var, "WEB_CONCURRENCY")
      expect(result).to eq("Infrastructure")
    end

    it "categorizes THREADS variables" do
      result = described_class.send(:categorize_env_var, "RAILS_MAX_THREADS")
      expect(result).to eq("Infrastructure")
    end

    it "categorizes QUEUE variables" do
      result = described_class.send(:categorize_env_var, "SOLID_QUEUE_IN_PUMA")
      expect(result).to eq("Infrastructure")
    end

    it "categorizes PIDFILE variables" do
      result = described_class.send(:categorize_env_var, "PIDFILE")
      expect(result).to eq("Infrastructure")
    end

    it "categorizes OTEL variables" do
      result = described_class.send(:categorize_env_var, "OTEL_EXPORTER_OTLP_ENDPOINT")
      expect(result).to eq("Monitoring")
    end

    it "categorizes SENTRY variables" do
      result = described_class.send(:categorize_env_var, "SENTRY_DSN")
      expect(result).to eq("Monitoring")
    end

    it "categorizes DATADOG variables" do
      result = described_class.send(:categorize_env_var, "DATADOG_API_KEY")
      # API_KEY pattern takes precedence
      expect(result).to eq("API Keys & Secrets")
    end

    it "categorizes APPSIGNAL variables" do
      result = described_class.send(:categorize_env_var, "APPSIGNAL_PUSH_KEY")
      # Monitoring pattern (APPSIGNAL) takes precedence over Push (PUSH)
      expect(result).to eq("Monitoring")
    end

    it "categorizes VAPID variables" do
      result = described_class.send(:categorize_env_var, "WEB_PUSH_VAPID_EXPIRATION_SECONDS")
      expect(result).to eq("Push Notifications")
    end

    it "categorizes FCM variables" do
      result = described_class.send(:categorize_env_var, "FCM_SERVER_KEY")
      expect(result).to eq("Push Notifications")
    end

    it "categorizes unknown variables as Other" do
      result = described_class.send(:categorize_env_var, "BUNDLE_GEMFILE")
      expect(result).to eq("Other")
    end

    it "categorizes CI as Other" do
      result = described_class.send(:categorize_env_var, "CI")
      expect(result).to eq("Other")
    end
  end

  describe ".call" do
    context "with detail:summary" do
      it "groups env vars by category" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]

        expect(text).to include("## API Keys & Secrets")
        expect(text).to include("## Mail")
        expect(text).to include("## Infrastructure")
        expect(text).to include("## Monitoring")
        expect(text).to include("## Push Notifications")
        expect(text).to include("## Other")
      end

      it "places API key vars under API Keys & Secrets" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]

        api_section = text.split("## API Keys & Secrets").last.split("##").first
        expect(api_section).to include("`GEMINI_API_KEY`")
        expect(api_section).to include("`OPENAI_API_KEY`")
        expect(api_section).to include("`YOUTUBE_API_KEY`")
      end

      it "places mail vars under Mail" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]

        mail_section = text.split("## Mail").last.split("##").first
        expect(mail_section).to include("`IMAP_ADDRESS`")
        expect(mail_section).to include("`MAIL_ADDRESS`")
        expect(mail_section).to include("`MAIL_PASSWORD`")
      end

      it "shows environment variable count" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]

        expect(text).to include("**Environment variables:**")
      end
    end

    context "with detail:standard" do
      it "groups env vars by category with defaults" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("## API Keys & Secrets")
        expect(text).to include("## Infrastructure")
        expect(text).to include("`PORT` (default: `3000`)")
      end

      it "places infrastructure vars correctly" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        infra_section = text.split("## Infrastructure").last.split("##").first
        expect(infra_section).to include("`PORT`")
        expect(infra_section).to include("`WEB_CONCURRENCY`")
        expect(infra_section).to include("`RAILS_MAX_THREADS`")
      end
    end

    context "with detail:full" do
      it "uses category grouping instead of file grouping" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("## Environment Variables by Category")
        expect(text).not_to include("## Environment Variables by File")
      end

      it "groups vars by category with file annotations" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("### API Keys & Secrets")
        expect(text).to include("### Mail")
        expect(text).to include("### Infrastructure")
        expect(text).to include("### Monitoring")
        expect(text).to include("### Push Notifications")
        expect(text).to include("### Other")
      end

      it "includes file locations as annotations" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("config/initializers/ruby_llm.rb")
        expect(text).to include("app/clients/gmail.rb")
        expect(text).to include("config/puma.rb")
      end

      it "includes line numbers in file annotations" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("config/initializers/ruby_llm.rb:3")
        expect(text).to include("config/puma.rb:1")
      end

      it "includes default values" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("`PORT` (default: `3000`)")
        expect(text).to include("`RAILS_MAX_THREADS` (default: `5`)")
      end

      it "places API keys under API Keys & Secrets section" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        api_section = text.split("### API Keys & Secrets").last.split("###").first
        expect(api_section).to include("`GEMINI_API_KEY`")
        expect(api_section).to include("`OPENAI_API_KEY`")
        expect(api_section).to include("`YOUTUBE_API_KEY`")
      end

      it "places monitoring vars under Monitoring section" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        monitoring_section = text.split("### Monitoring").last.split("###").first
        expect(monitoring_section).to include("`OTEL_EXPORTER_OTLP_ENDPOINT`")
      end

      it "places push vars under Push Notifications section" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        push_section = text.split("### Push Notifications").last.split("###").first
        expect(push_section).to include("`WEB_PUSH_VAPID_EXPIRATION_SECONDS`")
      end

      it "orders categories consistently" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        api_pos = text.index("### API Keys & Secrets")
        mail_pos = text.index("### Mail")
        infra_pos = text.index("### Infrastructure")
        monitoring_pos = text.index("### Monitoring")
        push_pos = text.index("### Push Notifications")
        other_pos = text.index("### Other")

        expect(api_pos).to be < mail_pos
        expect(mail_pos).to be < infra_pos
        expect(infra_pos).to be < monitoring_pos
        expect(monitoring_pos).to be < push_pos
        expect(push_pos).to be < other_pos
      end
    end

    context "when no env vars are found" do
      let(:env_vars) { {} }

      it "returns a helpful message" do
        result = described_class.call
        text = result.content.first[:text]

        expect(text).to include("No environment variables")
      end
    end

    context "with unknown detail level" do
      it "reads an invalid detail level as the default, and says so" do
        text = described_class.call(detail: "verbose").content.first[:text]

        expect(text).to start_with(described_class.call(detail: "standard").content.first[:text])
        expect(text).to include("verbose")
        expect(text).to include("not a valid `detail`")
      end
    end
  end
  # Rails 6+ apps commonly carry only per-environment credentials. Checking
  # for the top-level file alone left those apps with the section silently
  # absent - the "no credentials" vs "could not open them" confusion again.
  describe "credentials file detection" do
    it "counts a per-environment credentials file" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "credentials"))
        File.write(File.join(dir, "config", "credentials", "production.yml.enc"), "x")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        expect(described_class.send(:credentials_file_present?)).to be(true)
      end
    end

    it "is false when the app has no credentials at all" do
      Dir.mktmpdir do |dir|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        expect(described_class.send(:credentials_file_present?)).to be(false)
      end
    end
  end

  describe ".scan_env_vars" do
    let(:tmpdir) { Dir.mktmpdir }

    before do
      # The outer stub replaces the very method under test here.
      allow(described_class).to receive(:scan_env_vars).and_call_original
      FileUtils.mkdir_p(File.join(tmpdir, "lib"))
      allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(1_000_000)
    end

    after { FileUtils.remove_entry(tmpdir) }

    def scan(source, name: "redis_configuration.rb")
      File.write(File.join(tmpdir, "lib", name), source)
      described_class.send(:scan_env_vars, tmpdir).values.flatten
    end

    it "does not report an interpolated name as a variable" do
      vars = scan(<<~RUBY)
        class RedisConfiguration
          def setup(prefix, defaults)
            url  = ENV.fetch("\#{prefix}URL", nil)
            port = ENV.fetch("\#{prefix}PORT", defaults[:port])
            db   = ENV["\#{prefix}DB"]
            [ url, port, db ]
          end
        end
      RUBY

      expect(vars).to be_empty
    end

    it "still reports a plain literal name beside an interpolated one" do
      vars = scan(<<~RUBY)
        class RedisConfiguration
          def setup(prefix)
            [ ENV.fetch("\#{prefix}URL", nil), ENV.fetch("REDIS_URL", nil) ]
          end
        end
      RUBY

      expect(vars.map { |v| v[:name] }).to eq(%w[REDIS_URL])
    end

    it "keeps a literal default" do
      vars = scan(%{PORT = ENV.fetch("PORT", "3000")\n})
      expect(vars.first).to include(name: "PORT", default: "3000")
    end

    # database.yml, newrelic.yml, a rake task and a view all read ENV, and
    # none of their names reached the answer someone writes a .env.example
    # from.
    it "reads ENV out of an ERB yml, a rake task and a view" do
      FileUtils.mkdir_p(File.join(tmpdir, "config"))
      FileUtils.mkdir_p(File.join(tmpdir, "lib", "tasks"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "views", "probes"))
      File.write(File.join(tmpdir, "config", "cache.yml"), <<~YAML)
        default: &default
          pool: <%= ENV.fetch("CACHE_MAX_THREADS") { 10 } %>
          url: <%= ENV['CACHE_DATABASE_URL'] %>
      YAML
      File.write(File.join(tmpdir, "lib", "tasks", "probe.rake"), <<~RUBY)
        task probe: :environment do
          puts ENV["RAKE_ONLY_VAR"]
        end
      RUBY
      File.write(File.join(tmpdir, "app", "views", "probes", "show.html.erb"),
                 %(<p><%= ENV["VIEW_ONLY_VAR"] %></p>\n))

      names = described_class.send(:scan_env_vars, tmpdir).values.flatten.map { |v| v[:name] }

      expect(names).to include("CACHE_MAX_THREADS", "CACHE_DATABASE_URL",
                               "RAKE_ONLY_VAR", "VIEW_ONLY_VAR")
    end

    # config/database.yml is on `sensitive_patterns` for its values. The ENV
    # names in its ERB tags are not values, and Huginn's DATABASE_HOST is only
    # there, so the names are read and nothing else is.
    it "reads only the ENV names in a sensitive config file's ERB tags" do
      FileUtils.mkdir_p(File.join(tmpdir, "config"))
      File.write(File.join(tmpdir, "config", "database.yml"), <<~YAML)
        production:
          host: <%= ENV["DATABASE_HOST"] %>
          password: <%= ENV.fetch("DB_PASSWORD", "hunter2") %>
          username: literal_user
      YAML

      vars = described_class.send(:scan_env_vars, tmpdir).values.flatten

      expect(vars.map { |v| v[:name] }).to contain_exactly("DATABASE_HOST", "DB_PASSWORD")
      expect(vars.to_s).not_to include("hunter2")
      expect(vars.to_s).not_to include("literal_user")
    end

    # A default read only as a name is unknown, so it cannot be named as
    # the variable's, and its site says so beside the one that was read.
    it "does not fold a default it did not read under another site's" do
      FileUtils.mkdir_p(File.join(tmpdir, "config", "initializers"))
      File.write(File.join(tmpdir, "config", "database.yml"), %(production:\n  port: <%= ENV.fetch("PA_W_DB_PORT", "5432") %>\n))
      File.write(File.join(tmpdir, "config", "initializers", "envs.rb"), %(PORT = ENV.fetch("PA_W_DB_PORT", "6000")\n))
      env_vars = described_class.send(:scan_env_vars, tmpdir)
      allow(described_class).to receive(:scan_env_vars).and_return(env_vars)
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmpdir)))

      standard = described_class.call(detail: "standard").content.first[:text]
      full = described_class.call(detail: "full").content.first[:text]

      expect(standard).not_to include("(default: `6000`)")
      expect(standard).to include("defaults differ")
      expect(full).not_to include("(default: `6000`)")
      expect(full).to include("config/database.yml:2 default not read").and include("config/initializers/envs.rb:1 default: `6000`")
      expect(full).not_to include("5432")
    end

    # "no default" says the line raises KeyError; this one has a default the
    # scan never read.
    it "labels a site whose default it did not read as unread in full detail" do
      FileUtils.mkdir_p(File.join(tmpdir, "config", "initializers"))
      File.write(File.join(tmpdir, "config", "database.yml"), %(production:\n  host: <%= ENV.fetch("PA_U_DBX_HOST", "db.internal") %>\n))
      File.write(File.join(tmpdir, "config", "initializers", "db.rb"), %(A = ENV.fetch("PA_U_DBX_HOST")\nB = ENV.fetch("PA_U_DBX_HOST", "other")\n))
      env_vars = described_class.send(:scan_env_vars, tmpdir)
      allow(described_class).to receive(:scan_env_vars).and_return(env_vars)
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmpdir)))

      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("config/database.yml:2 default not read")
      expect(text).not_to include("config/database.yml:2 no default")
      expect(text).not_to include("db.internal")
    end

    it "never opens a sensitive file that is not config YAML" do
      File.write(File.join(tmpdir, ".env"), %(SECRET=<%= ENV["NOT_READ"] %>\n))
      FileUtils.mkdir_p(File.join(tmpdir, "config"))
      File.write(File.join(tmpdir, "config", "master.key"), %(<%= ENV["ALSO_NOT_READ"] %>\n))

      names = described_class.send(:scan_env_vars, tmpdir).values.flatten.map { |v| v[:name] }

      expect(names).to be_empty
    end

    it "reports the line the yml file reads it on" do
      FileUtils.mkdir_p(File.join(tmpdir, "config"))
      File.write(File.join(tmpdir, "config", "newrelic.yml"), <<~YAML)
        common: &default_settings
          app_name: probe
          license_key: <%= ENV["NEWRELIC_ONLY_VAR"] %>
      YAML

      entry = described_class.send(:scan_env_vars, tmpdir).values.flatten.first

      expect(entry).to include(name: "NEWRELIC_ONLY_VAR", line: 3)
    end

    it "does not print a Ruby expression where a default value belongs" do
      vars = scan(%{PORT = ENV.fetch("PORT", defaults[:port])\n})
      expect(vars.first[:name]).to eq("PORT")
      expect(vars.first[:default]).to eq(described_class::COMPUTED_DEFAULT)
    end

    it "does not print a method call as a default" do
      vars = scan(%{PW = ENV.fetch("REDIS_PASSWORD", default_password)\n})
      expect(vars.first[:default]).to eq(described_class::COMPUTED_DEFAULT)
    end

    it "ignores an ENV reference that only appears in a comment" do
      vars = scan(%{# ENV["LEGACY_TOKEN"] was removed\nX = ENV.fetch("REAL_TOKEN", nil)\n})
      expect(vars.map { |v| v[:name] }).to eq(%w[REAL_TOKEN])
    end

    it "ignores a trailing comment on a line that also reads ENV" do
      vars = scan(%{X = ENV.fetch("REAL_TOKEN", nil) # ENV["LEGACY_TOKEN"] is gone\n})
      expect(vars.map { |v| v[:name] }).to eq(%w[REAL_TOKEN])
    end

    it "still reports a lowercase literal name" do
      vars = scan(%(x = ENV["port"]\n))
      expect(vars.map { |v| v[:name] }).to eq(%w[port])
    end

    it "reports a single-character name" do
      vars = scan(%(x = ENV["X"]\n))
      expect(vars.map { |v| v[:name] }).to eq(%w[X])
    end

    it "skips an empty name" do
      vars = scan(%(x = ENV[""]\n))
      expect(vars).to be_empty
    end

    it "records the line the reference sits on" do
      vars = scan(%{\n\nX = ENV.fetch("REAL_TOKEN", nil)\n})
      expect(vars.first[:line]).to eq(3)
    end
  end

  describe "Dockerfile values" do
    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "Dockerfile"), <<~DOCKER)
          FROM ruby:3.3
          ENV RAILS_ENV=production
          ENV SECRET_KEY_BASE=0123456789abcdef0123456789abcdef0123456789abcdef
          ARG NPM_TOKEN=npm_abcdefghijklmnopqrstuvwxyz0123456789
        DOCKER
        @root = dir
        example.run
      end
    end

    before do
      allow(described_class).to receive(:scan_env_vars).and_call_original
      allow(described_class).to receive(:scan_dockerfile).and_call_original
    end

    it "never prints a Dockerfile value that is a credential" do
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(@root)))
      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("`ENV` `RAILS_ENV` = `production`")
      expect(text).to include("`ENV` `SECRET_KEY_BASE` = `[FILTERED]`")
      expect(text).to include("`ARG` `NPM_TOKEN` = `[FILTERED]`")
      expect(text).not_to include("0123456789abcdef")
      expect(text).not_to include("npm_abc")
    end
  end

  describe "Dockerfile ENV written across continuation lines" do
    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "Dockerfile"), <<~DOCKER)
          FROM ruby:3.3
          ARG TZ="Etc/UTC"
          # Runtime environment
          ENV \\
            BIND="0.0.0.0" \\
            NODE_ENV="production" \\
            MALLOC_CONF="narenas:2,background_thread:true" \\
            SIDEKIQ_READY_FILENAME=sidekiq_started
          ENV RAILS_ENV=production TZ="${TZ}"
          ENV LEGACY_FORM legacy value
        DOCKER
        @root = dir
        example.run
      end
    end

    before do
      allow(described_class).to receive(:scan_env_vars).and_call_original
      allow(described_class).to receive(:scan_dockerfile).and_call_original
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(@root)))
    end

    it "lists every variable of a continued ENV instruction with its value" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("`ENV` `BIND` = `0.0.0.0`")
      expect(text).to include("`ENV` `NODE_ENV` = `production`")
      expect(text).to include("`ENV` `MALLOC_CONF` = `narenas:2,background_thread:true`")
      expect(text).to include("`ENV` `SIDEKIQ_READY_FILENAME` = `sidekiq_started`")
    end

    it "splits a multi-assignment ENV into one row per variable" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("`ENV` `RAILS_ENV` = `production`")
      expect(text).to include("`ENV` `TZ` = `${TZ}`")
    end

    it "still reads the legacy space-separated ENV form" do
      text = described_class.call(detail: "full").content.first[:text]

      expect(text).to include("`ENV` `LEGACY_FORM` = `legacy value`")
    end

    it "counts continued ENV names among the app's environment variables" do
      text = described_class.call(detail: "summary").content.first[:text]

      expect(text).to include("`BIND`")
      expect(text).to include("`MALLOC_CONF`")
    end
  end

  # The static model builder never mapped `encrypts`, so this section was
  # silently absent from every --no-boot answer with no marker.
  describe "encrypted model columns from a static payload" do
    it "lists them for a model parsed without booting" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "keypair.rb"), <<~RUBY)
          class Keypair < ApplicationRecord
            encrypts :private_key
          end
        RUBY
        File.write(File.join(dir, ".env.example"), "SECRET_KEY_BASE=\n")

        app = RailsAiContext::StaticApp.new(dir)
        models = RailsAiContext::Introspectors::ModelIntrospector.new(app).static_call
        allow(described_class).to receive(:detect_encrypted_columns).and_call_original
        allow(described_class).to receive(:cached_context).and_return({ models: models })
        allow(described_class).to receive(:rails_app).and_return(app)

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("## Encrypted Model Columns")
        expect(text).to include("**Keypair:** private_key")
      end
    end
  end

  # The per-service env var list is a filter over the names the parser already
  # found, so a name only a raw text scan would have matched is not reported.
  describe "external service env vars" do
    it "lists the scanned names carrying the service prefix" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile"), "gem \"stripe\"\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:detect_external_services).and_call_original

        services = described_class.send(
          :detect_external_services, dir, %w[STRIPE_SECRET_KEY STRIPE_PUBLISHABLE_KEY DATABASE_URL]
        )

        expect(services.first[:name]).to eq("Stripe")
        expect(services.first[:env_vars]).to eq(%w[STRIPE_PUBLISHABLE_KEY STRIPE_SECRET_KEY])
      end
    end
  end

  describe "HTTP clients in the forms their docs use" do
    it "detects URI(...), Faraday.get and a client kept in lib/" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/clients"))
        FileUtils.mkdir_p(File.join(dir, "lib/clients"))
        File.write(File.join(dir, "app/clients/probe_client.rb"), <<~RUBY)
          class ProbeClient
            def a = Faraday.new(url: "https://api.alpha.example")
            def b = Net::HTTP.get(URI.parse("https://api.beta.example/x"))
            def c = Net::HTTP.get(URI("https://api.gamma.example/x"))
            def d = Faraday.get("https://api.delta.example/x")
            def e = HTTParty.get("https://api.epsilon.example/x")
          end
        RUBY
        File.write(File.join(dir, "lib/clients/zeta_client.rb"), <<~RUBY)
          class ZetaClient
            def a = Faraday.new(url: "https://api.zeta.example")
          end
        RUBY
        allow(described_class).to receive(:detect_external_services).and_call_original

        services = described_class.send(:detect_external_services, dir, [])

        expect(services.map { |s| s[:name] }).to contain_exactly(*%w[Alpha Beta Gamma Delta Epsilon Zeta])
        expect(services.find { |s| s[:name] == "Zeta" }[:file]).to eq("lib/clients/zeta_client.rb")
      end
    end
  end

  describe "HTTP clients beyond Faraday, Net::HTTP and HTTParty, and hosts that are not names" do
    it "detects RestClient, http.rb, Excon, Typhoeus, URI.open and a Net::HTTP host argument, and skips a local or private IP" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/clients"))
        FileUtils.mkdir_p(File.join(dir, "config/initializers"))
        File.write(File.join(dir, "app/clients/sibling_client.rb"), <<~RUBY)
          class SiblingClient
            def c = RestClient.get("https://api.kappa.example/x")
            def d = HTTP.get("https://api.lambda.example/x")
            def g = Excon.get("https://api.xi.example")
            def h = Net::HTTP.start("api.omicron.example", 443) { }
            def i = URI.open("https://api.pi.example/feed")
            def j = Typhoeus.get("https://api.rho.example/x")
            def k = Net::HTTP.get(URI("http://10.0.0.5:9200/x"))
            def l = Net::HTTP.get(URI("http://8.8.8.8/x"))
            def m = Net::HTTP.get(URI("http://0.0.0.0:3000/x"))
            def n = URI.open("report.pdf")
            def o = HTTP.get("index.html")
            # response = Net::HTTP.start('api.commented.example', :use_ssl => true)
          end
        RUBY
        File.write(File.join(dir, "config/initializers/health.rb"), 'HEALTH = -> { Net::HTTP.get(URI("http://127.0.0.1:9200/_cluster/health")) }' + "\n")
        allow(described_class).to receive(:detect_external_services).and_call_original

        services = described_class.send(:detect_external_services, dir, [])

        expect(services.map { |s| s[:name] }).to contain_exactly(*%w[Kappa Lambda Xi Omicron Pi Rho 8.8.8.8])
      end
    end
  end

  describe "an HTTP client named only in a trailing comment or a string" do
    it "is not a service the app calls" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/services"))
        File.write(File.join(dir, "app/services/x.rb"), <<~RUBY)
          class X
            def a = run # was HTTParty.get("https://api.oldvendor.com/v1")
            def b = "Use Faraday.get('https://docs.example.org') to test"
            def c = ::Faraday.get("https://api.kept.example/x")
          end
        RUBY
        allow(described_class).to receive(:detect_external_services).and_call_original

        names = described_class.send(:detect_external_services, dir, []).map { |s| s[:name] }

        expect(names).to eq(%w[Kept])
      end
    end
  end

  describe "a service the Gemfile only names in a comment" do
    it "is not detected" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile"), "gem \"stripe\"\n# gem \"twilio-ruby\"\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:detect_external_services).and_call_original

        names = described_class.send(:detect_external_services, dir, []).map { |s| s[:name] }

        expect(names).to include("Stripe")
        expect(names).not_to include("Twilio")
      end
    end
  end

  describe "credentials the booted app decrypts" do
    def credentials_in(dir, content = nil)
      key_path = File.join(dir, "development.key")
      File.write(key_path, ActiveSupport::EncryptedConfiguration.generate_key) if content
      config = ActiveSupport::EncryptedConfiguration.new(
        config_path: File.join(dir, "development.yml.enc"), key_path: key_path, env_key: "RAC_SPEC_NO_KEY", raise_if_missing_key: false
      )
      config.write(content) if content
      config
    end

    before do
      allow(described_class).to receive(:detect_credentials_keys).and_call_original
      allow(described_class).to receive(:credentials_file_present?).and_return(true)
    end

    it "says the file holds no keys when it decrypts to nothing" do
      Dir.mktmpdir do |dir|
        allow(Rails.application).to receive(:credentials).and_return(credentials_in(dir, ""))

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("## Credentials Keys (values hidden)", "decrypts and holds no keys")
        expect(text).not_to include("needs a booted app")
      end
    end

    it "still says it cannot read them when the key is missing" do
      Dir.mktmpdir do |dir|
        credentials_in(dir, "a: 1\n")
        File.delete(File.join(dir, "development.key"))
        allow(Rails.application).to receive(:credentials).and_return(credentials_in(dir))

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("needs a booted app with its master key")
      end
    end
  end

  describe "credentials and encrypted-columns trailer" do
    let(:credentials_keys) { %w[secret_key_base aws/access_key_id] }
    let(:encrypted_columns) { { "Keypair" => %w[private_key] } }

    it "reads the same at standard and full" do
      trailer = lambda do |detail|
        text = described_class.call(detail: detail).content.first[:text]
        text[text.index("## Credentials Keys (values hidden)")..]
      end

      expect(trailer.call("standard")).to eq(<<~TEXT.chomp)
        ## Credentials Keys (values hidden)
        - `secret_key_base`
        - `aws/access_key_id`

        ## Encrypted Model Columns
        - **Keypair:** private_key

        #{described_class::SCAN_NOTE}
      TEXT
      expect(trailer.call("full")).to eq(trailer.call("standard"))
    end
  end

  describe "category order across detail levels" do
    it "keeps Infrastructure ahead of Monitoring at standard and summary" do
      %w[standard summary].each do |detail|
        text = described_class.call(detail: detail).content.first[:text]

        expect(text.index("## Infrastructure")).to be < text.index("## Monitoring")
      end
    end
  end

  describe "Kamal's config/deploy.yml env" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = dir
        example.run
      end
    end

    before do
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(@root)))
      FileUtils.mkdir_p(File.join(@root, "config"))
    end

    def write_deploy(yaml)
      File.write(File.join(@root, "config", "deploy.yml"), yaml)
    end

    it "lists the secret names and the clear values it sets, at every detail level" do
      write_deploy(<<~YAML)
        service: app
        env:
          secret:
            - RAILS_MASTER_KEY
            - DB_PASSWORD:MAIN_DB_PASSWORD
          clear:
            SOLID_QUEUE_IN_PUMA: true
            <% if true %>
            JOB_CONCURRENCY: 3
            <% end %>
      YAML

      text = described_class.call.content.first[:text]
      expect(text).to include("## Set by Kamal (`config/deploy.yml`)")
      expect(text).to include("- `RAILS_MASTER_KEY` - secret, from `.kamal/secrets`")
      expect(text).to include("- `DB_PASSWORD` - secret, from `.kamal/secrets` (`MAIN_DB_PASSWORD`)")
      expect(text).to include("- `SOLID_QUEUE_IN_PUMA` = `true`")
      expect(text).to include("- `JOB_CONCURRENCY` = `3`")
      expect(described_class.call(detail: "full").content.first[:text]).to include("- `RAILS_MASTER_KEY` - secret, from `.kamal/secrets`")
      expect(described_class.call(detail: "summary").content.first[:text]).to include("- `RAILS_MASTER_KEY`")
    end

    it "reads an env hash with no clear or secret key as clear values, and redacts a secret-looking one" do
      write_deploy("env:\n  DATABASE_HOST: db1\n  API_TOKEN: Zx9kQ2mW7pL4vB8nR3tY6uH1\n")

      text = described_class.call.content.first[:text]
      expect(text).to include("- `DATABASE_HOST` = `db1`")
      expect(text).not_to include("Zx9kQ2mW7pL4vB8nR3tY6uH1")
    end

    it "says an ERB tag sets a clear value at deploy time, never printing it as empty" do
      write_deploy("env:\n  clear:\n    RAILS_LOG_LEVEL: <%= ENV.fetch(\"LOG_LEVEL\", \"info\") %>\n    HOST: app-<%= ENV[\"N\"] %>\n")

      text = described_class.call.content.first[:text]
      expect(text).to include("- `RAILS_LOG_LEVEL` - set by ERB at deploy time")
      expect(text).to include("- `HOST` - set by ERB at deploy time")
      expect(text).not_to include("= ``")
      expect(text).not_to include("RAC_ERB_OUTPUT")
    end

    it "hides a clear value that holds a URL or an opaque token, unless the name is on the safe list" do
      write_deploy(<<~YAML)
        env:
          clear:
            SLACK_WEBHOOK: https://hooks.slack.com/services/T000/B000/XXXXsecretXXXX
            SENTRY_DSN: https://abc123def@o1.ingest.sentry.io/1
            OPAQUE: a8f3k29dk3ls02kd93ks
            RAILS_RELATIVE_URL_ROOT: /app
            WEB_CONCURRENCY: 2
      YAML

      text = described_class.call.content.first[:text]
      expect(text).to include("- `SLACK_WEBHOOK` - value hidden")
      expect(text).to include("- `SENTRY_DSN` - value hidden")
      expect(text).to include("- `OPAQUE` - value hidden")
      expect(text).to include("- `RAILS_RELATIVE_URL_ROOT` = `/app`")
      expect(text).to include("- `WEB_CONCURRENCY` = `2`")
      expect(text).not_to include("XXXXsecretXXXX")
      expect(text).not_to include("abc123def")
    end

    it "lists the env a role and a tag add, and names the destination files it did not read" do
      write_deploy(<<~YAML)
        servers:
          web:
            - 1.1.1.1
          job:
            hosts:
              - 1.1.1.2: eu
            env:
              clear:
                JOB_CONCURRENCY: 5
              secret:
                - JOB_TOKEN
        env:
          clear:
            WEB_CONCURRENCY: 2
          tags:
            eu:
              REGION: eu
      YAML
      File.write(File.join(@root, "config", "deploy.staging.yml"), "env:\n  clear:\n    STAGE: 1\n")

      text = described_class.call.content.first[:text]
      expect(text).to include("- `WEB_CONCURRENCY` = `2`")
      expect(text).to include("- `JOB_CONCURRENCY` = `5` (role `job`)")
      expect(text).to include("- `JOB_TOKEN` - secret, from `.kamal/secrets` (role `job`)")
      expect(text).to include("- `REGION` = `eu` (tag `eu`)")
      expect(text).to include("`config/deploy.staging.yml` merges over this per destination and is not read")
      expect(described_class.call(detail: "summary").content.first[:text]).to include("- `JOB_TOKEN`")
    end

    it "says an ERB tag names a variable, never printing the placeholder as its name" do
      write_deploy("env:\n  clear:\n    <%= ENV.fetch(\"DYN_NAME\", \"X\") %>: abc\n  secret:\n    - <%= ENV[\"S\"] %>\n    - DB_PASSWORD:<%= ENV[\"P\"] %>\n")

      %w[summary standard full].each do |detail|
        expect(described_class.call(detail: detail).content.first[:text]).not_to include("RAC_ERB_OUTPUT")
      end
      text = described_class.call.content.first[:text]
      expect(text).to include("- a variable whose name an ERB tag sets at deploy time")
      expect(text).to include("- a secret whose name an ERB tag sets at deploy time")
      expect(text).to include("- `DB_PASSWORD` - secret, from `.kamal/secrets` (a name an ERB tag sets)")
    end

    it "shows a hyphenated host or bucket name, and still hides a long hex key" do
      write_deploy("env:\n  clear:\n    DB_HOST: myapp-production-db-1\n    S3_BUCKET: myapp-assets-2024\n    HEXKEY: 0123456789abcdef0123456789abcdef\n")

      text = described_class.call.content.first[:text]
      expect(text).to include("- `DB_HOST` = `myapp-production-db-1`")
      expect(text).to include("- `S3_BUCKET` = `myapp-assets-2024`")
      expect(text).to include("- `HEXKEY` - value hidden")
    end

    it "adds nothing for a deploy file that is not valid YAML or has no env" do
      write_deploy("env: [unclosed\n")
      expect(described_class.call.content.first[:text]).not_to include("Set by Kamal")

      write_deploy("service: app\n")
      expect(described_class.call.content.first[:text]).not_to include("Set by Kamal")
    end
  end

  describe "an app whose config/boot.rb points Bundler outside its git repository" do
    it "says the gem-based answers did not read that bundle, at every detail level" do
      Dir.mktmpdir do |engine|
        File.write(File.join(engine, "Gemfile"), %(gem "stripe"\n))
        dummy = File.join(engine, "test/dummy")
        FileUtils.mkdir_p(File.join(dummy, "config"))
        File.write(File.join(dummy, "config/boot.rb"), %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)\n))
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dummy)))

        note = "Gem-based services and config gem settings not read: config/boot.rb points Bundler at `../../Gemfile`, outside the app's git repository."
        %w[summary standard full].each do |detail|
          expect(described_class.call(detail: detail).content.first[:text]).to include(note)
        end
      end
    end
  end

  describe "config gem settings and Anyway::Config classes" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = dir
        example.run
      end
    end

    before do
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(@root)))
    end

    def write(rel, body)
      path = File.join(@root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    it "lists the setting keys each file gives and each config class's attributes with their env names, never a value" do
      write("Gemfile.lock", "GEM\n  remote: https://rubygems.org/\n  specs:\n    config (5.5.1)\n\nDEPENDENCIES\n  config\n")
      write("config/settings.yml", "payments:\n  provider: stripe\n  timeout: 30\n")
      write("config/settings/production.yml", "payments:\n  timeout: 10\n")
      write("config/settings.local.yml", "payments:\n  secret: shh\n")
      write("config/configs/payment_config.rb", <<~RUBY)
        class PaymentConfig < Anyway::Config
          attr_config :api_key, timeout: 30
          required :api_key
        end
      RUBY
      write("app/configs/geo_config.rb", <<~RUBY)
        class GeoConfig < ApplicationConfig
          env_prefix :maps
          attr_config :token
        end
      RUBY

      %w[standard full].each do |detail|
        text = described_class.call(detail: detail).content.first[:text]
        expect(text).to include("## Settings (config gem, read as `Settings.<key>`; values hidden)")
        expect(text).to include("- `config/settings.yml`: `payments.provider`, `payments.timeout`")
        expect(text).to include("- `config/settings/production.yml`: `payments.timeout`")
        expect(text).not_to include("settings.local.yml")
        expect(text).to include("## Anyway::Config classes (values hidden)")
        expect(text).to include("- `PaymentConfig` (`config/configs/payment_config.rb`): `api_key` (`PAYMENT_API_KEY`, required), `timeout` (`PAYMENT_TIMEOUT`)")
        expect(text).to include("- `GeoConfig` (`app/configs/geo_config.rb`): `token` (`MAPS_TOKEN`)")
        expect(text).not_to include("stripe")
      end
    end

    it "lists no settings when the bundle has no config gem, since no Settings constant exists" do
      write("Gemfile.lock", "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.1.0)\n\nDEPENDENCIES\n  rails\n")
      write("config/settings.yml", "payments:\n  provider: stripe\n")

      %w[standard full].each do |detail|
        expect(described_class.call(detail: detail).content.first[:text]).not_to include("Settings")
      end
    end

    it "adds nothing for a settings file that is not YAML or a config file that does not parse" do
      write("config/settings.yml", "payments: [unclosed\n")
      write("config/configs/bad_config.rb", "class BadConfig < Anyway::Config\n  attr_config (((\n")

      text = described_class.call.content.first[:text]
      expect(text).not_to include("config/settings.yml")
    end
  end

  describe ".scan_env_example" do
    before { allow(described_class).to receive(:scan_env_example).and_call_original }

    it "contributes nothing for a file over the size cap" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".env.example"), "API_KEY=abc\n")
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(2)

        expect(described_class.send(:scan_env_example, dir)).to be_empty
      end
    end

    it "contributes nothing when no example file exists" do
      Dir.mktmpdir do |dir|
        expect(described_class.send(:scan_env_example, dir)).to be_empty
      end
    end
  end
end
