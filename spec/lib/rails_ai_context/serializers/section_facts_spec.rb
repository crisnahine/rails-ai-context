# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::SectionFacts do
  let(:context) { IntrospectedFixture.context }

  describe ".auth_line" do
    # The fixture app declares no devise model and no Pundit policy, so the
    # section resolves and still names nothing.
    it "answers nil when the fixture's auth section found no framework" do
      expect(described_class.auth_line(context)).to be_nil
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
    it "names the pipeline the fixture's assets section reports" do
      expect(described_class.assets_line(context)).to eq("- Assets: none")
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
