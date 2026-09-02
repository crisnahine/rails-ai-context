# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

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

  describe "static tier" do
    it "is declared files-only" do
      expect(described_class.static_tier).to eq(:files_only)
    end

    it "reports migrations from a bare directory with no booted app" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db", "migrate"))
        File.write(File.join(dir, "db", "migrate", "20240101000000_create_widgets.rb"), <<~RUBY)
          class CreateWidgets < ActiveRecord::Migration[7.1]
            def change
              create_table :widgets
            end
          end
        RUBY
        app = RailsAiContext::StaticApp.new(dir)
        result = described_class.new(app).call
        expect(result[:total]).to eq(1)
        expect(result[:recent].first[:name]).to eq("Create widgets")
      end
    end

    it "omits pending entirely when the schema records no version" do
      hide_const("ActiveRecord")

      Dir.mktmpdir do |dir|
        migrate = File.join(dir, "db", "migrate")
        FileUtils.mkdir_p(migrate)
        File.write(File.join(migrate, "20240101000000_create_users.rb"), "class X; end\n")
        File.write(File.join(dir, "db", "schema.rb"), "ActiveRecord::Schema.define do\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call

        expect(result).not_to have_key(:pending)
        expect(result[:total]).to eq(1)
      end
    end

    it "reads every applied version from structure.sql so an out-of-order merge is pending" do
      hide_const("ActiveRecord")

      Dir.mktmpdir do |dir|
        migrate = File.join(dir, "db", "migrate")
        FileUtils.mkdir_p(migrate)
        %w[20240101000000_create_users 20240201000000_add_index 20240301000000_create_posts].each do |name|
          File.write(File.join(migrate, "#{name}.rb"), "class X; end\n")
        end
        File.write(File.join(dir, "db", "structure.sql"), <<~SQL)
          CREATE TABLE public.users (id bigint NOT NULL);

          INSERT INTO schema_migrations (version) VALUES ('20240101000000'), ('20240301000000');
        SQL

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call

        expect(result[:pending]).to eq([ { version: "20240201000000", name: "Add index" } ])
      end
    end

    it "counts only versioned files in both the total and the pending list" do
      hide_const("ActiveRecord")

      Dir.mktmpdir do |dir|
        migrate = File.join(dir, "db", "migrate")
        FileUtils.mkdir_p(migrate)
        File.write(File.join(migrate, "20240101000000_create_users.rb"), "class X; end\n")
        File.write(File.join(migrate, "add_index.rb"), "class AddIndex; end\n")
        File.write(File.join(dir, "db", "schema.rb"), "ActiveRecord::Schema[7.1].define(version: 1) do\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call

        expect(result[:total]).to eq(1)
        expect(result[:recent].map { |m| m[:filename] }).to eq([ "20240101000000_create_users.rb" ])
        expect(result[:pending].map { |m| m[:version] }).to eq([ "20240101000000" ])
      end
    end

    it "reports files newer than the schema version as pending" do
      hide_const("ActiveRecord")

      Dir.mktmpdir do |dir|
        migrate = File.join(dir, "db", "migrate")
        FileUtils.mkdir_p(migrate)
        %w[20240101000000_create_users 20240201000000_add_index 20240301000000_create_posts].each do |name|
          File.write(File.join(migrate, "#{name}.rb"), "class X < ActiveRecord::Migration[7.1]; end\n")
        end
        File.write(File.join(dir, "db", "schema.rb"), "ActiveRecord::Schema[7.1].define(version: 2024_02_01_000000) do\nend\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call

        expect(result[:pending]).to eq([ { version: "20240301000000", name: "Create posts" } ])
      end
    end
  end
end
