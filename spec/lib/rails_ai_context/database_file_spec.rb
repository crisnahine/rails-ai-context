# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::DatabaseFile do
  def config(adapter, database)
    ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", { adapter: adapter, database: database })
  end

  # A SQLite compiled with USE_URI, as the sqlite3 gem ships it from 2.0.
  before { allow(described_class).to receive(:uris?).and_return(true) }

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

    it "leaves an in-memory database and every other adapter to the connection" do
      expect(described_class.missing(config("sqlite3", ":memory:"))).to be_nil
      expect(described_class.missing(config("sqlite3", "file:no_such.sqlite3?mode=memory"))).to be_nil
      expect(described_class.missing(config("sqlite3", "file::memory:?cache=shared"))).to be_nil
      expect(described_class.missing(config("postgresql", "no_such_development"))).to be_nil
    end

    it "tests the path inside a file: URI, whichever way the URI spells it" do
      Dir.mktmpdir do |dir|
        there = File.join(dir, "with space.sqlite3")
        FileUtils.touch(there)
        gone = File.join(dir, "no_such.sqlite3")

        [ "file:#{gone}", "file:#{gone}?mode=rwc", "file://#{gone}?cache=shared", "file://localhost#{gone}#frag" ].each do |uri|
          expect(described_class.missing(config("sqlite3", uri))).to be_a(ActiveRecord::NoDatabaseError), uri
        end
        [ "file:#{there.gsub(' ', '%20')}?mode=ro", "file://#{there.gsub(' ', '%20')}" ].each do |uri|
          expect(described_class.missing(config("sqlite3", uri))).to be_nil, uri
        end
      end
    end
  end

  describe "on a SQLite that reads no URIs" do
    before { allow(described_class).to receive(:uris?).and_return(false) }

    it "takes a file: name as the file it is, from the working directory" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect(described_class.missing?(config("sqlite3", "file:app.sqlite3?mode=memory"))).to be(true)
          expect(described_class.in_memory?(config("sqlite3", "file:app.sqlite3?mode=memory"))).to be(false)
          FileUtils.touch("file:app.sqlite3?mode=memory")
          expect(described_class.missing?(config("sqlite3", "file:app.sqlite3?mode=memory"))).to be(false)
        end
      end
    end
  end

  describe ".missing?" do
    it "answers whether a SQLite database's file is not there" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "development.sqlite3")

        expect(described_class.missing?(config("sqlite3", path))).to be(true)
        FileUtils.touch(path)
        expect(described_class.missing?(config("sqlite3", path))).to be(false)
        expect(described_class.missing?(config("postgresql", "no_such"))).to be(false)
      end
    end
  end

  describe ".in_memory?" do
    it "is true for a SQLite database that keeps no file" do
      answers = [ ":memory:", "file:x?mode=memory", "file::memory:", "file:x.sqlite3?mode=ro", "storage/x.sqlite3" ].map do |database|
        described_class.in_memory?(config("sqlite3", database))
      end

      expect(answers).to eq([ true, true, true, false, false ])
      expect(described_class.in_memory?(config("postgresql", ":memory:"))).to be(false)
    end
  end
end
