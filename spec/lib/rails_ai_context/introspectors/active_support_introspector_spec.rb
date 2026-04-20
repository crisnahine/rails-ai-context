# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ActiveSupportIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns a Hash without error" do
      expect(result).to be_a(Hash)
      expect(result).not_to have_key(:error)
    end

    it "returns concerns as a Hash keyed by directory" do
      expect(result[:concerns]).to be_a(Hash)
    end

    it "returns deprecators as array" do
      expect(result[:deprecators]).to be_an(Array)
    end

    it "returns message_verifier_usage as array" do
      expect(result[:message_verifier_usage]).to be_an(Array)
    end

    it "returns tagged_logging as Hash with :configured" do
      expect(result[:tagged_logging]).to be_a(Hash)
      expect(result[:tagged_logging][:configured]).to eq(true).or(eq(false))
    end

    it "returns common on_load hooks as array" do
      expect(result[:on_load_hooks]).to be_an(Array)
    end

    it "returns cache_usage with a :store key" do
      expect(result[:cache_usage]).to be_a(Hash)
      expect(result[:cache_usage][:store]).to be_a(String)
    end

    context "when a concern file exists" do
      let(:concerns_dir) { File.join(Rails.root, "app/models/concerns") }
      let(:concern_path) { File.join(concerns_dir, "test_trackable.rb") }

      before do
        FileUtils.mkdir_p(concerns_dir)
        File.write(concern_path, <<~RUBY)
          module TestTrackable
            extend ActiveSupport::Concern

            included do
              scope :tracked, -> { where.not(tracked_at: nil) }
            end

            class_methods do
              def track_all!
              end
            end
          end
        RUBY
      end

      after { FileUtils.rm_f(concern_path) }

      it "lists the concern under app/models/concerns with expected flags" do
        entries = result[:concerns]["app/models/concerns"]
        expect(entries).to be_an(Array)
        concern = entries.find { |e| e[:name] == "TestTrackable" }
        expect(concern).not_to be_nil
        expect(concern[:uses_active_support_concern]).to eq(true)
        expect(concern[:class_methods_block]).to eq(true)
      end
    end
  end
end
