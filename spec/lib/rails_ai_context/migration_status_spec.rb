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
end
