# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::PendingMigrations do
  around do |example|
    Dir.mktmpdir do |dir|
      @migrate = File.join(dir, "db/migrate")
      FileUtils.mkdir_p(@migrate)
      %w[20240101000000_create_users 20240301000000_create_posts 20240201000000_add_index].each do |name|
        File.write(File.join(@migrate, "#{name}.rb"), "class #{name.sub(/\A\d+_/, '').camelize} < ActiveRecord::Migration[7.2]; end\n")
      end
      example.run
    end
  end

  describe ".for" do
    it "treats every migration as pending when nothing is known to be applied" do
      expect(described_class.for(migrate_dir: @migrate, applied: []).map { |m| m[:version] })
        .to eq(%w[20240101000000 20240201000000 20240301000000])
    end

    # An out-of-order merge: the newest version is applied, an earlier one is
    # not. Comparing against the max version alone reported nothing pending.
    it "reports an unapplied earlier migration when a later one is applied" do
      pending = described_class.for(migrate_dir: @migrate, applied: %w[20240101000000 20240301000000])
      expect(pending).to eq([ { version: "20240201000000", name: "Add index" } ])
    end

    it "falls back to a max version when that is all the schema records" do
      pending = described_class.for(migrate_dir: @migrate, applied: "20240201000000")
      expect(pending.map { |m| m[:version] }).to eq(%w[20240301000000])
    end

    it "compares numerically so a legacy zero-padded version is not pending" do
      File.write(File.join(@migrate, "001_legacy.rb"), "class Legacy; end\n")
      expect(described_class.for(migrate_dir: @migrate, applied: %w[1 20240101000000 20240201000000 20240301000000])).to eq([])
    end

    it "answers everything pending when applied is unknown and the directory is empty otherwise" do
      Dir.mktmpdir { |empty| expect(described_class.for(migrate_dir: empty, applied: nil)).to eq([]) }
    end
  end

  describe ".migrate_dir_for" do
    it "maps a named schema dump to its migrate directory" do
      expect(described_class.migrate_dir_for("/app", "/app/db/queue_schema.rb")).to eq("/app/db/queue_migrate")
      expect(described_class.migrate_dir_for("/app", "/app/db/schema.rb")).to eq("/app/db/migrate")
      expect(described_class.migrate_dir_for("/app")).to eq("/app/db/migrate")
    end
  end
end
