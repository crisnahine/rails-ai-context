# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ActionTextIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns installed as false when ActionText is not loaded" do
      expect(result[:installed]).to be false
    end

    context "with rich text macros in model source" do
      let(:fixture_model) { File.join(Rails.root, "app/models/article.rb") }

      before do
        File.write(fixture_model, <<~RUBY)
          class Article < ApplicationRecord
            has_rich_text :content
            has_rich_text :summary
          end
        RUBY
      end

      after { FileUtils.rm_f(fixture_model) }

      it "detects all rich text fields" do
        fields = result[:rich_text_fields].select { |f| f[:model] == "Article" }
        expect(fields.size).to eq(2)
        expect(fields.map { |f| f[:field] }).to contain_exactly("content", "summary")
      end
    end

    context "without rich text macros" do
      it "returns empty rich_text_fields" do
        expect(result[:rich_text_fields]).to eq([])
      end
    end
  end

  describe "models in a pack" do
    let(:pack_model) { File.join(Rails.root, "packs", "billing", "app", "models", "invoice.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(pack_model))
      File.write(pack_model, "class Invoice < ApplicationRecord\n  has_rich_text :notes\nend\n")
    end

    after { FileUtils.rm_rf(File.join(Rails.root, "packs")) }

    it "reports a pack model's rich text field" do
      fields = described_class.new(Rails.application).call[:rich_text_fields]
      expect(fields).to include(model: "Invoice", field: "notes")
    end
  end
end
