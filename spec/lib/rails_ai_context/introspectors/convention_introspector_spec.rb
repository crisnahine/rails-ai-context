# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::ConventionIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns architecture as an array" do
      expect(result[:architecture]).to be_an(Array)
    end

    it "returns patterns as an array" do
      expect(result[:patterns]).to be_an(Array)
    end

    it "returns directory_structure as a hash" do
      expect(result[:directory_structure]).to be_a(Hash)
    end

    it "detects models directory" do
      expect(result[:directory_structure]).to have_key("app/models")
    end

    it "returns config_files as an array" do
      expect(result[:config_files]).to be_an(Array)
    end

    it "returns custom_directories as an array" do
      expect(result[:custom_directories]).to be_an(Array)
    end

    context "with SolidQueue gem present" do
      let(:gemfile_lock) { File.join(Rails.root, "Gemfile.lock") }

      before do
        File.write(gemfile_lock, <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              solid_queue (1.0.0)
        LOCK
      end

      after { FileUtils.rm_f(gemfile_lock) }

      it "detects solid_queue in architecture" do
        expect(result[:architecture]).to include("solid_queue")
      end
    end

    context "with dry-rb gems present" do
      let(:gemfile_lock) { File.join(Rails.root, "Gemfile.lock") }

      before do
        File.write(gemfile_lock, <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              dry-validation (1.10.0)
              dry-monads (1.6.0)
        LOCK
      end

      after { FileUtils.rm_f(gemfile_lock) }

      it "detects dry_rb in architecture" do
        expect(result[:architecture]).to include("dry_rb")
      end
    end

    context "with an empty app/models/concerns/ directory (only a .keep file)" do
      let(:concerns_dir) { File.join(Rails.root, "app/models/concerns") }

      before do
        FileUtils.mkdir_p(concerns_dir)
        FileUtils.touch(File.join(concerns_dir, ".keep"))
      end

      after { FileUtils.rm_rf(concerns_dir) }

      it "does not claim concerns_models - the directory holds no concern files" do
        expect(result[:architecture]).not_to include("concerns_models")
      end
    end

    context "with a real concern file in app/models/concerns/" do
      let(:concerns_dir) { File.join(Rails.root, "app/models/concerns") }

      before do
        FileUtils.mkdir_p(concerns_dir)
        File.write(File.join(concerns_dir, "searchable.rb"), <<~RUBY)
          module Searchable
            extend ActiveSupport::Concern
          end
        RUBY
      end

      after { FileUtils.rm_rf(concerns_dir) }

      it "detects concerns_models" do
        expect(result[:architecture]).to include("concerns_models")
      end
    end

    context "with an empty app/controllers/concerns/ directory (only a .keep file)" do
      let(:concerns_dir) { File.join(Rails.root, "app/controllers/concerns") }

      before do
        FileUtils.mkdir_p(concerns_dir)
        FileUtils.touch(File.join(concerns_dir, ".keep"))
      end

      after { FileUtils.rm_rf(concerns_dir) }

      it "does not claim concerns_controllers - the directory holds no concern files" do
        expect(result[:architecture]).not_to include("concerns_controllers")
      end
    end

    context "with custom app directories" do
      let(:custom_dir) { File.join(Rails.root, "app/services") }

      before { FileUtils.mkdir_p(custom_dir) }
      after { FileUtils.rm_rf(custom_dir) }

      it "detects non-standard directories under app/" do
        expect(result[:custom_directories]).to include("services")
      end
    end

    context "with async query usage in a controller" do
      let(:controller_dir) { File.join(Rails.root, "app/controllers") }
      let(:controller_path) { File.join(controller_dir, "async_demo_controller.rb") }

      before do
        FileUtils.mkdir_p(controller_dir)
        File.write(controller_path, <<~RUBY)
          class AsyncDemoController < ApplicationController
            def index
              @users  = User.all.load_async
              @count  = User.async_count
            end
          end
        RUBY
      end

      after { FileUtils.rm_f(controller_path) }

      it "detects async_queries pattern" do
        expect(result[:patterns]).to include("async_queries")
      end
    end

    # Built in a tmpdir rather than Rails.root: these need their own schema.rb,
    # and the dummy app ships one every other example depends on.
    def patterns_for(models:, schema: nil)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        models.each { |name, source| File.write(File.join(dir, "app/models", name), source) }
        if schema
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db/schema.rb"), schema)
        end

        app = double("app", root: Pathname.new(dir), config: double(api_only: false))
        described_class.new(app).call[:patterns]
      end
    end

    context "soft delete" do
      it "detects the pattern from a deleted_at column in the dump" do
        patterns = patterns_for(
          models: { "thing.rb" => "class Thing < ApplicationRecord\nend\n" },
          schema: %(create_table "things" do |t|\n  t.datetime "deleted_at"\nend\n)
        )

        expect(patterns).to include("soft_delete")
      end

      it "does not fire on a model that merely mentions deleted_at" do
        patterns = patterns_for(
          models: { "thing.rb" => "class Thing < ApplicationRecord\n  # deleted_at was rejected here\nend\n" },
          schema: %(create_table "things" do |t|\n  t.string "name"\nend\n)
        )

        expect(patterns).not_to include("soft_delete")
      end

      it "falls back to model source when there is no readable dump" do
        patterns = patterns_for(
          models: { "thing.rb" => "class Thing < ApplicationRecord\n  scope :kept, -> { where(deleted_at: nil) }\nend\n" }
        )

        expect(patterns).to include("soft_delete")
      end
    end

    context "when a model file declares more than one class" do
      it "reads past a first class that names no superclass" do
        patterns = patterns_for(
          models: { "widget.rb" => "class WidgetSupport\nend\n\nclass Widget < ActiveSupport::CurrentAttributes\nend\n" }
        )

        expect(patterns).to include("current_attributes")
      end

      it "sees a class nested inside another class" do
        patterns = patterns_for(
          models: { "gadget.rb" => "class Gadget\n  class Inner < ActiveSupport::CurrentAttributes\n  end\nend\n" }
        )

        expect(patterns).to include("current_attributes")
      end
    end

    context "single table inheritance" do
      let(:models) do
        {
          "vehicle.rb" => "class Vehicle < ApplicationRecord\nend\n",
          "car.rb"     => "class Car < Vehicle\nend\n"
        }
      end

      it "detects sti when the parent table carries a type column" do
        patterns = patterns_for(
          models: models,
          schema: %(create_table "vehicles" do |t|\n  t.string "type"\nend\n)
        )

        expect(patterns).to include("sti")
      end

      it "stays quiet when the parent table has no type column" do
        patterns = patterns_for(
          models: models,
          schema: %(create_table "vehicles" do |t|\n  t.string "name"\nend\n)
        )

        expect(patterns).not_to include("sti")
      end
    end

    context "without async query usage anywhere" do
      it "does not include async_queries in patterns" do
        expect(result[:patterns]).not_to include("async_queries")
      end
    end

    context "with async query patterns appearing only in comments" do
      let(:controller_dir)  { File.join(Rails.root, "app/controllers") }
      let(:controller_path) { File.join(controller_dir, "comment_only_controller.rb") }

      before do
        FileUtils.mkdir_p(controller_dir)
        File.write(controller_path, <<~RUBY)
          class CommentOnlyController < ApplicationController
            # We used to call User.async_count here but removed it.
            # TODO: bring back load_async once the perf review lands.
            def index
              @users = User.all
            end
          end
        RUBY
      end

      after { FileUtils.rm_f(controller_path) }

      it "does NOT detect async_queries (comments are not real usage)" do
        expect(result[:patterns]).not_to include("async_queries")
      end
    end
  end

  describe "#gem_present?" do
    around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

    def introspect(lock)
      File.write(File.join(@root, "Gemfile.lock"), lock)
      described_class.new(double("app", root: @root))
    end

    it "sees a gem in the PATH section" do
      lock = <<~LOCK
        PATH
          remote: engines/billing
          specs:
            dry-monads (1.6.0)
      LOCK
      expect(introspect(lock).send(:gem_present?, "dry-monads")).to be(true)
    end

    it "does not match a gem whose name merely starts with the query" do
      lock = <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            dry-monads-extras (1.0.0)
      LOCK
      expect(introspect(lock).send(:gem_present?, "dry-monads")).to be(false)
    end
  end

  describe "source across every directory of a kind" do
    it "counts a pack's models in the layer count" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "models"))
        File.write(File.join(dir, "app", "models", "user.rb"), "class User < ApplicationRecord\nend\n")
        File.write(File.join(dir, "packs", "billing", "app", "models", "invoice.rb"),
                   "class Invoice < ApplicationRecord\nend\n")

        app = double("app", root: Pathname.new(dir), config: double(api_only: false))
        structure = described_class.new(app).call[:directory_structure]
        expect(structure["app/models"]).to eq(2)
      end
    end

    # The Custom Directories list names them, and the only section carrying
    # file counts walked a fixed list that had never heard of app/workers.
    it "counts the files of any other directory the app keeps under app/" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "workers", "billing"))
        FileUtils.mkdir_p(File.join(dir, "app", "tools"))
        File.write(File.join(dir, "app", "workers", "billing", "create_worker.rb"),
                   "class Billing::CreateWorker
  include Sidekiq::Job
end
")
        File.write(File.join(dir, "app", "tools", "probe.rb"), "class Probe
end
")

        app = double("app", root: Pathname.new(dir), config: double(api_only: false))
        structure = described_class.new(app).call[:directory_structure]

        expect(structure["app/workers"]).to eq(1)
        expect(structure["app/tools"]).to eq(1)
      end
    end

    it "detects STI under a namespaced parent" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "admin"))
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "app", "models", "admin", "report.rb"),
                   "class Admin::Report < ApplicationRecord\nend\n")
        File.write(File.join(dir, "app", "models", "admin", "weekly_report.rb"),
                   "class Admin::WeeklyReport < Admin::Report\nend\n")
        File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
          create_table "reports" do |t|
            t.string "type"
          end
        RUBY

        app = double("app", root: Pathname.new(dir), config: double(api_only: false))
        patterns = described_class.new(app).call[:patterns]
        expect(patterns).to include("sti")
      end
    end
  end
end
