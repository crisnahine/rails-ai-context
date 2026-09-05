# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::SectionFacts do
  let(:context) { IntrospectedFixture.context }

  describe ".auth_line" do
    # The fixture declares Devise on two models and no authorization gem, so
    # the section resolves and names one framework.
    it "names the framework the fixture's auth section found" do
      expect(described_class.auth_line(context)).to eq("- Auth: Devise")
    end

    it "names every framework the section carries" do
      ctx = {
        auth: {
          authentication: { devise: [ { model: "User" } ], rails_auth: { session_model: "Session" } },
          authorization: { pundit: [ "PostPolicy" ], cancancan: true }
        }
      }

      expect(described_class.auth_line(ctx)).to eq("- Auth: Devise + Rails 8 auth + Pundit + CanCanCan")
    end

    it "answers nil for a refused auth section" do
      expect(described_class.auth_line({ auth: { unavailable: "requires a booted Rails app" } })).to be_nil
    end
  end

  describe ".assets_line" do
    it "answers nil for the fixture, whose assets section reports no pipeline" do
      expect(described_class.assets_line(context)).to be_nil
    end

    it "drops the no-pipeline word from a line that still has a bundler" do
      ctx = { assets: { pipeline: "none", js_bundler: "esbuild" } }

      expect(described_class.assets_line(ctx)).to eq("- Assets: esbuild")
    end

    it "joins the pipeline, bundler and framework in that order" do
      ctx = { assets: { pipeline: "Propshaft", js_bundler: "esbuild", css_framework: "Tailwind" } }

      expect(described_class.assets_line(ctx)).to eq("- Assets: Propshaft, esbuild, Tailwind")
    end

    it "answers nil when the section carries none of the three" do
      expect(described_class.assets_line({ assets: {} })).to be_nil
    end
  end

  describe ".strong_param_names" do
    it "names the methods the introspector recorded as hashes" do
      data = { strong_params: [ { name: "filter_params", permits: %w[origin status] },
                                { name: "form_account_batch_params", requires: "form_account_batch" } ] }

      expect(described_class.strong_param_names(data)).to eq(%w[filter_params form_account_batch_params])
    end

    it "keeps a plain string entry, which is already a method name" do
      expect(described_class.strong_param_names({ strong_params: %w[post_params] })).to eq(%w[post_params])
    end

    it "answers an empty list for a controller with no strong params" do
      expect(described_class.strong_param_names({})).to eq([])
    end
  end

  describe ".filters_line" do
    it "names each filter by kind" do
      data = { filters: [ { kind: "before", name: "authenticate" }, { kind: "after", name: "track" } ] }

      expect(described_class.filters_line(data)).to eq("- Filters: before authenticate, after track")
    end

    # The per-action answer and docs/CONFIGURATION.md both spell a skip
    # `~~name~~ _(skipped)_`, and one fact reads one way everywhere.
    it "strikes a skipped filter through the way the per-action answer does" do
      data = { filters: [ { kind: "before", name: "authenticate", skipped: true } ] }

      expect(described_class.filters_line(data)).to eq("- Filters: ~~authenticate~~ _(skipped)_")
    end

    it "answers nil for a controller with no filters" do
      expect(described_class.filters_line({})).to be_nil
    end
  end

  describe ".controller_summary_lines" do
    let(:controller_data) do
      {
        filters: [ { kind: "before", name: "authenticate" } ],
        strong_params: [ { name: "post_params" } ],
        rescue_from: [ { exception: "ActiveRecord::RecordNotFound", handler: "not_found" } ]
      }
    end

    it "states the filters and the strong params, in that order" do
      expect(described_class.controller_summary_lines(controller_data))
        .to eq([ "- Filters: before authenticate", "- Strong params: post_params" ])
    end

    it "adds the rescue handlers for a surface that renders them" do
      expect(described_class.controller_summary_lines(controller_data, rescue_handlers: true).last)
        .to eq("- Rescue from: ActiveRecord::RecordNotFound -> not_found")
    end

    it "answers an empty list for a controller with none of them" do
      expect(described_class.controller_summary_lines({}, rescue_handlers: true)).to eq([])
    end
  end

  describe ".rescue_handler_lines" do
    it "pairs each exception with its handler" do
      data = { rescue_from: [ { exception: "ActiveRecord::RecordInvalid", handler: "not_found" } ] }

      expect(described_class.rescue_handler_lines(data)).to eq([ "ActiveRecord::RecordInvalid -> not_found" ])
    end

    it "names the exception alone for a block form, which records no handler" do
      data = { rescue_from: [ { exception: "Mastodon::NotPermittedError" } ] }

      expect(described_class.rescue_handler_lines(data)).to eq([ "Mastodon::NotPermittedError" ])
    end

    it "answers an empty list for a controller with no rescue_from" do
      expect(described_class.rescue_handler_lines({})).to eq([])
    end
  end

  describe ".available_locales_label" do
    it "qualifies a list read off the locale files" do
      expect(described_class.available_locales_label(available_locales_source: "locale_files"))
        .to eq("Available locales (from locale files)")
    end

    it "leaves a configured list unqualified" do
      expect(described_class.available_locales_label(available_locales_source: "config"))
        .to eq("Available locales")
    end

    it "leaves a payload that records no source unqualified" do
      expect(described_class.available_locales_label({})).to eq("Available locales")
    end
  end

  describe ".i18n_line" do
    it "qualifies a list read off the locale files" do
      ctx = { i18n: { available_locales: %w[en fr], available_locales_source: "locale_files" } }
      expect(described_class.i18n_line(ctx)).to eq("- I18n: 2 locales from locale files (en, fr)")
    end

    it "leaves a configured list unqualified" do
      ctx = { i18n: { available_locales: %w[en fr], available_locales_source: "config" } }
      expect(described_class.i18n_line(ctx)).to eq("- I18n: 2 locales (en, fr)")
    end

    it "says nothing when the app has one locale" do
      expect(described_class.i18n_line(i18n: { available_locales: %w[en] })).to be_nil
    end
  end
end
