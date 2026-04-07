# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::LiveReload do
  let(:app) { Rails.application }
  let(:mcp_server) { instance_double("MCP::Server") }
  let(:live_reload) { described_class.new(app, mcp_server) }

  describe "#initialize" do
    it "stores the app and MCP server references" do
      expect(live_reload.app).to eq(app)
      expect(live_reload.mcp_server).to eq(mcp_server)
    end

    it "computes an initial fingerprint" do
      # The instance should have a fingerprint set (tested via handle_change behavior)
      expect { live_reload }.not_to raise_error
    end
  end

  describe "#handle_change" do
    let(:changed_paths) { [ "/app/models/user.rb", "/app/controllers/posts_controller.rb" ] }

    context "when fingerprint has changed" do
      before do
        allow(RailsAiContext::Fingerprinter).to receive(:changed?).and_return(true)
        allow(RailsAiContext::Fingerprinter).to receive(:compute).and_return("new_fingerprint")
        allow(mcp_server).to receive(:notify_resources_list_changed)
        allow(mcp_server).to receive(:notify_log_message)
        allow($stderr).to receive(:puts)
      end

      it "invalidates all tool caches (which includes AstCache.clear)" do
        expect(RailsAiContext::Tools::BaseTool).to receive(:reset_all_caches!)
        live_reload.handle_change(changed_paths)
      end

      it "sends notify_resources_list_changed to MCP server" do
        expect(mcp_server).to receive(:notify_resources_list_changed)
        live_reload.handle_change(changed_paths)
      end

      it "sends notify_log_message with change details" do
        expect(mcp_server).to receive(:notify_log_message).with(
          data: a_string_matching(/Files changed:.*Tool caches invalidated\./),
          level: "info",
          logger: "rails-ai-context"
        )
        live_reload.handle_change(changed_paths)
      end

      it "logs to stderr" do
        expect($stderr).to receive(:puts).with(a_string_matching(/Files changed:.*Tool caches invalidated\./))
        live_reload.handle_change(changed_paths)
      end
    end

    context "when fingerprint has not changed" do
      before do
        allow(RailsAiContext::Fingerprinter).to receive(:changed?).and_return(false)
      end

      it "skips cache invalidation and notifications" do
        expect(RailsAiContext::Tools::BaseTool).not_to receive(:reset_all_caches!)
        expect(mcp_server).not_to receive(:notify_resources_list_changed)
        live_reload.handle_change(changed_paths)
      end
    end

    context "when an error occurs" do
      before do
        allow(RailsAiContext::Fingerprinter).to receive(:changed?).and_raise(StandardError, "disk error")
        allow($stderr).to receive(:puts)
      end

      it "rescues and logs the error without crashing" do
        expect($stderr).to receive(:puts).with("[rails-ai-context] Live reload error: disk error")
        expect { live_reload.handle_change(changed_paths) }.not_to raise_error
      end
    end
  end

  describe "#categorize_changes" do
    it "groups files by type correctly" do
      paths = [
        "/rails/app/models/user.rb",
        "/rails/app/models/post.rb",
        "/rails/app/controllers/posts_controller.rb",
        "/rails/app/views/posts/index.html.erb",
        "/rails/app/jobs/publish_job.rb",
        "/rails/config/routes.rb",
        "/rails/config/database.yml",
        "/rails/db/migrate/001_create_users.rb",
        "/rails/db/schema.rb",
        "/rails/lib/tasks/deploy.rake",
        "/rails/app/mailers/user_mailer.rb",
        "/rails/app/javascript/controllers/hello_controller.js",
        "/rails/some/other/file.rb"
      ]

      result = live_reload.categorize_changes(paths)

      expect(result["model"]).to eq(2)
      expect(result["controller"]).to eq(1)
      expect(result["view"]).to eq(1)
      expect(result["job"]).to eq(1)
      expect(result["route"]).to eq(1)
      expect(result["config"]).to eq(1)
      expect(result["migration"]).to eq(1)
      expect(result["database"]).to eq(1)
      expect(result["rake_task"]).to eq(1)
      expect(result["mailer"]).to eq(1)
      expect(result["javascript"]).to eq(1)
      expect(result["file"]).to eq(1)
    end
  end

  describe "#format_change_message" do
    it "produces a readable summary" do
      categories = { "model" => 2, "controller" => 1 }
      message = live_reload.format_change_message(categories)
      expect(message).to eq("Files changed: 2 model(s), 1 controller(s).")
    end

    it "handles a single category" do
      categories = { "config" => 3 }
      message = live_reload.format_change_message(categories)
      expect(message).to eq("Files changed: 3 config(s).")
    end
  end

  describe "#start" do
    # Listen gem is loaded at runtime via `require "listen"` inside #start.
    # Define a stub module with #to so verify_partial_doubles allows mocking.
    let(:listen_mod) do
      mod = Module.new
      mod.define_singleton_method(:to) { |*_args, **_kwargs, &_block| }
      mod
    end
    let(:listener) { instance_double("Listen::Listener") }

    before do
      # Stub `require "listen"` so it doesn't raise LoadError in the test env
      allow(live_reload).to receive(:require).with("listen").and_return(true)
      stub_const("Listen", listen_mod)
      allow(listen_mod).to receive(:to).and_return(listener)
      allow(listener).to receive(:start)
      allow($stderr).to receive(:puts)
    end

    it "creates a listener and starts it" do
      live_reload.start

      expect(listen_mod).to have_received(:to)
      expect(listener).to have_received(:start)
    end

    it "passes debounce config as wait_for_delay" do
      RailsAiContext.configuration.live_reload_debounce = 2.5

      live_reload.start

      # Listen.to receives multiple directory args followed by keyword args
      expect(listen_mod).to have_received(:to) do |*args, **kwargs|
        expect(kwargs[:wait_for_delay]).to eq(2.5)
      end
    ensure
      RailsAiContext.configuration.live_reload_debounce = 1.5
    end

    it "logs the enabled message to stderr" do
      live_reload.start

      expect($stderr).to have_received(:puts).with(a_string_matching(/Live reload enabled/))
    end
  end

  describe "#stop" do
    it "stops the listener when one is running" do
      listener = instance_double("Listen::Listener")
      allow(listener).to receive(:stop)
      live_reload.instance_variable_set(:@listener, listener)

      live_reload.stop

      expect(listener).to have_received(:stop)
    end

    it "does nothing when no listener is set" do
      expect { live_reload.stop }.not_to raise_error
    end
  end

  describe "WATCH_DIRS" do
    it "is the union of Watcher::WATCH_PATTERNS and Fingerprinter::WATCHED_DIRS" do
      expected = (RailsAiContext::Watcher::WATCH_PATTERNS | RailsAiContext::Fingerprinter::WATCHED_DIRS)
      expect(described_class::WATCH_DIRS).to match_array(expected)
    end
  end
end
