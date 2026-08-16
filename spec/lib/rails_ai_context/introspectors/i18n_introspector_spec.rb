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

  # Without a booted app, I18n.available_locales reports the library's own
  # default, so an app with en and es was described as having one locale - in
  # the same output that listed both files.
  describe "#static_call" do
    def static_result(locales)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "locales"))
        locales.each { |name, body| File.write(File.join(dir, "config", "locales", name), body) }
        yield dir if block_given?
        return described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
      end
    end

    it "reads the available locales from the files on disk" do
      result = static_result(
        "en.yml" => "en:\n  hello: Hello\n  bye: Bye\n",
        "es.yml" => "es:\n  hello: Hola\n"
      )
      expect(result[:available_locales]).to eq(%w[en es])
      expect(result[:total_locale_files]).to eq(2)
    end

    it "computes coverage against the default locale" do
      result = static_result(
        "en.yml" => "en:\n  hello: Hello\n  bye: Bye\n",
        "es.yml" => "es:\n  hello: Hola\n"
      )
      expect(result[:locale_coverage]["es"]).to include(keys: 1, missing: 1, extra: 0)
    end

    it "honours an explicit default locale from config" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n", "es.yml" => "es:\n  hello: Hola\n") do |dir|
        File.write(File.join(dir, "config", "application.rb"), <<~RUBY)
          module Dummy
            class Application < Rails::Application
              config.i18n.default_locale = :es
            end
          end
        RUBY
      end
      expect(result[:default_locale]).to eq("es")
    end

    it "falls back to en when nothing overrides it" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n")
      expect(result[:default_locale]).to eq("en")
    end

    it "does not claim a backend it cannot see" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n")
      expect(result[:backend]).to be_nil
    end

    it "returns no locales when the directory is missing" do
      Dir.mktmpdir do |dir|
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result[:available_locales]).to eq([])
      end
    end
    # An anchor and its alias live in one file - sharing date and number
    # formats between a base locale and a regional one is the common case.
    # Without aliases: true Psych raises, the rescue swallows it, and every
    # locale in that file disappears while Locale Files still lists it.
    it "reads locales from a file that uses YAML anchors" do
      result = static_result(
        "en.yml" => "en: &defaults\n  hello: Hello\nen-GB:\n  <<: *defaults\n  hello: Hullo\n"
      )
      expect(result[:available_locales]).to include("en", "en-GB")
    end

    # A language-name lookup table is an ordinary thing to keep under
    # config/locales, and Rails really does load every one of its top-level
    # keys as an available locale. What it does not have is translations: on
    # Discourse, 138 of 186 coverage rows read "0.0% - 0 unique keys - 11918
    # missing" for languages nobody ever translated.
    describe "a locale-name table under config/locales" do
      let(:result) do
        static_result(
          "en.yml"    => "en:\n  hello: Hello\n  bye: Bye\n",
          "es.yml"    => "es:\n  hello: Hola\n",
          "names.yml" => "aa:\n  name: Afar\nzu:\n  name: Zulu\n"
        )
      end

      it "still lists its keys as available locales, the way Rails does" do
        expect(result[:available_locales]).to include("aa", "zu")
      end

      it "reports no coverage for a locale with no translations of its own" do
        expect(result[:locale_coverage].keys).to contain_exactly("es")
      end

      it "names the locales it left out of coverage" do
        expect(result[:locales_without_translations]).to contain_exactly("aa", "zu")
      end
    end

    it "honours a bare I18n.default_locale in an initializer" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n", "de.yml" => "de:\n  hello: Hallo\n") do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "locale.rb"), "I18n.default_locale = :de\n")
      end
      expect(result[:default_locale]).to eq("de")
    end
  end
end
