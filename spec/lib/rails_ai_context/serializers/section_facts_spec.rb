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
end
