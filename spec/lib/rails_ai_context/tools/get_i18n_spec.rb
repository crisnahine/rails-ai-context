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
          locales_without_translations: %w[aa zu]
        )
      end

      it "says how many locales it left out of coverage" do
        text = described_class.call.content.first[:text]
        expect(text).to include("2 of 4 locales round to 0.0% against en")
      end

      # Asking for one of them by name must not answer with a silent gap where
      # the coverage line sits for every other locale.
      it "says why the detail view has no coverage line" do
        text = described_class.call(locale: "aa").content.first[:text]
        expect(text).to include("rounds to 0.0% against en")
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
