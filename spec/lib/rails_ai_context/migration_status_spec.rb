# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::MigrationStatus do
  let(:migrate_dir) { File.join(Rails.application.root.to_s, "db/migrate") }

  after do
    FileUtils.rm_rf(migrate_dir)
  end

  describe ".pending" do
    it "returns nil when the migrations directory does not exist" do
      expect(described_class.pending(File.join(Rails.application.root.to_s, "db/no_such_migrate_dir"))).to be_nil
    end

    it "returns an empty array when there are no pending migrations" do
      FileUtils.mkdir_p(migrate_dir)
      expect(described_class.pending(migrate_dir)).to eq([])
    end

    it "returns pending migrations that have not been applied to the database" do
      FileUtils.mkdir_p(migrate_dir)
      File.write(File.join(migrate_dir, "20990101000000_create_widgets.rb"), <<~RUBY)
        class CreateWidgets < ActiveRecord::Migration[7.1]
          def change
            create_table :widgets do |t|
              t.string :name
            end
          end
        end
      RUBY

      pending = described_class.pending(migrate_dir)
      expect(pending).to eq([ { version: "20990101000000", name: "CreateWidgets" } ])
    end

    # Rails 7.2+ refuses to load a directory holding a version past tomorrow,
    # and the applied set still says which files have not run.
    it "answers from the applied versions when Rails refuses to load the directory" do
      skip "no migration timestamp validation before Rails 7.2" unless ActiveRecord.respond_to?(:validate_migration_timestamps=)

      FileUtils.mkdir_p(migrate_dir)
      File.write(File.join(migrate_dir, "20990101000000_create_widgets.rb"), "class CreateWidgets < ActiveRecord::Migration[7.1]\nend\n")
      previous = ActiveRecord.validate_migration_timestamps
      ActiveRecord.validate_migration_timestamps = true

      expect(described_class.pending(migrate_dir)).to eq([ { version: "20990101000000", name: "CreateWidgets" } ])
    ensure
      ActiveRecord.validate_migration_timestamps = previous if ActiveRecord.respond_to?(:validate_migration_timestamps=)
    end

    it "returns nil when ActiveRecord is not loaded" do
      hide_const("ActiveRecord")
      FileUtils.mkdir_p(migrate_dir)
      expect(described_class.pending(migrate_dir)).to be_nil
    end
  end

  describe ".migration_context" do
    it "resolves via the connection pool (Rails 7.1+ API)" do
      context = described_class.migration_context(migrate_dir)
      expect(context).to be_a(ActiveRecord::MigrationContext)
    end
  end

  # A secondary database keeps its own schema_migrations, which only a
  # connection to it can read.
  describe ".of_database" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    def database(path)
      ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "analytics", { adapter: "sqlite3", database: path })
    end

    it "reads a database of the app's other than the primary through a pool of its own, removed after" do
      dir = File.join(@dir, "analytics_migrate")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "20240101000000_create_events.rb"), "class CreateEvents < ActiveRecord::Migration[7.1]\nend\n")
      app_pool = ActiveRecord::Base.connection_pool

      state = described_class.of_database(database(File.join(@dir, "analytics.sqlite3")), dir)

      expect(state).to eq(pending: [ { version: "20240101000000", name: "CreateEvents" } ])
      expect(ActiveRecord::Base.connection_pool).to equal(app_pool)
      expect(ActiveRecord::Base.connection_handler.connection_pool_list.map { |pool| pool.db_config.name }).not_to include("analytics")
    end

    it "answers nothing pending for a database with no migrations, once it has connected" do
      expect(described_class.of_database(database(File.join(@dir, "analytics.sqlite3")), File.join(@dir, "none"))).to eq(pending: [])
    end

    it "hands back what stopped the connection" do
      # A directory where the database file should be: SQLite cannot open it.
      state = described_class.of_database(database(@dir), @dir)

      expect(state[:error]).to be_a(ActiveRecord::ActiveRecordError)
    end
  end
end
