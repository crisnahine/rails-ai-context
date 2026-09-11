# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetI18n do
  before { described_class.reset_cache! }

  let(:i18n_data) do
    {
      default_locale: "en",
      available_locales: %w[en fr],
      backend: "I18n::Backend::Simple",
      locale_files: [
        { file: "en.yml", key_count: 100 },
        { file: "fr.yml", key_count: 80 },
        { file: "devise.en.yml", key_count: 50 },
        { file: "broken.fr.yml", parse_error: true }
      ],
      total_locale_files: 4,
      locale_coverage: { "fr" => { keys: 80, coverage_pct: 80.0, missing: 20, extra: 0 } },
      fallbacks: { fr: %w[en] }
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ i18n: i18n_data })
  end

  describe ".call" do
    it "renders the overview header facts" do
      text = described_class.call.content.first[:text]
      expect(text).to include("# I18n")
      expect(text).to include("**Default locale:** en")
      expect(text).to include("**Backend:** I18n::Backend::Simple")
      expect(text).to include("**Available locales:** en, fr (2)")
      expect(text).to include("**Locale files:** 4")
    end

    # Without a booted app the list is read from config/locales unless the app
    # assigns one, and those two answers are not the same question. Mastodon
    # ships files for 106 locales and enables 97.
    context "when the list was read from the locale files" do
      let(:i18n_data) { super().merge(available_locales_source: "locale_files") }

      it "says where the list came from" do
        text = described_class.call.content.first[:text]
        expect(text).to include("**Available locales (from locale files):** en, fr (2)")
      end
    end

    context "when the app configures the list" do
      let(:i18n_data) { super().merge(available_locales_source: "config") }

      it "names the field plainly" do
        text = described_class.call.content.first[:text]
        expect(text).to include("**Available locales:** en, fr (2)")
      end
    end

    it "renders coverage vs the default locale" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## Coverage (vs en)")
      expect(text).to include("**fr**: 80.0% - 80 unique keys")
    end

    # An app whose config/locales holds a language-name table lists far more
    # available locales than it has coverage rows for. Without a word about
    # the gap, a reader counts 187 locales, then 49 rows, and cannot tell
    # which number is wrong.
    context "when some locales carry no translations" do
      let(:i18n_data) do
        super().merge(
          available_locales: %w[en fr aa zu],
          locale_coverage: super()[:locale_coverage].merge(
            "aa" => { keys: 1, coverage_pct: 0.0, missing: 100, extra: 1 },
            "zu" => { keys: 1, coverage_pct: 0.0, missing: 100, extra: 1 }
          ),
          locales_without_translations: [ { locale: "aa", keys: 1 }, { locale: "zu", keys: 1 } ]
        )
      end

      it "says how many locales it left out of coverage" do
        text = described_class.call.content.first[:text]
        expect(text).to include("2 of 4 locales round to 0.0% against en")
      end

      # A language-name table gives every one of them the same key count, and
      # repeating it per name ran to 138 copies of "(2 keys)" on Discourse.
      it "states a shared key count once instead of per name" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Each defines 1 key of its own: aa, zu")
        expect(text).not_to include("aa (1 key)")
      end

      # Grouping them keeps 138 rows of zeroes off the overview.
      it "keeps their rows out of the coverage list" do
        text = described_class.call.content.first[:text]
        expect(text).not_to include("**aa**: 0.0%")
      end

      # The group is a summary, not a deletion: asking for one by name still
      # has to answer with its numbers.
      it "still answers with the numbers when asked for one by name" do
        text = described_class.call(locale: "aa").content.first[:text]
        expect(text).to include("**Unique keys:** 1 (0.0% of en)")
        expect(text).to include("100 missing")
      end
    end

    # Coverage counts a key path once; the per-file list below it counts each
    # file's leaves. Without the label the two numbers look like a bug.
    it "says the coverage key total counts unique paths" do
      text = described_class.call.content.first[:text]
      expect(text).to include("80 unique keys")
    end

    it "renders fallbacks" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## Fallbacks")
      expect(text).to include("**fr** → en")
    end

    it "lists locale files with key counts and parse errors" do
      text = described_class.call.content.first[:text]
      expect(text).to include("`en.yml` - 100 keys")
      expect(text).to include("`broken.fr.yml` - [parse error]")
    end

    context "with a locale filter" do
      it "shows only files matching that locale" do
        text = described_class.call(locale: "fr").content.first[:text]
        expect(text).to include("# I18n: fr")
        expect(text).to include("`fr.yml` - 80 keys")
        expect(text).to include("`broken.fr.yml`")
        expect(text).not_to include("`en.yml` - 100 keys")
        expect(text).not_to include("`devise.en.yml`")
      end

      it "shows coverage for the filtered locale" do
        text = described_class.call(locale: "fr").content.first[:text]
        expect(text).to include("**Unique keys:** 80 (80.0% of en)")
      end

      # The filename convention is not the only way a file serves a locale:
      # gem-provided files are named for the gem, and GitLab's zh-CN lives in
      # devise.zh-cn.yml. The tool listed both and then said it had none.
      it "finds a locale's files when the filename does not spell the locale" do
        allow(described_class).to receive(:cached_context).and_return(
          i18n: i18n_data.merge(
            available_locales: %w[en zh-CN],
            locale_files: [
              { file: "en.yml", key_count: 100, locales: %w[en] },
              { file: "devise.zh-cn.yml", key_count: 49, locales: %w[zh-CN] }
            ]
          )
        )

        text = described_class.call(locale: "zh-CN").content.first[:text]

        expect(text).to include("devise.zh-cn.yml")
        expect(text).not_to include("No locale files found")
      end

      it "returns not-found with suggestions for an unknown locale" do
        text = described_class.call(locale: "zz").content.first[:text]
        expect(text).to include("Locale 'zz' not found.")
        expect(text).to include("Available: en, fr")
      end
    end

    context "when introspection data is missing" do
      before { allow(described_class).to receive(:cached_context).and_return({}) }

      it "says how to enable it" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Add :i18n to introspectors")
      end
    end

    context "when introspection failed" do
      before { allow(described_class).to receive(:cached_context).and_return({ i18n: { error: "boom" } }) }

      it "reports the failure honestly" do
        text = described_class.call.content.first[:text]
        expect(text).to include("I18n introspection failed: boom")
      end
    end

    context "when the static tier declares the fallbacks unanswered" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          { i18n: i18n_data.merge(backend: nil, fallbacks: nil, unavailable_sections: %w[backend fallbacks]) }
        )
      end

      it "marks the fallbacks section unavailable instead of dropping it" do
        text = described_class.call.content.first[:text]
        expect(text).to include("## Fallbacks")
        expect(text).to include("[UNAVAILABLE:")
        expect(text).not_to include("**fr** →")
      end

      # The whole answer is here; two fields of it are not. Borrowing the
      # tier's own refusal sentence made one unanswered field read as the
      # tool declining, which is what an app that cannot boot really gets.
      it "says why the two runtime-only fields are unanswered, not that the tool refused" do
        text = described_class.call.content.first[:text]
        expect(text).to include("- **Backend:** [UNAVAILABLE:")
        expect(text).not_to include("requires a booted Rails app")
        expect(text).to include("belongs to the process that answers")
      end

      it "marks the per-locale fallback line unavailable" do
        text = described_class.call(locale: "fr").content.first[:text]
        expect(text).to include("**Fallbacks:** [UNAVAILABLE:")
      end
    end

    context "when running in the static tier without file data" do
      before do
        allow(described_class).to receive(:cached_context)
          .and_return({ i18n: { unavailable: "requires a booted Rails app" } })
      end

      it "renders the unavailable note" do
        text = described_class.call.content.first[:text]
        expect(text).to include("[UNAVAILABLE: requires a booted Rails app]")
      end
    end
  end
end
