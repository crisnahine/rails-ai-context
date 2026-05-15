# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::MigrationIntrospector do
  let(:app) { Rails.application }
  let(:introspector) { described_class.new(app) }

  before do
    @migrate_dir = File.join(app.root.to_s, "db/migrate")
    FileUtils.mkdir_p(@migrate_dir)

    File.write(File.join(@migrate_dir, "20240101120000_create_users.rb"), <<~RUBY)
      class CreateUsers < ActiveRecord::Migration[7.1]
        def change
          create_table :users do |t|
            t.string :email
            t.timestamps
          end
          add_index :users, :email, unique: true
        end
      end
    RUBY

    File.write(File.join(@migrate_dir, "20240215080000_add_name_to_users.rb"), <<~RUBY)
      class AddNameToUsers < ActiveRecord::Migration[7.1]
        def change
          add_column :users, :name, :string
        end
      end
    RUBY

    File.write(File.join(@migrate_dir, "20240320090000_create_posts.rb"), <<~RUBY)
      class CreatePosts < ActiveRecord::Migration[7.1]
        def change
          create_table :posts do |t|
            t.references :user, foreign_key: true
            t.string :title
            t.timestamps
          end
        end
      end
    RUBY
  end

  after do
    FileUtils.rm_rf(@migrate_dir)
  end

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns total migration count" do
      expect(result[:total]).to eq(3)
    end

    it "returns recent migrations in reverse order" do
      recent = result[:recent]
      expect(recent.first[:filename]).to eq("20240320090000_create_posts.rb")
      expect(recent.last[:filename]).to eq("20240101120000_create_users.rb")
    end

    it "detects migration actions" do
      create_users = result[:recent].find { |m| m[:filename].include?("create_users") }
      expect(create_users[:actions]).to include("create_table", "add_index")
    end

    it "detects add_column actions" do
      add_name = result[:recent].find { |m| m[:filename].include?("add_name") }
      expect(add_name[:actions]).to include("add_column")
    end

    it "returns migration stats" do
      stats = result[:migration_stats]
      expect(stats[:total_create_table]).to eq(2)
      expect(stats[:total_add_column]).to eq(1)
      expect(stats[:by_year]).to include("2024" => 3)
    end

    it "does not return an error" do
      expect(result[:error]).to be_nil
    end
  end

  describe "#pending_migrations (Rails compatibility)" do
    let(:migrate_dir) { File.join(app.root.to_s, "db/migrate") }

    it "uses MigrationContext#pending_migrations when available (Rails 7.1+)" do
      # Non-verifying double since pending_migrations may not exist in Rails 7.0
      fake_context = double("MigrationContext", migrations: [], pending_migrations: []) # rubocop:disable RSpec/VerifiedDoubles

      allow(ActiveRecord::Base).to receive(:connected?).and_return(true)
      allow(ActiveRecord::MigrationContext).to receive(:new).and_return(fake_context)
      allow(fake_context).to receive(:respond_to?).with(:pending_migrations).and_return(true)

      result = introspector.call
      expect(result[:pending]).to eq([])
      expect(fake_context).to have_received(:pending_migrations)
    end

    it "falls back to ActiveRecord::Migrator with schema_migration when pending_migrations is unavailable (Rails 7.0)" do
      fake_migration = double("Migration", version: 20240101120000, name: "CreateUsers") # rubocop:disable RSpec/VerifiedDoubles
      fake_context = double("MigrationContext", migrations: [fake_migration]) # rubocop:disable RSpec/VerifiedDoubles
      schema_migration = double("SchemaMigration") # rubocop:disable RSpec/VerifiedDoubles
      fake_connection = double("Connection") # rubocop:disable RSpec/VerifiedDoubles
      fake_migrator = double("Migrator", pending_migrations: [fake_migration]) # rubocop:disable RSpec/VerifiedDoubles

      allow(ActiveRecord::Base).to receive(:connected?).and_return(true)
      allow(ActiveRecord::MigrationContext).to receive(:new).and_return(fake_context)
      allow(fake_context).to receive(:respond_to?).with(:pending_migrations).and_return(false)
      allow(ActiveRecord::Base).to receive(:connection).and_return(fake_connection)
      allow(fake_connection).to receive(:schema_migration).and_return(schema_migration)
      allow(ActiveRecord::Migrator).to receive(:new).with(:up, [fake_migration], schema_migration).and_return(fake_migrator)

      result = introspector.call
      expect(result[:pending]).to eq([{ version: "20240101120000", name: "CreateUsers" }])
      expect(ActiveRecord::Migrator).to have_received(:new).with(:up, [fake_migration], schema_migration)
    end
  end
end
