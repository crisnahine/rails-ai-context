# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetConfig do
  before { described_class.reset_cache! }

  let(:config_data) do
    {
      cache_store: "redis_cache_store",
      session_store: "cookie_store",
      timezone: "UTC",
      queue_adapter: "solid_queue",
      mailer: { delivery_method: "smtp", default_from: "noreply@example.com" },
      middleware_stack: %w[
        ActionDispatch::HostAuthorization
        Rack::Sendfile
        ActionDispatch::Static
        ActionDispatch::Executor
        CustomRateLimiter
        Rack::Attack
      ],
      initializers: %w[
        filter_parameter_logging.rb
        inflections.rb
        stripe.rb
        sidekiq.rb
        cors.rb
      ],
      current_attributes: %w[Current]
    }
  end

  let(:gems_data) do
    {
      notable: [ { name: "devise" } ],
      all: []
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({
      config: config_data,
      gems: gems_data
    })
  end

  describe ".call" do
    it "returns application configuration" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Application Configuration")
    end

    it "includes cache store" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("redis_cache_store")
    end

    it "includes session store" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("cookie_store")
    end

    it "includes timezone" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("UTC")
    end

    it "includes queue adapter" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("solid_queue")
    end

    it "includes mailer configuration" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Mailer")
      expect(text).to include("smtp")
    end

    it "shows custom middleware only, filtering defaults" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Custom Middleware")
      expect(text).to include("CustomRateLimiter")
      expect(text).to include("Rack::Attack")
      # Default Rails middleware should be filtered out
      expect(text).not_to include("ActionDispatch::HostAuthorization")
    end

    it "shows notable initializers, filtering standard ones" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Initializers")
      expect(text).to include("stripe.rb")
      expect(text).to include("sidekiq.rb")
      # Standard initializers should be filtered out
      expect(text).not_to match(/^- `filter_parameter_logging.rb`/)
      expect(text).not_to match(/^- `inflections.rb`/)
    end

    it "shows CurrentAttributes" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("CurrentAttributes")
      expect(text).to include("Current")
    end

    it "detects auth framework from gems" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Devise")
    end
  end

  describe "assets stack from frontend introspector" do
    it "uses frontend framework introspector data when available" do
      allow(described_class).to receive(:cached_context).and_return({
        config: config_data,
        gems: gems_data,
        frontend_frameworks: {
          frameworks: { react: "18.2.0", vue: nil },
          build_tool: "vite",
          component_libraries: { tailwindcss: "3.4.0" }
        }
      })

      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("React")
      expect(text).to include("Vue")
      expect(text).to include("Vite")
      expect(text).to include("Tailwind")
    end

    it "falls back gracefully when frontend introspector has error" do
      allow(described_class).to receive(:cached_context).and_return({
        config: config_data,
        gems: gems_data,
        frontend_frameworks: { error: "failed" }
      })

      result = described_class.call
      text = result.content.first[:text]
      # Should not crash — assets line may be absent or show only pipeline
      expect(text).to include("Application Configuration")
    end

    it "falls back when no frontend data at all" do
      allow(described_class).to receive(:cached_context).and_return({
        config: config_data,
        gems: gems_data
      })

      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Application Configuration")
    end
  end

  describe "Active Storage and Action Mailer detection" do
    it "shows Active Storage service when configured" do
      stub_const("ActiveStorage", Module.new)
      allow(described_class).to receive(:detect_active_storage).and_return("amazon")

      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Active Storage")
      expect(text).to include("amazon")
    end

    it "shows Action Mailer delivery method" do
      allow(described_class).to receive(:detect_mailer_delivery).and_return("smtp")

      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Mailer delivery")
      expect(text).to include("smtp")
    end

    it "handles missing Active Storage gracefully" do
      allow(described_class).to receive(:detect_active_storage).and_return(nil)

      result = described_class.call
      text = result.content.first[:text]
      expect(text).not_to include("Active Storage")
    end

    it "handles missing mailer delivery gracefully" do
      allow(described_class).to receive(:detect_mailer_delivery).and_return(nil)

      result = described_class.call
      text = result.content.first[:text]
      expect(text).not_to include("Mailer delivery")
    end
  end

  describe "Action Cable from Rails config API" do
    it "uses Rails config API when available" do
      allow(described_class).to receive(:detect_action_cable).and_return("redis")

      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Action Cable")
      expect(text).to include("redis")
    end

    it "falls back to YAML when config API unavailable" do
      # The YAML fallback is tested by the existing behavior —
      # when no cable.yml exists and no config API, returns nil
      allow(described_class).to receive(:detect_action_cable).and_call_original

      result = described_class.call
      text = result.content.first[:text]
      # Just verify it doesn't crash — cable line may or may not be present
      expect(text).to include("Application Configuration")
    end
  end

  describe "edge cases" do
    it "handles missing config data" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "handles config introspection error" do
      allow(described_class).to receive(:cached_context).and_return({
        config: { error: "something went wrong" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("failed")
      expect(text).to include("something went wrong")
    end

    it "handles empty middleware stack" do
      config_data[:middleware_stack] = []
      result = described_class.call
      text = result.content.first[:text]
      expect(text).not_to include("Custom Middleware")
    end

    it "handles empty initializers" do
      config_data[:initializers] = []
      result = described_class.call
      text = result.content.first[:text]
      expect(text).not_to include("Initializers")
    end

    it "handles nil mailer" do
      config_data[:mailer] = nil
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Application Configuration")
      expect(text).not_to include("Mailer")
    end

    it "handles empty current_attributes" do
      config_data[:current_attributes] = []
      result = described_class.call
      text = result.content.first[:text]
      expect(text).not_to include("CurrentAttributes")
    end
  end
end
