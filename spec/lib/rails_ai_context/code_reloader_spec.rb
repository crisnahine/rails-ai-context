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

    # eager_load is the wrong flag. With enable_reloading off, Rails registers
    # no class_unload callback, so reload! reloads nothing however eager_load
    # is set - and this app is exactly that shape (eager_load false,
    # enable_reloading false), which is why gating on eager_load reported a
    # reload that never happened.
    it "is false when reloading is disabled, whatever eager_load says" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(false)
      allow(Rails.application.config).to receive(:eager_load).and_return(false)
      allow(Rails.application.config).to receive(:enable_reloading).and_return(false)
      expect(described_class.reloadable?).to be(false)
    end

    it "is true when reloading is enabled" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(false)
      allow(Rails.application.config).to receive(:enable_reloading).and_return(true)
      expect(described_class.reloadable?).to be(true)
    end

    it "agrees with Zeitwerk about whether this app can reload" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(false)
      expect(described_class.reloadable?).to eq(Rails.autoloaders.main.reloading_enabled?)
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
  describe ".with_app_code" do
    it "runs the block exactly once when reloading is possible" do
      allow(described_class).to receive(:reloadable?).and_return(true)
      runs = 0
      described_class.with_app_code { runs += 1 }
      expect(runs).to eq(1)
    end

    it "runs the block exactly once when reloading is not possible" do
      allow(described_class).to receive(:reloadable?).and_return(false)
      runs = 0
      described_class.with_app_code { runs += 1 }
      expect(runs).to eq(1)
    end

    it "returns the block's value" do
      allow(described_class).to receive(:reloadable?).and_return(false)
      expect(described_class.with_app_code { :answer }).to eq(:answer)
    end

    # The sharing lock is what makes Dependencies.interlock able to see this
    # call; without it a reload unloads constants mid-read.
    it "takes the executor's lock when a reload could land" do
      allow(described_class).to receive(:reloadable?).and_return(true)
      expect(Rails.application.executor).to receive(:wrap).and_call_original
      described_class.with_app_code { :ok }
    end

    it "does not take the lock when nothing can reload" do
      allow(described_class).to receive(:reloadable?).and_return(false)
      expect(Rails.application.executor).not_to receive(:wrap)
      described_class.with_app_code { :ok }
    end

    it "lets an exception out rather than retrying the block" do
      allow(described_class).to receive(:reloadable?).and_return(true)
      runs = 0
      expect {
        described_class.with_app_code { runs += 1; raise ArgumentError, "boom" }
      }.to raise_error(ArgumentError)
      expect(runs).to eq(1)
    end
  end
end
