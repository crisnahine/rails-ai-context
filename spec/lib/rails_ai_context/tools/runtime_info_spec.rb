# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::RuntimeInfo do
  before { described_class.reset_cache! }

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "includes Runtime Info header" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Runtime Info")
    end

    it "shows connection pool stats" do
      result = described_class.call(section: "connections")
      text = result.content.first[:text]
      expect(text).to include("Connection Pool")
      expect(text).to include("Pool size")
    end

    it "shows database section" do
      result = described_class.call(section: "database")
      text = result.content.first[:text]
      expect(text).to include("Database")
    end

    it "shows cache section" do
      result = described_class.call(section: "cache")
      text = result.content.first[:text]
      expect(text).to include("Cache")
    end

    it "shows jobs section" do
      result = described_class.call(section: "jobs")
      text = result.content.first[:text]
      expect(text).to include("Background Jobs")
    end

    it "filters to a single section" do
      result = described_class.call(section: "connections")
      text = result.content.first[:text]
      expect(text).to include("Connection Pool")
      expect(text).not_to include("Background Jobs")
      expect(text).not_to include("## Cache")
    end

    it "standard detail shows all sections" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("Connection Pool")
      expect(text).to include("Database")
    end

    it "handles graceful degradation when Sidekiq not loaded" do
      result = described_class.call(section: "jobs")
      text = result.content.first[:text]
      expect(text).to include("not loaded")
    end

    context "when ActiveRecord is not defined" do
      before do
        @original_ar = ActiveRecord
        hide_const("ActiveRecord")
      end

      after do
        # ActiveRecord is restored automatically by hide_const
      end

      it "degrades gracefully for connection pool section" do
        result = described_class.call(section: "connections")
        text = result.content.first[:text]
        expect(text).to include("ActiveRecord not available")
        expect(text).not_to include("Pool size")
      end

      it "degrades gracefully for database section" do
        result = described_class.call(section: "database")
        text = result.content.first[:text]
        expect(text).to include("ActiveRecord not available")
      end

      it "still returns cache and jobs sections" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Runtime Info")
        expect(text).to include("Cache")
        expect(text).to include("Background Jobs")
      end
    end

    it "has read-only annotations" do
      annotations = described_class.annotations_value
      expect(annotations.read_only_hint).to eq(true)
      expect(annotations.destructive_hint).to eq(false)
    end

    it "uses MigrationContext#pending_migrations when available (Rails 7.1+)" do
      # Non-verifying double since pending_migrations may not exist in Rails 7.0
      fake_context = double("MigrationContext", migrations: [], pending_migrations: []) # rubocop:disable RSpec/VerifiedDoubles

      allow(Dir).to receive(:exist?).and_call_original
      allow(Dir).to receive(:exist?).with(File.join(Rails.root, "db/migrate")).and_return(true)
      allow(ActiveRecord::MigrationContext).to receive(:new).and_return(fake_context)
      allow(fake_context).to receive(:respond_to?).with(:pending_migrations).and_return(true)

      result = described_class.call(section: "database")
      text = result.content.first[:text]

      expect(text).to include("Database")
      expect(fake_context).to have_received(:pending_migrations)
    end

    it "falls back to ActiveRecord::Migrator when pending_migrations is unavailable (Rails 7.0)" do
      fake_context = double("MigrationContext", migrations: []) # rubocop:disable RSpec/VerifiedDoubles
      schema_migration = double("SchemaMigration") # rubocop:disable RSpec/VerifiedDoubles
      fake_migrator = double("Migrator", pending_migrations: []) # rubocop:disable RSpec/VerifiedDoubles

      allow(Dir).to receive(:exist?).and_call_original
      allow(Dir).to receive(:exist?).with(File.join(Rails.root, "db/migrate")).and_return(true)
      allow(ActiveRecord::MigrationContext).to receive(:new).and_return(fake_context)
      allow(fake_context).to receive(:respond_to?).with(:pending_migrations).and_return(false)
      allow(ActiveRecord::Base).to receive_message_chain(:connection, :schema_migration).and_return(schema_migration)
      allow(ActiveRecord::Migrator).to receive(:new).with(:up, [], schema_migration).and_return(fake_migrator)

      # Test the private method directly to isolate fallback from gather_database's connection calls
      result = described_class.send(:gather_pending_migrations)

      expect(result).to eq([])
      expect(ActiveRecord::Migrator).to have_received(:new).with(:up, [], schema_migration)
    end
  end
end
