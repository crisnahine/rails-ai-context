# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::DatabaseFile do
  def config(adapter, database)
    ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", { adapter: adapter, database: database })
  end

  describe ".missing" do
    it "names a SQLite database whose file is not there" do
      error = described_class.missing(config("sqlite3", "storage/no_such.sqlite3"))

      expect(error).to be_a(ActiveRecord::NoDatabaseError)
      expect(error.message).to include("storage/no_such.sqlite3")
    end

    it "is nil for a SQLite file that is there" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "development.sqlite3")
        FileUtils.touch(path)

        expect(described_class.missing(config("sqlite3", path))).to be_nil
      end
    end

    it "reads a relative path from Rails.root, as the adapter does" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "storage"))
        FileUtils.touch(File.join(dir, "storage", "development.sqlite3"))
        allow(Rails).to receive(:root).and_return(Pathname.new(dir))

        expect(described_class.missing(config("sqlite3", "storage/development.sqlite3"))).to be_nil
      end
    end

    it "leaves an in-memory database, a file: URI and every other adapter to the connection" do
      expect(described_class.missing(config("sqlite3", ":memory:"))).to be_nil
      expect(described_class.missing(config("sqlite3", "file:no_such.sqlite3?mode=memory"))).to be_nil
      expect(described_class.missing(config("postgresql", "no_such_development"))).to be_nil
    end
  end
end
