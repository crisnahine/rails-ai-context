# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ActiveStorageIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    context "with attachment macros in model source" do
      let(:fixture_model) { File.join(Rails.root, "app/models/profile.rb") }

      before do
        File.write(fixture_model, <<~RUBY)
          class Profile < ApplicationRecord
            has_one_attached :avatar
            has_many_attached :documents
          end
        RUBY
      end

      after { FileUtils.rm_f(fixture_model) }

      it "detects has_one_attached" do
        avatars = result[:attachments].select { |a| a[:name] == "avatar" }
        expect(avatars.size).to eq(1)
        expect(avatars.first[:type]).to eq("has_one_attached")
        expect(avatars.first[:model]).to eq("Profile")
      end

      it "detects has_many_attached" do
        docs = result[:attachments].select { |a| a[:name] == "documents" }
        expect(docs.size).to eq(1)
        expect(docs.first[:type]).to eq("has_many_attached")
      end
    end

    context "with variants defined in model source" do
      let(:fixture_model) { File.join(Rails.root, "app/models/document.rb") }

      before do
        File.write(fixture_model, <<~RUBY)
          class Document < ApplicationRecord
            has_one_attached :file
            has_many_attached :images

            def thumbnail
              file.variant(:thumb, resize_to_limit: [100, 100])
            end
          end
        RUBY
      end

      after { FileUtils.rm_f(fixture_model) }

      it "detects variant names via AST" do
        variants = result[:variants]
        expect(variants).to include(a_hash_including(model: "Document", name: "thumb"))
      end

      it "detects both attachment types via AST" do
        attachments = result[:attachments].select { |a| a[:model] == "Document" }
        types = attachments.map { |a| a[:type] }
        expect(types).to include("has_one_attached", "has_many_attached")
      end
    end

    it "extracts storage services from config" do
      expect(result[:storage_services]).to include("local")
      expect(result[:storage_services]).to include("test")
    end

    it "returns false for direct_upload when none present" do
      expect(result[:direct_upload]).to be false
    end

    it "returns installed flag as boolean" do
      expect(result[:installed]).to be(true).or be(false)
    end
  end
end
