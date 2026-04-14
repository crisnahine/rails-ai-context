# frozen_string_literal: true

require "spec_helper"

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

    context "without async query usage anywhere" do
      it "does not include async_queries in patterns" do
        expect(result[:patterns]).not_to include("async_queries")
      end
    end
  end
end
