# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::CLI::EntryBoot do
  describe ".app_present?" do
    it "is true for a directory with config/environment.rb" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/environment.rb"), "")
        expect(described_class.app_present?(dir)).to be true
      end
    end

    it "is false for an empty directory" do
      Dir.mktmpdir { |dir| expect(described_class.app_present?(dir)).to be false }
    end

    # An engine keeps its dummy app under spec/dummy; its root has app/ and
    # no config/. The static tier can read it; the boot tier cannot.
    it "accepts a source-only engine repo only when asked to" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/widget.rb"), "class Widget; end\n")
        expect(described_class.app_present?(dir)).to be false
        expect(described_class.app_present?(dir, allow_source_only: true)).to be true
      end
    end
  end

  describe ".call" do
    # Entering the static tier is real here, not stubbed.
    around do |example|
      app_root = RailsAiContext.configuration.app_root
      example.run
    ensure
      RailsAiContext.tier = :runtime
      RailsAiContext.static_reason = nil
      RailsAiContext.configuration.app_root = app_root
    end

    it "answers :absent with the message for a directory that is not an app" do
      Dir.mktmpdir do |dir|
        outcome = described_class.call(root: dir, allow_static: true)
        expect(outcome.tier).to eq(:absent)
        expect(outcome.messages.first).to eq("Error: No Rails app found in #{dir}")
      end
    end

    it "answers :static without booting when --no-boot is passed to a readable app" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/widget.rb"), "class Widget; end\n")
        outcome = described_class.call(root: dir, allow_static: true, no_boot: true)
        expect(outcome.tier).to eq(:static)
        expect(outcome.reason).to eq("static mode requested with --no-boot")
      end
    end

    it "refuses --no-boot on a directory with nothing to read" do
      Dir.mktmpdir do |dir|
        outcome = described_class.call(root: dir, allow_static: true, no_boot: true)
        expect(outcome.tier).to eq(:absent)
      end
    end

    it "hands the static tier the root it was given" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/widget.rb"), "class Widget; end\n")
        expect(RailsAiContext::Configuration).to receive(:auto_load!).with(dir)

        described_class.call(root: dir, allow_static: true, no_boot: true)
        expect(RailsAiContext.configuration.app_root).to eq(dir)
      end
    end

    context "with a failed boot" do
      let(:failed) { RailsAiContext::BootManager::Result.new(status: :failed, error: RuntimeError.new("boom")) }

      # The real one empties Gem.loaded_specs for the whole process outside
      # `bundle exec`.
      before do
        allow(RailsAiContext::BootManager).to receive(:boot!).and_return(failed)
        allow(described_class).to receive(:drop_conflicting_gem_activations!)
      end

      def failing_app
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config/environment.rb"), "raise 'boom'\n")
          yield dir
        end
      end

      it "degrades to :static when static is allowed, and to :absent when it is not" do
        failing_app do |dir|
          allowed = described_class.call(root: dir, allow_static: true)
          expect(allowed.tier).to eq(:static)
          expect(allowed.messages).to include(a_string_starting_with("[rails-ai-context] App boot failed:"))

          refused = described_class.call(root: dir, allow_static: false)
          expect(refused.tier).to eq(:absent)
          expect(refused.messages.first).to eq("Error: Rails app failed to boot in #{dir}")
        end
      end

      # A broken install cannot load the gem either; the boot diagnosis
      # collected so far must still reach the terminal.
      it "keeps the boot-failure lines when the static tier itself cannot load" do
        allow(described_class).to receive(:require_gem_without_app!).and_raise(LoadError, "cannot load such file -- mcp")

        failing_app do |dir|
          outcome = described_class.call(root: dir, allow_static: true)
          expect(outcome.tier).to eq(:absent)
          expect(outcome.messages).to include(a_string_starting_with("[rails-ai-context] App boot failed:"))
          expect(outcome.messages.last).to eq("Error: cannot load such file -- mcp")
        end
      end
    end
  end
end
