# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ViewTemplateIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns templates hash" do
      expect(result[:templates]).to be_a(Hash)
    end

    it "returns partials hash" do
      expect(result[:partials]).to be_a(Hash)
    end

    it "discovers templates in posts directory" do
      expect(result[:templates].keys).to include("posts/index.html.erb")
      expect(result[:templates].keys).to include("posts/show.html.erb")
    end

    it "excludes partials from templates" do
      template_names = result[:templates].keys
      expect(template_names.none? { |n| File.basename(n).start_with?("_") }).to be true
    end

    it "discovers partials" do
      expect(result[:partials].keys).to include("posts/_post.html.erb")
    end

    it "counts lines for templates" do
      index = result[:templates]["posts/index.html.erb"]
      expect(index[:lines]).to be > 0
    end

    it "extracts partial references from templates" do
      index = result[:templates]["posts/index.html.erb"]
      expect(index[:partials]).to be_an(Array)
    end

    it "extracts stimulus references from templates" do
      show = result[:templates]["posts/show.html.erb"]
      expect(show[:stimulus]).to be_an(Array)
    end

    it "excludes layouts from templates" do
      template_names = result[:templates].keys
      expect(template_names.none? { |n| n.include?("layouts/") }).to be true
    end
  end
end
