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

    # A file the reader refuses reads as refused everywhere: it cannot carry a
    # key count and its locales in one section while the coverage pass skips it
    # in another.
    context "with a locale file above the size the reader accepts" do
      let(:es_locale) { File.join(Rails.root, "config/locales/es.yml") }

      before do
        File.write(es_locale, "es:\n" + (1..200).map { |i| "  key#{i}: \"#{'x' * 20}\"\n" }.join)
        allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(1_000)
        allow(I18n).to receive(:available_locales).and_return([ :en, :es ])
      end

      after { FileUtils.rm_f(es_locale) }

      it "reports the refusal the same way everywhere" do
        big_file = result[:locale_files].find { |f| f[:file] == "es.yml" }
        expect(big_file[:parse_error]).to be true
        expect(big_file).not_to have_key(:key_count)
        expect(result[:locale_coverage]["es"][:keys]).to eq(0)
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

    # Rails applies config.i18n after every initializer has run, so both keys
    # take the last assignment, not the first file that carries one.
    it "takes the default locale an initializer sets over application.rb's" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n", "es.yml" => "es:\n  hello: Hola\n") do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "application.rb"), <<~RUBY)
          module Dummy
            class Application < Rails::Application
              config.i18n.default_locale = :en
              config.i18n.available_locales = [:en]
            end
          end
        RUBY
        File.write(File.join(dir, "config", "initializers", "i18n.rb"), <<~RUBY)
          Rails.application.configure do
            config.i18n.default_locale = :es
            config.i18n.available_locales = [:en, :es]
          end
        RUBY
      end

      expect(result[:default_locale]).to eq("es")
      expect(result[:available_locales]).to eq(%w[en es])
    end

    it "falls back to en when nothing overrides it" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n")
      expect(result[:default_locale]).to eq("en")
    end

    it "does not claim a backend it cannot see" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n")
      expect(result[:backend]).to be_nil
    end

    # I18n.fallbacks belongs to whichever process asks, and no app booted in
    # this one. Static Mastodon reported "en -> en" as the app's setting.
    it "does not report the library's own fallbacks as the app's" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n")
      expect(result).to have_key(:fallbacks)
      expect(result[:fallbacks]).to be_nil
      expect(result[:unavailable_sections]).to include("backend", "fallbacks")
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

    # Only the locale-rooted key paths are kept per file; a locale's own paths
    # are derived by stripping that root. These numbers are what that derivation
    # has to reproduce, across files holding one root and files holding several.
    it "scores every locale the same whether its root shares a file or not" do
      result = static_result(
        "en.yml"     => "en:\n  a: A\n  b: B\n  c: C\n  d: D\n",
        "fr.yml"     => "fr:\n  a: A\n  b: B\n",
        "shared.yml" => "de:\n  a: A\nes:\n  a: A\n  b: B\n  c: C\nfr:\n  c: C\n  own: X\n"
      )

      expect(result[:available_locales]).to eq(%w[de en es fr])
      expect(result[:locale_coverage]).to eq(
        "de" => { keys: 1, missing: 3, extra: 0, coverage_pct: 25.0 },
        "es" => { keys: 3, missing: 1, extra: 0, coverage_pct: 75.0 },
        "fr" => { keys: 4, missing: 1, extra: 1, coverage_pct: 75.0 }
      )
      expect(result[:locales_without_translations]).to be_empty
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

    # I18n::Railtie applies app.config.i18n from after_initialize, which runs
    # once every initializer has, so config.i18n overwrites a bare
    # I18n.default_locale set in an initializer rather than losing to it.
    it "takes application.rb's config.i18n default locale over an initializer's bare I18n one" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n", "de.yml" => "de:\n  hello: Hallo\n") do |dir|
        File.write(File.join(dir, "config", "application.rb"), "config.i18n.default_locale = :en\n")
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "locale.rb"), "I18n.default_locale = :de\n")
      end
      expect(result[:default_locale]).to eq("en")
    end

    # Two initializers, one spelling: the later file is the one that lands.
    it "takes the last bare I18n.default_locale when nothing buffers one" do
      result = static_result("en.yml" => "en:\n  hello: Hello\n", "de.yml" => "de:\n  hello: Hallo\n") do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
        File.write(File.join(dir, "config", "initializers", "a_locale.rb"), "I18n.default_locale = :en\n")
        File.write(File.join(dir, "config", "initializers", "z_locale.rb"), "I18n.default_locale = :de\n")
      end
      expect(result[:default_locale]).to eq("de")
    end

    # With the running environment's file absent every environment is read,
    # and they are alternatives rather than a sequence: letting the last one
    # by filename win makes test.rb beat production.rb for no reason.
    it "lets no environment decide when the fallback read several that disagree" do
      original = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "staging"
      result = static_result("en.yml" => "en:\n  hello: Hello\n", "ja.yml" => "ja:\n  hello: Konnichiwa\n") do |dir|
        File.write(File.join(dir, "config", "application.rb"), "config.i18n.default_locale = :ja\n")
        FileUtils.mkdir_p(File.join(dir, "config", "environments"))
        File.write(File.join(dir, "config", "environments", "production.rb"), "config.i18n.default_locale = :en\n")
        File.write(File.join(dir, "config", "environments", "test.rb"), "config.i18n.default_locale = :de\n")
      end
      expect(result[:default_locale]).to eq("ja")
    ensure
      ENV["RAILS_ENV"] = original
    end

    # Agreeing on a value is not a guess, so the fallback still answers.
    it "keeps a fallback environment value every environment agrees on" do
      original = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "staging"
      result = static_result("en.yml" => "en:\n  hello: Hello\n", "de.yml" => "de:\n  hello: Hallo\n") do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "environments"))
        File.write(File.join(dir, "config", "environments", "production.rb"), "config.i18n.default_locale = :de\n")
        File.write(File.join(dir, "config", "environments", "test.rb"), "config.i18n.default_locale = :de\n")
      end
      expect(result[:default_locale]).to eq("de")
    ensure
      ENV["RAILS_ENV"] = original
    end

    # Only the running environment's file runs, so another environment's
    # assignment says nothing about this one.
    it "reads only the running environment's file" do
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

    # Rails builds available_locales from the load path only while the app
    # leaves the setting alone. Once the app assigns it, that list IS
    # available_locales, and reading the files instead invents locales the app
    # disabled: Mastodon enables 97 and ships files for 106.
    describe "an explicit available_locales assignment" do
      def with_config(initializers, application: nil, &block)
        static_result(
          "en.yml"  => "en:\n  hello: Hello\n  bye: Bye\n",
          "es.yml"  => "es:\n  hello: Hola\n",
          "tlh.yml" => "tlh:\n  hello: nuqneH\n"
        ) do |dir|
          FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
          initializers.each { |name, body| File.write(File.join(dir, "config", "initializers", name), body) }
          File.write(File.join(dir, "config", "application.rb"), application) if application
          block&.call(dir)
        end
      end

      it "reads a multi-line list of quoted symbols" do
        result = with_config({ "i18n.rb" => <<~RUBY })
          Rails.application.configure do
            config.i18n.available_locales = [
              :en,
              :es,
              :'zh-CN',
            ]
          end
        RUBY

        expect(result[:available_locales]).to eq(%w[en es zh-CN])
      end

      it "reads the bare I18n spelling" do
        result = with_config({ "i18n.rb" => "I18n.available_locales = %i[en es]\n" })
        expect(result[:available_locales]).to eq(%w[en es])
      end

      # config.i18n is buffered and applied from after_initialize, so it lands
      # on top of a bare I18n assignment an initializer already made.
      it "takes the buffered config.i18n list over a bare I18n one" do
        result = with_config(
          { "i18n.rb" => "I18n.available_locales = %i[en es tlh]\n" },
          application: "module Dummy\n  class Application < Rails::Application\n    config.i18n.available_locales = [:en]\n  end\nend\n"
        )

        expect(result[:available_locales]).to eq(%w[en])
      end

      # The listener strips whichever root matched, so a bare
      # `config.available_locales` inside a gem's own configure block reads the
      # same as Rails' unless the config spelling has to name i18n. Accepting
      # it replaced the app's whole list with the gem's one locale.
      it "ignores a config.available_locales that does not name i18n" do
        result = with_config({
          "zzz_some_gem.rb" => "SomeGem.configure do |config|\n  config.available_locales = [:zz]\nend\n",
          "i18n.rb"         => "Rails.application.configure do\n  config.i18n.available_locales = [:en, :es]\nend\n"
        })

        expect(result[:available_locales]).to eq(%w[en es])
      end

      # Rails hands app.config.i18n to I18n once, after every initializer has
      # run, so the last assignment executed is the one that lands.
      it "lets an initializer override application.rb" do
        result = with_config(
          { "i18n.rb" => "Rails.application.configure do\n  config.i18n.available_locales = [:en, :es]\nend\n" },
          application: "module Dummy\n  class Application < Rails::Application\n    config.i18n.available_locales = [:en]\n  end\nend\n"
        )

        expect(result[:available_locales]).to eq(%w[en es])
      end

      it "says the list came from config" do
        result = with_config({ "i18n.rb" => "I18n.available_locales = %i[en es]\n" })
        expect(result[:available_locales_source]).to eq("config")
      end

      it "measures coverage against the configured list" do
        result = with_config({ "i18n.rb" => "Rails.application.configure do\n  config.i18n.available_locales = [:en, :es]\nend\n" })
        expect(result[:locale_coverage].keys).to eq(%w[es])
      end

      it "falls back to the files when the value is computed" do
        result = with_config({ "i18n.rb" => "Rails.application.configure do\n  config.i18n.available_locales += [:zz]\nend\n" })

        expect(result[:available_locales]).to eq(%w[en es tlh])
        expect(result[:available_locales_source]).to eq("locale_files")
      end

      # A literal the app later overwrites with a computed value is not what
      # Rails ends up handing I18n, so it is not the answer either.
      it "falls back to the files when a later assignment supersedes the literal" do
        result = with_config(
          { "i18n.rb" => "Rails.application.configure do\n  config.i18n.available_locales = Locale.enabled.map(&:code)\nend\n" },
          application: "module Dummy\n  class Application < Rails::Application\n    config.i18n.available_locales = [:en, :fr]\n  end\nend\n"
        )

        expect(result[:available_locales]).to eq(%w[en es tlh])
        expect(result[:available_locales_source]).to eq("locale_files")
      end

      it "falls back to the files when nothing is configured" do
        result = with_config({})

        expect(result[:available_locales]).to eq(%w[en es tlh])
        expect(result[:available_locales_source]).to eq("locale_files")
      end

      # One unreadable initializer used to raise out of the walk and through
      # static_call's rescue, and the whole I18n answer became an error.
      it "reads the last initializer in name order, so the guard below has teeth" do
        result = with_config({
          "i18n.rb"       => "Rails.application.configure do\n  config.i18n.available_locales = [:en, :es]\nend\n",
          "zzz_broken.rb" => "Rails.application.configure do\n  config.i18n.available_locales = [:zz]\nend\n"
        })

        expect(result[:available_locales]).to eq(%w[zz])
      end

      # The same candidate files, read the same way: another environment's
      # file never runs, so its list is not the one the app enables.
      it "ignores an available_locales set by another environment" do
        original = ENV["RAILS_ENV"]
        ENV["RAILS_ENV"] = "production"
        result = with_config({}) do |dir|
          FileUtils.mkdir_p(File.join(dir, "config", "environments"))
          File.write(File.join(dir, "config", "environments", "production.rb"),
                     "config.i18n.available_locales = [:en, :es]\n")
          File.write(File.join(dir, "config", "environments", "development.rb"),
                     "config.i18n.available_locales = [:tlh]\n")
        end

        expect(result[:available_locales]).to eq(%w[en es])
      ensure
        ENV["RAILS_ENV"] = original
      end

      it "skips a file it cannot read" do
        broken = nil
        result = with_config({
          "i18n.rb"       => "Rails.application.configure do\n  config.i18n.available_locales = [:en, :es]\nend\n",
          "zzz_broken.rb" => "Rails.application.configure do\n  config.i18n.available_locales = [:zz]\nend\n"
        }) do |dir|
          broken = File.join(dir, "config", "initializers", "zzz_broken.rb")
          make_unreadable(broken)
        end

        expect(result[:error]).to be_nil
        expect(result[:available_locales]).to eq(%w[en es])
      end
    end
  end
end
