# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Configuration do
  let(:config) { described_class.new }

  it "has sensible defaults" do
    expect(config.server_name).to eq("rails-ai-context")
    expect(config.http_port).to eq(6029)
    expect(config.http_bind).to eq("127.0.0.1")
    expect(config.auto_mount).to eq(false)
    expect(config.cache_ttl).to eq(60)
    expect(config.context_mode).to eq(:compact)
    expect(config.claude_max_lines).to eq(150)
    expect(config.max_tool_response_chars).to eq(200_000)
    expect(config.live_reload).to eq(:auto)
    expect(config.live_reload_debounce).to eq(1.5)
    expect(config.anti_hallucination_rules).to eq(true)
    expect(config.hydration_enabled).to eq(true)
    expect(config.hydration_max_hints).to eq(5)
  end

  it "defaults to full preset" do
    expect(config.introspectors).to eq(described_class::PRESETS[:full])
  end

  it "excludes internal Rails models by default" do
    expect(config.excluded_models).to include("ApplicationRecord")
    expect(config.excluded_models).to include("ActiveStorage::Blob")
  end

  it "excludes framework association names by default" do
    expect(config.excluded_association_names).to include("active_storage_attachments")
    expect(config.excluded_association_names).to include("active_storage_blobs")
    expect(config.excluded_association_names).to include("rich_text_body")
    expect(config.excluded_association_names).to include("rich_text_content")
    expect(config.excluded_association_names).to include("action_mailbox_inbound_emails")
    expect(config.excluded_association_names).to include("noticed_events")
    expect(config.excluded_association_names).to include("noticed_notifications")
  end

  it "allows adding custom excluded association names" do
    config.excluded_association_names += %w[custom_assoc]
    expect(config.excluded_association_names).to include("custom_assoc")
    expect(config.excluded_association_names).to include("active_storage_attachments")
  end

  it "is configurable" do
    config.server_name = "my-app"
    config.http_port = 8080
    config.auto_mount = true

    expect(config.server_name).to eq("my-app")
    expect(config.http_port).to eq(8080)
    expect(config.auto_mount).to eq(true)
  end

  describe "#preset=" do
    it "sets introspectors to standard preset" do
      config.preset = :standard
      expect(config.introspectors).to eq(%i[schema models routes jobs gems conventions controllers tests migrations stimulus view_templates config components turbo auth performance i18n])
    end

    it "sets introspectors to full preset" do
      config.preset = :full
      expect(config.introspectors.size).to eq(39)
      expect(config.introspectors).to include(:stimulus, :database_stats, :views, :view_templates, :turbo, :auth, :api, :devops, :migrations, :seeds, :middleware, :engines, :multi_database, :components, :performance, :frontend_frameworks)
      expect(config.introspectors).to include(:initializers, :autoload, :connection_pool, :active_support, :credentials, :security, :observability, :env)
    end

    it "accepts string preset names" do
      config.preset = "full"
      expect(config.introspectors.size).to eq(39)
    end

    it "raises on unknown preset" do
      expect { config.preset = :unknown }.to raise_error(ArgumentError, /Unknown preset/)
    end

    it "allows adding introspectors after preset" do
      config.preset = :standard
      config.introspectors += %i[views devops]
      expect(config.introspectors).to include(:views, :devops)
      expect(config.introspectors.size).to eq(19)
    end
  end

  describe RailsAiContext do
    it "supports block configuration" do
      RailsAiContext.configure do |c|
        c.server_name = "test-app"
      end

      expect(RailsAiContext.configuration.server_name).to eq("test-app")
    ensure
      # Reset
      RailsAiContext.configuration = RailsAiContext::Configuration.new
    end
  end
end
