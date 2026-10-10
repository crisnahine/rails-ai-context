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

    # Connecting would create the file: an empty database with every
    # migration pending.
    it "returns nil without creating a SQLite database whose file is not there" do
      FileUtils.mkdir_p(migrate_dir)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "development.sqlite3")
        config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", { adapter: "sqlite3", database: path })
        allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(config)

        expect(described_class.pending(migrate_dir)).to be_nil
        expect(File.exist?(path)).to be(false)
      end
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

    # An empty file is an empty SQLite database: created, never migrated.
    def created_database
      path = File.join(@dir, "analytics.sqlite3")
      FileUtils.touch(path)
      path
    end

    def tables_in(path)
      db = SQLite3::Database.new(path, readonly: true)
      db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten
    ensure
      db&.close
    end

    def migrations_dir
      dir = File.join(@dir, "analytics_migrate")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "20240101000000_create_events.rb"), "class CreateEvents < ActiveRecord::Migration[7.1]\nend\n")
      dir
    end

    it "reads a database of the app's other than the primary through a pool of its own, removed after" do
      dir = migrations_dir
      app_pool = ActiveRecord::Base.connection_pool

      state = described_class.of_database(database(created_database), dir)

      expect(state).to eq(pending: [ { version: "20240101000000", name: "CreateEvents" } ])
      expect(ActiveRecord::Base.connection_pool).to equal(app_pool)
      expect(ActiveRecord::Base.connection_handler.connection_pool_list.map { |pool| pool.db_config.name }).not_to include("analytics")
    end

    # Building a Migrator creates schema_migrations and ar_internal_metadata
    # in a database that lacks them; reading what is pending writes nothing.
    it "reads a database that was never migrated without writing to it" do
      path = created_database

      expect(described_class.of_database(database(path), migrations_dir)).to eq(pending: [ { version: "20240101000000", name: "CreateEvents" } ])
      expect(tables_in(path)).to eq([])
    end

    it "answers nothing pending for a database with no migrations, once it has connected" do
      expect(described_class.of_database(database(created_database), File.join(@dir, "none"))).to eq(pending: [])
    end

    it "says a SQLite database whose file is not there does not exist, without creating it" do
      path = File.join(@dir, "analytics.sqlite3")

      state = described_class.of_database(database(path), migrations_dir)

      expect(state[:error]).to be_a(ActiveRecord::NoDatabaseError)
      expect(state[:error].message).to include(path)
      expect(File.exist?(path)).to be(false)
    end

    # Rails 7.1+ wraps the driver's error; Rails 7.0's sqlite3 adapter hands
    # back SQLite3::CantOpenException itself. Either way it is what stopped
    # the connection, and doctor reads it as a database it cannot reach.
    it "hands back what stopped the connection" do
      # A directory where the database file should be: SQLite cannot open it.
      state = described_class.of_database(database(@dir), @dir)

      expect(state.keys).to eq([ :error ])
      expect(state[:error].message).to match(/unable to open database file/i)
    end
  end
end
