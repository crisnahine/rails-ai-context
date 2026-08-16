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
    # Discourse, 138 of its 187 locales define 2 keys each and score 0.0%
    # against an English locale with 11,918.
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

      # Naming them keeps 138 rows of zeroes off the screen, but the row
      # itself is the only place the numbers live - a translation genuinely
      # started below the rounding floor still has to be able to read its own
      # missing count.
      it "still carries a coverage row for a locale that rounds to zero" do
        expect(result[:locale_coverage].keys).to contain_exactly("es", "aa", "zu")
        expect(result[:locale_coverage]["aa"]).to include(coverage_pct: 0.0, missing: 2)
      end

      it "names the locales it left out of coverage" do
        expect(result[:locales_without_translations].map { |l| l[:locale] }).to contain_exactly("aa", "zu")
      end

      # A locale can define plenty of keys and still share none with the
      # default. Naming it without the count reads as "not translated"; the
      # count says what it actually is.
      it "carries each left-out locale's own key count" do
        expect(result[:locales_without_translations]).to include(hash_including(locale: "aa", keys: 1))
      end
    end

    # Locale files are usually named for their locale, but nothing requires it.
    # A locale carried in a shared file has translations; saying it has none
    # would be a positive claim that is false.
    it "scores a locale whose translations live in a shared file" do
      result = static_result(
        "en.yml"           => "en:\n  hello: Hello\n  bye: Bye\n",
        "translations.yml" => "es:\n  hello: Hola\n"
      )

      expect(result[:locale_coverage].keys).to contain_exactly("es")
      expect(result[:locales_without_translations]).to be_empty
    end

    # A locale can have both: a file of its own AND keys in a shared file.
    # Reading only the named one scores it on a fraction of what it translates.
    it "reads a locale's own file and the shared file together" do
      result = static_result(
        "en.yml"     => "en:\n  a: A\n  b: B\n",
        "es.yml"     => "es:\n  only_es: X\n",
        "shared.yml" => "es:\n  a: Aa\n  b: Bb\n"
      )

      expect(result[:locales_without_translations]).to be_empty
      expect(result[:locale_coverage]["es"]).to include(coverage_pct: 100.0, extra: 1)
    end

    # Reading every file to answer "which files hold locale X" once per locale
    # is O(locales x files): on Discourse, 187 locales over 108 files took the
    # introspector from under a second to four and a half minutes.
    it "reads each locale file a bounded number of times" do
      reads = 0
      allow(RailsAiContext::SafeFile).to receive(:read).and_wrap_original do |orig, *args, **kw|
        reads += 1
        orig.call(*args, **kw)
      end

      files = (1..12).to_h { |i| [ "loc#{i}.yml", "loc#{i}:\n  hello: H#{i}\n" ] }
      static_result(files.merge("en.yml" => "en:\n  hello: Hello\n"))

      # One pass to index the files, plus each locale's own matched files. The
      # per-locale full scan this guards against is 13 x 13 = 169 and up.
      expect(reads).to be < 100
    end

    # GitLab's config/application.rb carries `# config.i18n.default_locale =
    # :de` as a commented example, and an unanchored match took it as the
    # app's choice: every coverage line then read "against de" for an app that
    # runs in English.
    it "ignores a default_locale that is commented out" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n") do |dir|
        File.write(File.join(dir, "config", "application.rb"), <<~RUBY)
          module Dummy
            class Application < Rails::Application
              # config.i18n.default_locale = :de
            end
          end
        RUBY
      end

      expect(result[:default_locale]).to eq("en")
    end

    # Coverage is measured against the default locale's keys. With none to
    # measure against, every locale scores zero - and calling them all
    # untranslated says something false about each one.
    it "claims nothing about coverage when the default locale has no keys" do
      result = static_result(
        "en.yml" => "en:\n  a: A\n",
        "fr.yml" => "fr:\n  a: Aa\n"
      ) { |dir| File.write(File.join(dir, "config", "application.rb"), "config.i18n.default_locale = :de\n") }

      expect(result[:default_locale]).to eq("de")
      expect(result[:locale_coverage]).to be_empty
      expect(result[:locales_without_translations]).to be_empty
    end

    it "honours a bare I18n.default_locale in an initializer" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n", "de.yml" => "de:\n  hello: Hallo\n") do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "locale.rb"), "I18n.default_locale = :de\n")
      end
      expect(result[:default_locale]).to eq("de")
    end

    # config/environments/*.rb arrive in glob order, so the first file to
    # carry an assignment won whatever environment it belonged to - and
    # development.rb sorts ahead of production.rb.
    it "prefers the running environment's file over the other environments" do
      original = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "production"
      result = static_result("en.yml" => "en:\n  hello: Hello\n", "ja.yml" => "ja:\n  hello: Konnichiwa\n") do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "environments"))
        File.write(File.join(dir, "config", "environments", "development.rb"), "config.i18n.default_locale = :ja\n")
        File.write(File.join(dir, "config", "environments", "production.rb"), "config.i18n.default_locale = :en\n")
      end
      expect(result[:default_locale]).to eq("en")
    ensure
      ENV["RAILS_ENV"] = original
    end
  end
end
