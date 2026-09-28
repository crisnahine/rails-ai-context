# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::MultiDatabaseIntrospector do
  let(:app) { Rails.application }
  let(:introspector) { described_class.new(app) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns databases array" do
      expect(result[:databases]).to be_an(Array)
    end

    it "returns multi_db flag" do
      expect(result[:multi_db]).to be(true).or be(false)
    end

    it "returns replicas array" do
      expect(result[:replicas]).to be_an(Array)
    end

    it "returns model_connections array" do
      expect(result[:model_connections]).to be_an(Array)
    end

    it "does not return an error" do
      expect(result[:error]).to be_nil
    end
  end

  describe "replicas without a booted ActiveRecord" do
    it "lists the database.yml entries marked replica" do
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), <<~YAML)
          #{Rails.env}:
            primary:
              adapter: postgresql
              database: app_primary
            primary_replica:
              adapter: postgresql
              database: app_primary
              replica: true
        YAML

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        expect(result[:replicas]).to eq([ { name: "primary_replica", adapter: "postgresql" } ])
      end
    end
  end

  describe "an adapter the file computes in ERB" do
    it "reads the literal fallback and marks it a default" do
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), <<~YAML)
          #{Rails.env}:
            adapter: <%= ENV['DATABASE_ADAPTER'].presence || "mysql2" %>
            database: <%= ENV['DATABASE_NAME'].presence || "app_development" %>
        YAML

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        expect(result[:databases]).to eq([ { name: "primary", adapter: "mysql2", adapter_default: true } ])
      end
    end

    it "reads two tags in one value as unknown, not as a half-stripped sentinel" do
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), <<~YAML)
          #{Rails.env}:
            adapter: <%= ENV["PREFIX"] %><%= ENV["DB"] || "pg" %>
        YAML

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        expect(result[:databases]).to eq([ { name: "primary", adapter: nil } ])
      end
    end

    it "keeps a fallback that is not a plain token out of the YAML" do
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), <<~YAML)
          #{Rails.env}:
            adapter: <%= ENV["DB"] || "a: b" %>
        YAML

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        expect(result[:databases]).to eq([ { name: "primary", adapter: nil } ])
      end
    end

    it "leaves an adapter with no literal fallback unknown" do
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), <<~YAML)
          #{Rails.env}:
            adapter: <%= ENV.fetch("DATABASE_ADAPTER") %>
        YAML

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        expect(result[:databases]).to eq([ { name: "primary", adapter: nil } ])
      end
    end
  end

  # Canvas and Plots2 commit no database.yml, only example files.
  describe "an app that commits only example database files" do
    it "records the adapters every example file names" do
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml.example"), "development:\n  adapter: mysql2\n  # adapter: postgresql\n")
        File.write(File.join(dir, "config", "database.yml.sqlite.example"), "development:\n  adapter: sqlite3\n")

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        expect(result[:example_adapters]).to eq(%w[mysql2 sqlite3])
      end
    end

    it "reads an adapter line that ends in a comment" do
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml.example"), "development:\n  adapter: postgresql # local\n")

        expect(described_class.new(RailsAiContext::StaticApp.new(dir)).call[:example_adapters]).to eq(%w[postgresql])
      end
    end

    it "records none when the app commits its database.yml" do
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), "#{Rails.env}:\n  adapter: postgresql\n")
        File.write(File.join(dir, "config", "database.yml.example"), "development:\n  adapter: mysql2\n")

        expect(described_class.new(RailsAiContext::StaticApp.new(dir)).call).not_to have_key(:example_adapters)
      end
    end
  end

  describe "the environment the static tier reads" do
    it "reads the RAILS_ENV section, not development" do
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), <<~YAML)
          development:
            adapter: sqlite3
            database: db/dev.sqlite3
          production:
            adapter: postgresql
            database: app_production
        YAML

        original = ENV["RAILS_ENV"]
        begin
          ENV["RAILS_ENV"] = "production"
          RailsAiContext.tier = :static
          result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
          expect(result[:databases]).to eq([ { name: "primary", adapter: "postgresql" } ])
        ensure
          RailsAiContext.tier = :runtime
          ENV["RAILS_ENV"] = original
        end
      end
    end
  end

  describe "a database.yml that shares its adapter through an anchor" do
    it "resolves the merge key so every entry names its adapter" do
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), <<~YAML)
          default: &default
            adapter: postgresql
            encoding: unicode

          #{Rails.env}:
            primary:
              <<: *default
              database: app_primary
            primary_replica:
              <<: *default
              database: app_primary
              replica: true
        YAML

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        expect(result[:replicas]).to eq([ { name: "primary_replica", adapter: "postgresql" } ])
        expect(result[:databases]).to eq([
          { name: "primary", adapter: "postgresql" },
          { name: "primary_replica", adapter: "postgresql", replica: true }
        ])
      end
    end
  end

  describe "a database.yml whose second database is named replica" do
    let(:yml) do
      <<~YAML
        default: &default
          adapter: postgresql
          pool: <%= ENV["DB_POOL"] || 5 %>
          encoding: unicode

        development:
          primary:
            <<: *default
            database: <%= ENV['DB_NAME'] || 'mastodon_development' %>
          replica:
            <<: *default
            database: <%= ENV['DB_NAME'] || 'mastodon_development' %>
            replica: true

        test:
          primary:
            <<: *default
            database: <%= ENV['DB_NAME'] || 'mastodon' %>_test
          replica:
            <<: *default
            database: <%= ENV['DB_NAME'] || 'mastodon' %>_test
            replica: true

        production:
          primary:
            <<: *default
            database: <%= ENV['DB_NAME'] || 'mastodon_production' %>
          replica:
            <<: *default
            database: <%= ENV['REPLICA_DB_NAME'] || 'mastodon_production' %>
            replica: true
            database_tasks: <%= ENV['REPLICA_DB_TASKS'] || 'true' %>
      YAML
    end

    it "reads it as two databases, the second the replica" do
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), yml)

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call

        expect(result[:databases]).to eq([
          { name: "primary", adapter: "postgresql" },
          { name: "replica", adapter: "postgresql", replica: true }
        ])
        expect(result[:replicas]).to eq([ { name: "replica", adapter: "postgresql" } ])
        expect(result[:multi_db]).to be(true)
      end
    end
  end

  # configs_for hides a replica unless asked, so Mastodon's booted run lost it
  # while the static tier read it from the file.
  describe "a booted app with a replica" do
    it "lists the replica the live configurations hold" do
      configurations = ActiveRecord::DatabaseConfigurations.new(
        Rails.env => { "primary" => { "adapter" => "postgresql", "database" => "app" },
                       "replica" => { "adapter" => "postgresql", "database" => "app", "replica" => true } }
      )
      allow(ActiveRecord::Base).to receive(:configurations).and_return(configurations)

      result = described_class.new(Rails.application).call

      expect(result[:databases].map { |d| d[:name] }).to eq([ "primary", "replica" ])
      expect(result[:replicas]).to eq([ { name: "replica", adapter: "postgresql" } ])
      expect(result[:multi_db]).to be(true)
    end
  end

  describe "a boot that failed, so the live configurations are empty" do
    it "falls back to the file rather than reporting no databases" do
      allow(ActiveRecord::Base.configurations).to receive(:configs_for).and_return([])
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), <<~YAML)
          #{Rails.env}:
            primary:
              adapter: postgresql
            replica:
              adapter: postgresql
              replica: true
        YAML

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call

        expect(result[:databases].map { |d| d[:name] }).to eq([ "primary", "replica" ])
        expect(result[:replicas]).to eq([ { name: "replica", adapter: "postgresql" } ])
        expect(result[:multi_db]).to be(true)
      end
    end
  end

  describe "shapes YAML answers and a line reader does not" do
    def databases_for(yml)
      hide_const("ActiveRecord")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "database.yml"), yml)
        yield described_class.new(RailsAiContext::StaticApp.new(dir)).call
      end
    end

    it "reads a database named replica that carries the anchor on its key line" do
      databases_for(<<~YAML) do |result|
        #{Rails.env}:
          primary: &primary
            adapter: postgresql
            database: app
          replica: &replica
            adapter: postgresql
            database: app
            replica: true
      YAML
        expect(result[:databases]).to eq([
          { name: "primary", adapter: "postgresql" },
          { name: "replica", adapter: "postgresql", replica: true }
        ])
        expect(result[:replicas]).to eq([ { name: "replica", adapter: "postgresql" } ])
        expect(result[:multi_db]).to be(true)
      end
    end

    it "follows an anchor that merges another anchor" do
      databases_for(<<~YAML) do |result|
        #{Rails.env}:
          primary: &primary_development
            adapter: postgresql
            database: app
          primary_replica:
            <<: *primary_development
            replica: true
      YAML
        expect(result[:databases]).to eq([
          { name: "primary", adapter: "postgresql" },
          { name: "primary_replica", adapter: "postgresql", replica: true }
        ])
      end
    end

    it "reads an anchor whose line ends in a comment" do
      databases_for(<<~YAML) do |result|
        default: &default # every database shares this
          adapter: postgresql

        #{Rails.env}:
          primary:
            <<: *default
          replica:
            <<: *default
            replica: true
      YAML
        expect(result[:replicas]).to eq([ { name: "replica", adapter: "postgresql" } ])
      end
    end

    it "counts an env given only a url as one database" do
      databases_for(<<~YAML) do |result|
        #{Rails.env}:
          url: postgres://localhost/app
      YAML
        expect(result[:databases]).to eq([ { name: "primary", adapter: nil } ])
        expect(result[:multi_db]).to be(false)
      end
    end

    it "reads a three-database env" do
      databases_for(<<~YAML) do |result|
        #{Rails.env}:
          primary:
            adapter: postgresql
          animals:
            adapter: mysql2
          primary_replica:
            adapter: postgresql
            replica: true
      YAML
        expect(result[:databases]).to eq([
          { name: "primary", adapter: "postgresql" },
          { name: "animals", adapter: "mysql2" },
          { name: "primary_replica", adapter: "postgresql", replica: true }
        ])
        expect(result[:multi_db]).to be(true)
      end
    end

    it "reports the ERB literal default, never the sentinel" do
      databases_for(<<~YAML) do |result|
        #{Rails.env}:
          primary:
            adapter: <%= ENV["DB_ADAPTER"] || "postgresql" %>
            database: app
      YAML
        expect(result[:databases]).to eq([ { name: "primary", adapter: "postgresql", adapter_default: true } ])
      end
    end

    it "reads a flat single-database file" do
      databases_for(<<~YAML) do |result|
        #{Rails.env}:
          adapter: sqlite3
          database: db/app.sqlite3
      YAML
        expect(result[:databases]).to eq([ { name: "primary", adapter: "sqlite3" } ])
        expect(result[:multi_db]).to be(false)
      end
    end

    it "answers nothing for a file that is not YAML even with the ERB taken out" do
      databases_for(<<~YAML) do |result|
        #{Rails.env}:
          primary:
        adapter: "unclosed
          - [
      YAML
        expect(result[:databases]).to eq([])
        expect(result[:replicas]).to eq([])
        expect(result[:multi_db]).to be(false)
      end
    end
  end

  describe "model connection detection" do
    before do
      @models_dir = File.join(app.root.to_s, "app/models")
      FileUtils.mkdir_p(@models_dir)

      File.write(File.join(@models_dir, "animals_record.rb"), <<~RUBY)
        class AnimalsRecord < ApplicationRecord
          self.abstract_class = true
          connects_to database: { writing: :animals, reading: :animals_replica }
        end
      RUBY
    end

    after do
      FileUtils.rm_f(File.join(@models_dir, "animals_record.rb"))
    end

    it "detects connects_to in models" do
      result = introspector.call
      connections = result[:model_connections]
      animal = connections.find { |c| c[:model] == "AnimalsRecord" }
      expect(animal).not_to be_nil
      expect(animal[:connects_to]).to include("animals")
    end
  end

  describe "model connections across every model directory" do
    it "finds a pack model's connects_to and names a namespaced model by its declared name" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "admin"))
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "models"))
        File.write(File.join(dir, "app", "models", "admin", "record.rb"),
                   "class Admin::Record < ApplicationRecord\n  connects_to database: { writing: :admin }\nend\n")
        File.write(File.join(dir, "packs", "billing", "app", "models", "invoice.rb"),
                   "class Invoice < ApplicationRecord\n  connects_to database: { writing: :billing }\nend\n")

        connections = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:model_connections]
        expect(connections.map { |c| c[:model] }).to contain_exactly("Admin::Record", "Invoice")
      end
    end
  end
end
