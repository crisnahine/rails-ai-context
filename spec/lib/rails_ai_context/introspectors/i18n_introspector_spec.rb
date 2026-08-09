# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::I18nIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns default locale as en" do
      expect(result[:default_locale]).to eq("en")
    end

    it "returns available locales including en" do
      expect(result[:available_locales]).to include("en")
      expect(result[:available_locales]).to all(be_a(String))
    end

    it "returns backend class name as a non-empty string" do
      expect(result[:backend]).to be_a(String)
      expect(result[:backend]).not_to be_empty
    end

    it "discovers locale files with correct names" do
      files = result[:locale_files].map { |f| f[:file] }
      expect(files).to include("en.yml")
    end

    # en.yml has: en > hello, en > posts > index > title, en > posts > show > title
    # That's 3 leaf keys
    it "counts keys accurately in locale files" do
      en_file = result[:locale_files].find { |f| f[:file] == "en.yml" }
      expect(en_file[:key_count]).to eq(3)
    end

    it "does not have parse_error on valid YAML" do
      en_file = result[:locale_files].find { |f| f[:file] == "en.yml" }
      expect(en_file).not_to have_key(:parse_error)
    end

    it "returns correct total_locale_files count" do
      expect(result[:total_locale_files]).to be >= 1
      expect(result[:total_locale_files]).to eq(result[:locale_files].size)
    end

    context "with invalid YAML locale file" do
      let(:bad_locale) { File.join(Rails.root, "config/locales/bad.yml") }

      before do
        File.write(bad_locale, "invalid: yaml: [broken: {")
      end

      after { FileUtils.rm_f(bad_locale) }

      it "marks the file with parse_error" do
        bad_file = result[:locale_files].find { |f| f[:file] == "bad.yml" }
        expect(bad_file[:parse_error]).to be true
      end
    end

    # en.yml carries hello, posts.index.title and posts.show.title.
    context "with a locale that translates one key and adds four of its own" do
      let(:es_locale) { File.join(Rails.root, "config/locales/es.yml") }

      before do
        File.write(es_locale, <<~YML)
          es:
            hello: "Hola"
            solo:
              uno: "1"
              dos: "2"
              tres: "3"
              cuatro: "4"
        YML
        allow(I18n).to receive(:available_locales).and_return([ :en, :es ])
      end

      after { FileUtils.rm_f(es_locale) }

      it "measures coverage against the default locale's own keys" do
        expect(result[:locale_coverage]["es"]).to include(
          keys: 5, coverage_pct: 33.3, missing: 2, extra: 4
        )
      end
    end

    context "with a locale file whose root key is a symbol" do
      let(:es_locale) { File.join(Rails.root, "config/locales/es.yml") }

      before do
        File.write(es_locale, <<~YML)
          :es:
            hello: "Hola"
        YML
        allow(I18n).to receive(:available_locales).and_return([ :en, :es ])
      end

      after { FileUtils.rm_f(es_locale) }

      it "strips the root so its keys still line up with the default locale" do
        expect(result[:locale_coverage]["es"]).to include(keys: 1, missing: 2, extra: 0)
      end
    end
  end
end
