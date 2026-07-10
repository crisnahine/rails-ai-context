# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::SchemaVersion do
  describe ".current" do
    it "reads the version from db/schema.rb" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "db"))
        File.write(File.join(root, "db/schema.rb"), <<~RUBY)
          ActiveRecord::Schema[7.1].define(version: 2024_03_20_090000) do
            create_table "users", force: :cascade do |t|
              t.string "email"
            end
          end
        RUBY

        expect(described_class.current(root)).to eq("20240320090000")
      end
    end

    it "reads the version from db/structure.sql (MySQL/mysqldump quoting) when schema.rb is absent" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "db"))
        File.write(File.join(root, "db/structure.sql"), <<~SQL)
          CREATE TABLE `products` (
            `id` bigint NOT NULL AUTO_INCREMENT,
            PRIMARY KEY (`id`)
          ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

          INSERT INTO `schema_migrations` (version) VALUES
          ('20260710111234'),
          ('20260710110345');
        SQL

        expect(described_class.current(root)).to eq("20260710111234")
      end
    end

    it "reads the version from db/structure.sql (Postgres/pg_dump quoting)" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "db"))
        File.write(File.join(root, "db/structure.sql"), <<~SQL)
          CREATE TABLE public.products (
              id bigint NOT NULL
          );

          INSERT INTO "schema_migrations" (version) VALUES
          ('20240101000000'),
          ('20240215080000');
        SQL

        expect(described_class.current(root)).to eq("20240215080000")
      end
    end

    it "returns nil when neither file exists" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "db"))
        expect(described_class.current(root)).to be_nil
      end
    end

    it "prefers db/schema.rb when both files exist" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "db"))
        File.write(File.join(root, "db/schema.rb"), "ActiveRecord::Schema[7.1].define(version: 2024_01_01_000000) do\nend\n")
        File.write(File.join(root, "db/structure.sql"), "INSERT INTO `schema_migrations` (version) VALUES\n('20990101000000');\n")

        expect(described_class.current(root)).to eq("20240101000000")
      end
    end
  end
end
