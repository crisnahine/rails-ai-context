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
        { name: "Devise::Engine", root: "devise-4.9.3", route_count: 12, dynamic_route_count: 2, model_count: 0 },
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
      expect(text).to include("## Mounted Apps (config/routes.rb)")
      expect(text).to include("**Sidekiq::Web** at `/sidekiq` (admin) - Sidekiq background job dashboard")
      expect(text).to include("**Blazer::Engine** at `/blazer`")
    end

    it "names a mount with no known path without inventing one" do
      allow(described_class).to receive(:cached_context)
        .and_return({ engines: engines_data.merge(mounted_engines: [ { engine: "Sidekiq::Web", path: nil } ]) })

      text = described_class.call.content.first[:text]

      expect(text).to include("- **Sidekiq::Web**\n")
      expect(text).not_to include("at `")
    end

    # The count comes off the models section, not the engine's file list.
    it "names the app's own in-repo engines with the models the scan filed there" do
      allow(described_class).to receive(:cached_context).and_return({
        engines: engines_data.merge(in_repo_engines: [ { name: "budgets", path: "modules/budgets" } ]),
        models: {
          "Budget" => { file: "modules/budgets/app/models/budget.rb" },
          "Budget::Entry" => { file: "modules/budgets/app/models/budget/entry.rb" },
          "Post" => { file: "app/models/post.rb" }
        }
      })

      text = described_class.call.content.first[:text]

      expect(text).to include("## In-Repo Engines (1)")
      expect(text).to include("**budgets** at `modules/budgets` - 2 models")
    end

    it "prints 0 models rather than nothing for an engine the scan found none in" do
      allow(described_class).to receive(:cached_context).and_return({
        engines: engines_data.merge(in_repo_engines: [ { name: "web", path: "engines/web" } ]),
        models: { "Post" => { file: "app/models/post.rb" } }
      })

      expect(described_class.call.content.first[:text]).to include("**web** at `engines/web` - 0 models")
    end

    it "says the count is unavailable when the models section failed" do
      allow(described_class).to receive(:cached_context).and_return({
        engines: engines_data.merge(in_repo_engines: [ { name: "budgets", path: "modules/budgets" } ]),
        models: { error: "boom" }
      })

      text = described_class.call.content.first[:text]

      expect(text).to include("**budgets** at `modules/budgets` - model count unavailable")
      expect(text).not_to include("**budgets** at `modules/budgets` - 0 models")
    end

    it "leaves the in-repo section out when the app has none" do
      expect(described_class.call.content.first[:text]).not_to include("In-Repo Engines")
    end

    it "lists loaded engine classes with route and model counts" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## Loaded Engine Classes")
      expect(text).to include("**Devise::Engine** - 12 routes, 2 redirect or lambda routes")
      expect(text).to include("**MyEngine** - 3 models")
    end

    context "with no engines at all" do
      before do
        allow(described_class).to receive(:cached_context)
          .and_return({ engines: { mounted_engines: [], rails_engines: [] } })
      end

      it "says so plainly in both sections" do
        text = described_class.call.content.first[:text]
        expect(text).to include("_Nothing mounted in config/routes.rb._")
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
        expect(text).to include("## Mounted Apps (config/routes.rb)")
      end
    end
  end
end
