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
      expect(config.introspectors.size).to eq(40)
      expect(config.introspectors).to include(:stimulus, :database_stats, :views, :view_templates, :turbo, :auth, :api, :devops, :migrations, :seeds, :middleware, :engines, :env_config, :multi_database, :components, :performance, :frontend_frameworks)
      expect(config.introspectors).to include(:initializers, :autoload, :connection_pool, :active_support, :credentials, :security, :observability, :env)
    end

    it "accepts string preset names" do
      config.preset = "full"
      expect(config.introspectors.size).to eq(40)
    end

    it "raises on unknown preset" do
      expect { config.preset = :unknown }.to raise_error(ArgumentError, /Unknown preset/)
    end
  end

  # Every reader asks for :full or :cli by name, so an unknown value was kept
  # and read as the default without a word.
  describe "#context_mode= and #tool_mode=" do
    it "accepts each mode by symbol or by string" do
      config.context_mode = "full"
      config.tool_mode = "cli"
      expect([ config.context_mode, config.tool_mode ]).to eq(%i[full cli])
    end

    it "refuses an unknown mode and names the valid ones" do
      expect { config.context_mode = :huge }.to raise_error(ArgumentError, "context_mode must be compact or full (got huge)")
      expect { config.tool_mode = :both }.to raise_error(ArgumentError, "tool_mode must be mcp or cli (got both)")
      expect([ config.context_mode, config.tool_mode ]).to eq(%i[compact mcp])
    end
  end

  # A validating writer under an attr_accessor redefines the accessor's
  # writer, which `ruby -W` reports in every process that loads the gem.
  it "loads without redefining a method" do
    path = File.expand_path("../../../lib/rails_ai_context/configuration.rb", __dir__)
    _out, err, = Open3.capture3(RbConfig.ruby, "-W", "-e", "load ARGV[0]", path)
    expect(err).not_to include("method redefined")
  end

  describe "#claude_max_lines=" do
    # A budget of zero or less has no reading that produces a file, and the
    # renderer answered it with the whole file under a "trimmed" note.
    it "raises on zero and on a negative budget" do
      expect { config.claude_max_lines = 0 }.to raise_error(ArgumentError, /claude_max_lines must be positive/)
      expect { config.claude_max_lines = -5 }.to raise_error(ArgumentError, /claude_max_lines must be positive/)
    end

    it "coerces a numeric string the way the sibling budgets do" do
      config.claude_max_lines = "200"
      expect(config.claude_max_lines).to eq(200)
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

    # An inner block must not disarm the outer one for what follows it.
    it "keeps recording after a nested configure block returns" do
      RailsAiContext.configure do |c|
        RailsAiContext.configure { |inner| inner.server_name = "inner" }
        c.cache_ttl = 120
      end

      expect(RailsAiContext.configuration.block_assigned_keys).to include(:cache_ttl)
    ensure
      RailsAiContext.configuration = RailsAiContext::Configuration.new
    end
  end
end
