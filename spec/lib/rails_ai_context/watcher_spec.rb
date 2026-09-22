# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Watcher do
  let(:app) { Rails.application }
  let(:watcher) { described_class.new(app) }

  describe "the shared watch list" do
    it "includes key Rails directories" do
      dirs = RailsAiContext::ChangeWatch.new(app).watched_dirs
      root = app.root.to_s
      expect(dirs).to include(File.join(root, "app/models"))
      expect(dirs).to include(File.join(root, "app/controllers"))
      expect(dirs).to include(File.join(root, "config"))
      expect(dirs).to include(File.join(root, "lib/tasks"))
    end

    # config/routes.rb and db/schema.rb are the two edits an author expects to
    # regenerate context, and only a Listen event runs the gate.
    it "watches config and db whole" do
      require "tmpdir"
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "config"))
        FileUtils.mkdir_p(File.join(root, "db"))
        File.write(File.join(root, "config/routes.rb"), "Rails.application.routes.draw {}")
        watch = RailsAiContext::ChangeWatch.new(RailsAiContext::StaticApp.new(root))

        expect(watch.watched_dirs).to include(File.join(root, "config"), File.join(root, "db"))
      end
    end

    it "watches a pack's models, so a pack edit reaches the reaction" do
      require "tmpdir"
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "packs", "billing", "app", "models"))
        watch = RailsAiContext::ChangeWatch.new(RailsAiContext::StaticApp.new(root))

        expect(watch.watched_dirs).to include(File.join(root, "packs", "billing", "app", "models"))
      end
    end
  end

  describe "#initialize" do
    it "stores the app reference" do
      expect(watcher.app).to eq(app)
    end

    it "defaults to Rails.application when no app is given" do
      w = described_class.new
      expect(w.app).to eq(Rails.application)
    end

    it "computes an initial fingerprint without raising" do
      expect { described_class.new(app) }.not_to raise_error
    end
  end

  describe "#start" do
    context "when listen gem is not available" do
      before do
        allow(watcher.instance_variable_get(:@watch)).to receive(:require).with("listen").and_raise(LoadError)
        allow($stderr).to receive(:puts)
      end

      it "prints an error message and exits" do
        expect($stderr).to receive(:puts).with(/listen.*gem is required/)
        expect { watcher.start }.to raise_error(SystemExit)
      end
    end
  end

  describe "handle_change (private)" do
    context "when fingerprint has changed" do
      before do
        allow(RailsAiContext::Fingerprinter).to receive(:stale?).and_return(true)
        allow(RailsAiContext::Fingerprinter).to receive(:mark).and_return(RailsAiContext::Fingerprinter::Mark.new(digest: "new_fp"))
        allow(RailsAiContext).to receive(:generate_context).and_return(
          { written: [ "/tmp/CLAUDE.md" ], skipped: [ "/tmp/.cursorrules" ] }
        )
        allow($stderr).to receive(:puts)
      end

      # `format: :all` rewrote every tool's files whatever the user picked,
      # and wrote them at all under an MCP-only install.
      it "regenerates the context files the configuration asks for" do
        expect(RailsAiContext).to receive(:generate_context).with(no_args)
        watcher.send(:handle_change)
      end

      it "logs written files" do
        expect($stderr).to receive(:puts).with("  Updated: /tmp/CLAUDE.md")
        watcher.send(:handle_change)
      end

      it "logs skipped files" do
        expect($stderr).to receive(:puts).with("  Unchanged: /tmp/.cursorrules")
        watcher.send(:handle_change)
      end
    end

    context "when a file does not apply to the app" do
      before do
        allow(RailsAiContext::Fingerprinter).to receive(:stale?).and_return(true)
        allow(RailsAiContext::Fingerprinter).to receive(:mark).and_return(RailsAiContext::Fingerprinter::Mark.new(digest: "new_fp"))
        allow(RailsAiContext).to receive(:generate_context).and_return(
          { written: [], skipped: [], not_applicable: { "/tmp/.claude/rules/rails-models.md" => "no models" } }
        )
        allow($stderr).to receive(:puts)
      end

      it "logs it with its reason" do
        expect($stderr).to receive(:puts).with("  Not applicable: /tmp/.claude/rules/rails-models.md (no models)")
        watcher.send(:handle_change)
      end
    end

    context "when fingerprint has not changed" do
      before do
        allow(RailsAiContext::Fingerprinter).to receive(:stale?).and_return(false)
      end

      it "does not regenerate context" do
        expect(RailsAiContext).not_to receive(:generate_context)
        watcher.send(:handle_change)
      end
    end

    context "when an error occurs during regeneration" do
      before do
        allow(RailsAiContext::Fingerprinter).to receive(:stale?).and_return(true)
        allow(RailsAiContext::Fingerprinter).to receive(:mark).and_return(RailsAiContext::Fingerprinter::Mark.new(digest: "new_fp"))
        allow(RailsAiContext).to receive(:generate_context).and_raise(StandardError, "write failure")
        allow($stderr).to receive(:puts)
      end

      it "rescues the error and logs it" do
        expect($stderr).to receive(:puts).with("[rails-ai-context] Error regenerating: write failure")
        expect { watcher.send(:handle_change) }.not_to raise_error
      end
    end
  end
  # The whole point of watch mode is that the generated files track the app.
  # Regenerating without reloading rewrote them from the constants the watcher
  # booted with, so a model added while it ran never appeared.
  describe "#handle_change" do
    it "reloads the app's code before regenerating" do
      watcher = described_class.new(Rails.application)
      allow(RailsAiContext::Fingerprinter).to receive(:stale?).and_return(true)
      allow(RailsAiContext::Fingerprinter).to receive(:mark).and_return(RailsAiContext::Fingerprinter::Mark.new(digest: "fp"))
      allow(RailsAiContext).to receive(:generate_context).and_return({ written: [], skipped: [] })
      allow($stderr).to receive(:puts)

      expect(RailsAiContext::CodeReloader).to receive(:reload!)
      watcher.send(:handle_change)
    end
  end
end
