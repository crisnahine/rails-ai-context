# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SeedsIntrospector do
  let(:app) { Rails.application }
  let(:introspector) { described_class.new(app) }

  before do
    @db_dir = File.join(app.root.to_s, "db")
    FileUtils.mkdir_p(@db_dir)

    File.write(File.join(@db_dir, "seeds.rb"), <<~RUBY)
      # Default seeds
      if Rails.env.development?
        User.find_or_create_by!(email: "admin@example.com") do |u|
          u.name = "Admin"
        end

        10.times do
          Post.create!(
            title: Faker::Lorem.sentence,
            user: User.first
          )
        end
      end

      Dir[Rails.root.join("db/seeds/*.rb")].sort.each { |f| load f }
    RUBY

    FileUtils.mkdir_p(File.join(@db_dir, "seeds"))
    File.write(File.join(@db_dir, "seeds/categories.rb"), <<~RUBY)
      Comment.find_or_create_by!(body: "General")
    RUBY
  end

  after do
    FileUtils.rm_f(File.join(@db_dir, "seeds.rb"))
    FileUtils.rm_rf(File.join(@db_dir, "seeds"))
  end

  describe "#call" do
    subject(:result) { introspector.call }

    it "analyzes seeds.rb" do
      seeds = result[:seeds_file]
      expect(seeds[:exists]).to be true
      expect(seeds[:uses_find_or_create]).to be true
      expect(seeds[:uses_create]).to be true
      expect(seeds[:uses_faker]).to be true
      expect(seeds[:environment_conditional]).to be true
      expect(seeds[:loads_directory]).to be true
    end

    it "discovers seed files in db/seeds/" do
      expect(result[:seed_files].size).to eq(1)
      expect(result[:seed_files].first[:name]).to eq("categories")
    end

    it "detects seeded models" do
      models = result[:models_seeded]
      expect(models).to include("User", "Post", "Comment")
      expect(models).not_to include("Faker", "Rails", "Dir")
    end

    it "does not return an error" do
      expect(result[:error]).to be_nil
    end

    # Date, Time, Random and Set are Ruby classes, and Importer a plain object: none is a model.
    context "when a seed file builds plain Ruby objects beside its records" do
      before do
        stub_const("Vendor::Widget", Class.new(ActiveRecord::Base))
        File.write(File.join(@db_dir, "seeds.rb"), <<~RUBY)
          Post.create!(title: "Hello", published_on: Date.new(2024, 5, 1), published_at: Time.new(2024))
          rng = Random.new(42)
          tags = Set.new
          Importer.new.call
          Vendor::Widget.create!(name: "A")
        RUBY
        FileUtils.rm_rf(File.join(@db_dir, "seeds"))
      end

      it "lists only the app's models and the records a loaded library defines" do
        expect(result[:models_seeded]).to eq(%w[Post Vendor::Widget])
      end
    end
  end

  describe "#call on an app read without booting" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.rm_rf(tmpdir) }

    it "lists only the models the app has" do
      FileUtils.mkdir_p(File.join(tmpdir, "app/models"))
      FileUtils.mkdir_p(File.join(tmpdir, "db"))
      File.write(File.join(tmpdir, "app/models/application_record.rb"), "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n")
      File.write(File.join(tmpdir, "app/models/post.rb"), "class Post < ApplicationRecord\nend\n")
      File.write(File.join(tmpdir, "db/seeds.rb"), <<~RUBY)
        Post.create!(title: "Hello", published_on: Date.new(2024, 5, 1), published_at: Time.new(2024))
        rng = Random.new(42)
        tags = Set.new
      RUBY

      result = described_class.new(RailsAiContext::StaticApp.new(tmpdir)).call

      expect(result[:models_seeded]).to eq(%w[Post])
    end
  end
end
