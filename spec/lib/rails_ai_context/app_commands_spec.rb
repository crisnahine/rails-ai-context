# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::AppCommands do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  def touch(rel)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "")
  end

  describe ".server" do
    it "names bin/dev when the app has one" do
      touch("bin/dev")
      touch("bin/rails")
      expect(described_class.server(@root)).to eq("bin/dev")
    end

    it "falls back to bin/rails server" do
      touch("bin/rails")
      expect(described_class.server(@root)).to eq("bin/rails server")
    end

    it "names no server for a tree with neither" do
      expect(described_class.server(@root)).to be_nil
    end
  end

  describe ".migrate" do
    it "names db:migrate for an app that migrates" do
      touch("bin/rails")
      FileUtils.mkdir_p(File.join(@root, "db", "migrate"))
      expect(described_class.migrate(@root)).to eq("bin/rails db:migrate")
    end

    it "names none for an app with no db/migrate" do
      touch("bin/rails")
      expect(described_class.migrate(@root)).to be_nil
    end

    it "names none without bin/rails" do
      FileUtils.mkdir_p(File.join(@root, "db", "migrate"))
      expect(described_class.migrate(@root)).to be_nil
    end
  end

  # db:setup also runs the seeds, which an app's own setup may warn against;
  # these build the database from what the app keeps and nothing more.
  describe ".setup" do
    it "loads the schema the app keeps" do
      touch("bin/rails")
      touch("config/database.yml")
      touch("db/structure.sql")
      expect(described_class.setup(@root)).to eq("bin/rails db:create db:schema:load")
    end

    it "migrates an app that keeps only migrations" do
      touch("bin/rails")
      touch("config/database.yml")
      touch("db/migrate/1_init.rb")
      expect(described_class.setup(@root)).to eq("bin/rails db:create db:migrate")
    end

    it "names none without a database config or bin/rails" do
      touch("bin/rails")
      expect(described_class.setup(@root)).to be_nil
    end
  end
end
