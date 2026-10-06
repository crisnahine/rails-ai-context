# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetEnvConfig do
  before { described_class.reset_cache! }

  let(:env_config_data) do
    {
      current: "development",
      count: 2,
      environments: [
        {
          name: "development",
          file: "config/environments/development.rb",
          config_keys: %w[cache_store eager_load],
          notable: { "eager_load" => "false", "cache_store" => ":memory_store" }
        },
        {
          name: "production",
          file: "config/environments/production.rb",
          config_keys: %w[force_ssl eager_load log_level],
          notable: { "force_ssl" => "true", "eager_load" => "true", "log_level" => ":info" }
        }
      ]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ env_config: env_config_data })
  end

  describe ".call" do
    it "renders the current environment and file count" do
      text = described_class.call.content.first[:text]
      expect(text).to include("# Environments")
      expect(text).to include("_Current: **development** - 2 environment files")
    end

    it "renders notable toggles per environment" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## production")
      expect(text).to include("- **force_ssl:** `true`")
      expect(text).to include("- **log_level:** `:info`")
    end

    it "renders config key lists" do
      text = described_class.call.content.first[:text]
      expect(text).to include("**Config keys set (2):** `cache_store`, `eager_load`")
    end

    context "with a config-key page" do
      let(:env_config_data) do
        {
          current: "production",
          count: 1,
          environments: [
            {
              name: "production",
              file: "config/environments/production.rb",
              config_keys: (1..120).map { |i| "key_#{format('%03d', i)}" },
              notable: {}
            }
          ]
        }
      end

      it "caps the keys shown and says how many there are" do
        text = described_class.call.content.first[:text]
        expect(text).to include("**Config keys set (120):**")
        expect(text).to include("`key_001`")
        expect(text).to include("`key_050`")
        expect(text).not_to include("`key_051`")
      end

      it "points at the next page" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Showing 1-50 of 120")
        expect(text).to include("offset:50")
      end

      it "honors offset and limit" do
        text = described_class.call(offset: 100, limit: 5).content.first[:text]
        expect(text).to include("`key_101`")
        expect(text).to include("`key_105`")
        expect(text).not_to include("`key_106`")
      end

      it "pages within a filtered environment" do
        text = described_class.call(environment: "production", offset: 60, limit: 2).content.first[:text]
        expect(text).to include("`key_061`, `key_062`")
        expect(text).not_to include("`key_063`")
      end
    end

    context "with an environment filter" do
      it "shows only the matching environment" do
        text = described_class.call(environment: "production").content.first[:text]
        expect(text).to include("## production")
        expect(text).not_to include("## development")
      end

      # An app can have both `production` and `production_replica`; a
      # substring hit answered an abbreviation with whichever is shortest.
      it "does not answer an abbreviation with a whole environment" do
        text = described_class.call(environment: "prod").content.first[:text]

        expect(text).to include("Environment 'prod' not found.")
        expect(text).to include("Did you mean 'production'?")
        expect(text).not_to include("## production\n")
      end

      it "returns not-found for an unknown environment" do
        text = described_class.call(environment: "qa").content.first[:text]
        expect(text).to include("Environment 'qa' not found.")
        expect(text).to include("Available: development, production")
      end
    end

    context "when no environment files exist" do
      before do
        allow(described_class).to receive(:cached_context)
          .and_return({ env_config: { current: "development", count: 0, environments: [] } })
      end

      it "says so plainly" do
        text = described_class.call.content.first[:text]
        expect(text).to include("_No environment files found._")
      end
    end

    context "when the introspector is not configured" do
      before { allow(described_class).to receive(:cached_context).and_return({}) }

      it "says how to enable it" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Add :env_config to introspectors")
      end
    end

    context "when introspection failed" do
      before { allow(described_class).to receive(:cached_context).and_return({ env_config: { error: "boom" } }) }

      it "reports the failure honestly" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Environment config introspection failed: boom")
      end
    end
  end

  describe "config/application.rb" do
    let(:application) do
      { file: "config/application.rb", config_keys: %w[active_job.queue_name_prefix payment x.payments.provider],
        config_for: [ { key: "payment", call: ":payment", file: "config/payment.yml", keys: %w[currency key] },
                      { key: "mail", call: ":mail", file: "config/mail.yml", missing: true },
                      { key: "x.stripe", call: 'Rails.root.join(dir, "x.yml")', path_unread: true },
                      { key: "redis", call: ":redis", file: "config/redis.yml", withheld: true },
                      { key: "up", call: ":up", file: "../up.yml", outside: true },
                      { key: "big", call: ":big", file: "config/big.yml", too_large: true },
                      { key: "dyn", call: ":dyn", file: "config/dyn.yml", keys: %w[host], erb_keys: 2 } ] }
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({ env_config: env_config_data.merge(application: application) })
    end

    it "lists what every environment runs, before the environment files, even for one environment" do
      [ described_class.call, described_class.call(environment: "production") ].each do |response|
        text = response.content.first[:text]
        expect(text).to include("## Every environment\n_config/application.rb_")
        expect(text).to include("**Config keys set (3):** `active_job.queue_name_prefix`, `payment`, `x.payments.provider`")
        expect(text).to include("- `payment` = config_for(:payment), `config/payment.yml` keys for development: currency, key")
        expect(text).to include("- `mail` = config_for(:mail), `config/mail.yml` does not exist")
        expect(text).to include("- `x.stripe` = config_for(Rails.root.join(dir, \"x.yml\")), keys not read: its path is not a literal")
        expect(text).to include("- `redis` = config_for(:redis), `config/redis.yml` on sensitive_patterns, keys not read")
        expect(text).to include("- `up` = config_for(:up), `../up.yml` outside the app, not read")
        expect(text).to include("- `big` = config_for(:big), `config/big.yml` over max_file_size, keys not read")
        expect(text).to include("- `dyn` = config_for(:dyn), `config/dyn.yml` keys for development: host, and 2 named by an ERB tag")
        expect(text.index("## Every environment")).to be < text.index("## production")
      end
    end
  end
end
