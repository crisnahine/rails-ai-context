# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe "Listener edge cases" do
  # ── GenericMacroListener ──────────────────────────────────────────────

  describe RailsAiContext::Introspectors::Listeners::GenericMacroListener do
    def parse_and_dispatch(source, *methods)
      result     = Prism.parse(source)
      dispatcher = Prism::Dispatcher.new
      listener   = described_class.new(*methods)
      dispatcher.register(listener, :on_call_node_enter)
      dispatcher.dispatch(result.value)
      listener.results
    end

    it "extracts a string arg as a symbol (gem \"rails\" style)" do
      results = parse_and_dispatch('gem "rails"', :gem)
      expect(results.size).to eq(1)
      expect(results.first[:args]).to eq([:rails])
    end
  end

  # ── ChainedCallListener ──────────────────────────────────────────────

  describe RailsAiContext::Introspectors::Listeners::ChainedCallListener do
    def parse_and_dispatch(source, *methods)
      result     = Prism.parse(source)
      dispatcher = Prism::Dispatcher.new
      listener   = described_class.new(*methods)
      dispatcher.register(listener, :on_call_node_enter)
      dispatcher.dispatch(result.value)
      listener.results
    end

    it "detects a deeply nested method chain (a.b.c.variant(:thumb))" do
      results = parse_and_dispatch("a.b.c.variant(:thumb)", :variant)
      expect(results.size).to eq(1)
      expect(results.first[:method]).to eq("variant")
      expect(results.first[:args]).to eq([:thumb])
    end
  end

  # ── EnvAccessListener ────────────────────────────────────────────────

  describe RailsAiContext::Introspectors::Listeners::EnvAccessListener do
    def parse_and_dispatch(source)
      result     = Prism.parse(source)
      dispatcher = Prism::Dispatcher.new
      listener   = described_class.new
      dispatcher.register(listener, :on_call_node_enter)
      dispatcher.dispatch(result.value)
      listener.results
    end

    it "detects ENV.fetch with block default and reports has_default: true" do
      results = parse_and_dispatch('ENV.fetch("RAILS_ENV") { "development" }')
      expect(results.size).to eq(1)
      expect(results.first).to include(method: "fetch", key: "RAILS_ENV", has_default: true)
    end
  end

  # ── MountListener ────────────────────────────────────────────────────

  describe RailsAiContext::Introspectors::Listeners::MountListener do
    def parse_and_dispatch(source)
      result     = Prism.parse(source)
      dispatcher = Prism::Dispatcher.new
      listener   = described_class.new
      dispatcher.register(listener, :on_call_node_enter)
      dispatcher.dispatch(result.value)
      listener.results
    end

    it "detects mount with hash rocket syntax and extracts both engine and path" do
      results = parse_and_dispatch('mount Sidekiq::Web => "/sidekiq"')
      expect(results.size).to eq(1)
      expect(results.first).to include(engine: "Sidekiq::Web", path: "/sidekiq")
    end
  end

  # ── GemfileDslListener ──────────────────────────────────────────────

  describe RailsAiContext::Introspectors::Listeners::GemfileDslListener do
    def parse_and_dispatch(source)
      result     = Prism.parse(source)
      dispatcher = Prism::Dispatcher.new
      listener   = described_class.new
      events = []
      events << :on_call_node_enter if listener.respond_to?(:on_call_node_enter)
      events << :on_call_node_leave if listener.respond_to?(:on_call_node_leave)
      dispatcher.register(listener, *events)
      dispatcher.dispatch(result.value)
      listener.results
    end

    it "extracts version, require: false, and array group from a complex gem line" do
      results = parse_and_dispatch('gem "rails", "~> 7.1", require: false, group: [:dev, :test]')
      gems = results.select { |r| r[:type] == :gem }

      expect(gems.size).to eq(1)
      gem = gems.first
      expect(gem[:name]).to eq("rails")
      expect(gem[:version]).to eq("~> 7.1")
      expect(gem[:options]).to include(require: false)
      expect(gem[:groups]).to contain_exactly(:dev, :test)
    end
  end

  # ── SchemaDslListener ───────────────────────────────────────────────

  describe RailsAiContext::Introspectors::Listeners::SchemaDslListener do
    def parse_and_dispatch(source)
      result     = Prism.parse(source)
      dispatcher = Prism::Dispatcher.new
      listener   = described_class.new
      dispatcher.register(listener, :on_call_node_enter)
      dispatcher.dispatch(result.value)
      listener.results
    end

    it "detects t.references with foreign_key and null options" do
      results = parse_and_dispatch('t.references :user, foreign_key: true, null: false')
      cols = results.select { |r| r[:type] == :column }

      expect(cols.size).to eq(1)
      col = cols.first
      expect(col[:column_type]).to eq("references")
      expect(col[:name]).to eq("user")
      expect(col[:options]).to include(foreign_key: true, null: false)
    end
  end

  # ── MigrationDslListener ────────────────────────────────────────────

  describe RailsAiContext::Introspectors::Listeners::MigrationDslListener do
    def parse_and_dispatch(source)
      result     = Prism.parse(source)
      dispatcher = Prism::Dispatcher.new
      listener   = described_class.new
      dispatcher.register(listener, :on_call_node_enter)
      dispatcher.dispatch(result.value)
      listener.results
    end

    it "extracts add_column with type and multiple keyword options" do
      results = parse_and_dispatch('add_column :users, :role, :integer, default: 0, null: false')

      expect(results.size).to eq(1)
      result = results.first
      expect(result[:action]).to eq(:add_column)
      expect(result[:table]).to eq("users")
      expect(result[:column]).to eq("role")
      expect(result[:column_type]).to eq("integer")
      expect(result[:options]).to include(default: 0, null: false)
    end
  end

  # ── RakeTaskDslListener ─────────────────────────────────────────────

  describe RailsAiContext::Introspectors::Listeners::RakeTaskDslListener do
    def parse_and_dispatch(source)
      result     = Prism.parse(source)
      dispatcher = Prism::Dispatcher.new
      listener   = described_class.new
      dispatcher.register(listener, :on_call_node_enter)
      dispatcher.dispatch(result.value)
      listener.results
    end

    it "extracts task with mixed symbol and string dependencies" do
      results = parse_and_dispatch('task :seed => [:environment, "db:create"]')
      tasks = results.select { |r| r[:type] == :task }

      expect(tasks.size).to eq(1)
      task = tasks.first
      expect(task[:name]).to eq("seed")
      expect(task[:deps]).to contain_exactly("environment", "db:create")
    end
  end

  # ── MailboxRoutingListener ──────────────────────────────────────────

  describe RailsAiContext::Introspectors::Listeners::MailboxRoutingListener do
    def parse_and_dispatch(source)
      result     = Prism.parse(source)
      dispatcher = Prism::Dispatcher.new
      listener   = described_class.new
      dispatcher.register(listener, :on_call_node_enter)
      dispatcher.dispatch(result.value)
      listener.results
    end

    it "detects routing with a regex containing pipe" do
      results = parse_and_dispatch('routing /forward|bounce/i => :handle')
      routing = results.select { |r| r[:type] == :routing }

      expect(routing.size).to eq(1)
      expect(routing.first[:action]).to eq("handle")
      expect(routing.first[:pattern]).to include("forward|bounce")
    end
  end

  # ── MiddlewareConfigListener ────────────────────────────────────────

  describe RailsAiContext::Introspectors::Listeners::MiddlewareConfigListener do
    def parse_and_dispatch(source)
      result     = Prism.parse(source)
      dispatcher = Prism::Dispatcher.new
      listener   = described_class.new
      dispatcher.register(listener, :on_call_node_enter)
      dispatcher.dispatch(result.value)
      listener.results
    end

    it "detects config.middleware.insert with a numeric index arg" do
      results = parse_and_dispatch("config.middleware.insert 0, Rack::Deflater")

      expect(results.size).to eq(1)
      expect(results.first[:action]).to eq("insert")
      expect(results.first[:middleware]).to eq("Rack::Deflater")
    end
  end
end
