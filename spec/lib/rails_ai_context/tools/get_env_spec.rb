# frozen_string_literal: true

require "spec_helper"

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

    context "with unknown detail level" do      it "reads an invalid detail level as the default, and says so" do
        text = described_class.call(detail: "verbose").content.first[:text]

        expect(text).to start_with(described_class.call(detail: "standard").content.first[:text])
        expect(text).to include("verbose")
        expect(text).to include("not a valid `detail`")
      end
    end
  end
end
