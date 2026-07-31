# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetAutoload do
  before { described_class.reset_cache! }

  let(:autoload_data) do
    {
      mode: "zeitwerk",
      zeitwerk_available: true,
      autoloaders: [
        { name: "main", tag: "main", collapsed: [ "app/models/concerns" ], ignored: [], root_dirs: [ "app/models" ] },
        { name: "once", tag: "once", collapsed: [], ignored: [], root_dirs: [] }
      ],
      autoload_paths: %w[app/models app/services lib],
      autoload_once_paths: %w[app/overrides],
      eager_load_paths: %w[app/models app/services],
      eager_load: false,
      custom_inflections: [
        { file: "config/initializers/inflections.rb", rule: "api => API" }
      ]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ autoload: autoload_data })
  end

  describe ".call" do
    it "reports mode and eager-load flag" do
      text = described_class.call.content.first[:text]
      expect(text).to include("# Autoloading")
      expect(text).to include("**Mode:** zeitwerk")
      expect(text).to include("**Eager load (this env):** false")
    end

    it "lists autoloaders with collapsed dirs" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## Autoloaders")
      expect(text).to include("**main** (tag: main)")
      expect(text).to include("collapsed: app/models/concerns")
    end

    it "surfaces per-loader extraction errors instead of hiding them" do
      autoload_data[:autoloaders] = [ { name: "main", error: "loader exploded" } ]
      text = described_class.call.content.first[:text]
      expect(text).to include("**main**")
      expect(text).to include("[error: loader exploded]")
    end

    it "lists the three path groups with counts" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## Autoload paths (3)")
      expect(text).to include("`app/services`")
      expect(text).to include("## Autoload-once paths (1)")
      expect(text).to include("`app/overrides`")
      expect(text).to include("## Eager-load paths (2)")
    end

    it "lists custom inflections" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## Custom Inflections")
      expect(text).to include("`api => API` (config/initializers/inflections.rb)")
    end

    context "when the introspector is not configured" do
      before { allow(described_class).to receive(:cached_context).and_return({}) }

      it "says how to enable it" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Add :autoload to introspectors")
      end
    end

    context "when introspection failed" do
      before { allow(described_class).to receive(:cached_context).and_return({ autoload: { error: "boom" } }) }

      it "reports the failure honestly" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Autoload introspection failed: boom")
      end
    end

    context "when running in the static tier" do
      before do
        allow(described_class).to receive(:cached_context)
          .and_return({ autoload: { unavailable: "requires a booted Rails app" } })
      end

      it "renders the unavailable note" do
        text = described_class.call.content.first[:text]
        expect(text).to include("[UNAVAILABLE: requires a booted Rails app]")
      end
    end
  end
end
