# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetEngines do
  before { described_class.reset_cache! }

  let(:engines_data) do
    {
      mounted_engines: [
        { engine: "Sidekiq::Web", path: "/sidekiq", category: "admin", description: "Sidekiq background job dashboard" },
        { engine: "Blazer::Engine", path: "/blazer" }
      ],
      rails_engines: [
        { name: "Devise::Engine", root: "devise-4.9.3", route_count: 12, model_count: 0 },
        { name: "MyEngine", root: "engines/my_engine", model_count: 3 }
      ]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ engines: engines_data })
  end

  describe ".call" do
    it "lists mounted engines with paths, categories, and descriptions" do
      text = described_class.call.content.first[:text]
      expect(text).to include("# Engines")
      expect(text).to include("## Mounted (config/routes.rb)")
      expect(text).to include("**Sidekiq::Web** at `/sidekiq` (admin) - Sidekiq background job dashboard")
      expect(text).to include("**Blazer::Engine** at `/blazer`")
    end

    it "lists loaded engine classes with route and model counts" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## Loaded Engine Classes")
      expect(text).to include("**Devise::Engine** - 12 routes")
      expect(text).to include("**MyEngine** - 3 models")
    end

    context "with no engines at all" do
      before do
        allow(described_class).to receive(:cached_context)
          .and_return({ engines: { mounted_engines: [], rails_engines: [] } })
      end

      it "says so plainly in both sections" do
        text = described_class.call.content.first[:text]
        expect(text).to include("_No engines mounted in config/routes.rb._")
        expect(text).to include("_No loaded Rails::Engine subclasses detected._")
      end
    end

    context "when the introspector is not configured" do
      before { allow(described_class).to receive(:cached_context).and_return({}) }

      it "says how to enable it" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Add :engines to introspectors")
      end
    end

    context "when introspection failed" do
      before { allow(described_class).to receive(:cached_context).and_return({ engines: { error: "boom" } }) }

      it "reports the failure honestly" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Engine introspection failed: boom")
      end
    end

    context "when running in the static tier without route data" do
      before do
        allow(described_class).to receive(:cached_context)
          .and_return({ engines: { unavailable: "requires a booted Rails app" } })
      end

      it "renders the unavailable note" do
        text = described_class.call.content.first[:text]
        expect(text).to include("[UNAVAILABLE: requires a booted Rails app]")
      end
    end

    # Which engines a process loaded is unknowable without that process. The
    # empty array it used to return rendered as "no loaded Rails::Engine
    # subclasses detected" for an app that loads eight of them.
    context "when the loaded-engine list is unavailable but routes parsed" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          { engines: { mounted_engines: [], rails_engines: { unavailable: "requires a booted Rails app" } } }
        )
      end

      it "says the list is unavailable rather than empty" do
        text = described_class.call.content.first[:text]
        expect(text).to include("[UNAVAILABLE: requires a booted Rails app]")
        expect(text).not_to include("No loaded Rails::Engine subclasses detected")
      end

      it "still reports the mounted engines it read from routes" do
        text = described_class.call.content.first[:text]
        expect(text).to include("## Mounted (config/routes.rb)")
      end
    end
  end
end
