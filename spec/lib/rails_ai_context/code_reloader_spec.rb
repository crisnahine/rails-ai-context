# frozen_string_literal: true

require "spec_helper"

# Invalidating the gem's caches is only half of staying fresh. A long-lived
# process (the MCP server, `watch`) keeps whatever Rails autoloaded at boot:
# Zeitwerk's eager_load_dir is idempotent, so a model file written after boot is
# never picked up, and the server answers "that model does not exist" about a
# file the caller just wrote. Routes escaped this because RouteIntrospector
# calls routes_reloader.execute_if_updated; nothing did the equivalent for code.
RSpec.describe RailsAiContext::CodeReloader do
  describe ".reloadable?" do
    it "is false in the static tier, where there is no app to reload" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      expect(described_class.reloadable?).to be(false)
    end

    it "is false when the app eager loads, because nothing is reloadable then" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(false)
      allow(Rails.application.config).to receive(:eager_load).and_return(true)
      expect(described_class.reloadable?).to be(false)
    end

    it "is true for a booted app that does not eager load" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(false)
      allow(Rails.application.config).to receive(:eager_load).and_return(false)
      expect(described_class.reloadable?).to be(true)
    end
  end

  describe ".reload!" do
    it "asks Rails to reload and reports that it did" do
      allow(described_class).to receive(:reloadable?).and_return(true)
      expect(Rails.application.reloader).to receive(:reload!)
      expect(described_class.reload!).to be(true)
    end

    it "does nothing when the app is not reloadable" do
      allow(described_class).to receive(:reloadable?).and_return(false)
      expect(Rails.application.reloader).not_to receive(:reload!)
      expect(described_class.reload!).to be(false)
    end

    # A reload failure must not take down a running MCP server: the caller
    # falls back to the previously loaded constants, which is stale but alive.
    it "survives a reloader that raises" do
      allow(described_class).to receive(:reloadable?).and_return(true)
      allow(Rails.application.reloader).to receive(:reload!).and_raise(NameError, "boom")
      expect { expect(described_class.reload!).to be(false) }.not_to raise_error
    end

    it "survives a reloader that raises a ScriptError" do
      allow(described_class).to receive(:reloadable?).and_return(true)
      allow(Rails.application.reloader).to receive(:reload!).and_raise(SyntaxError, "bad file")
      expect { expect(described_class.reload!).to be(false) }.not_to raise_error
    end
  end
end
