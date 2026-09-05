# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::MarkdownSerializer do
  let(:context) { RailsAiContext.introspect }

  describe "the header against a static-tier context" do
    around do |example|
      RailsAiContext.tier = :static
      example.run
    ensure
      RailsAiContext.tier = :runtime
    end

    it "names the Rails version the lockfile carries" do
      app = RailsAiContext::StaticApp.new(File.expand_path("../../../fixtures/static_app", __dir__))
      output = described_class.new(RailsAiContext::Introspector.new(app).call).call

      expect(output).to include("> Rails 7.2.2 | Ruby ")
    end
  end

  describe "the Controllers section" do
    it "names the strong params methods rather than dumping their permit detail" do
      context = {
        controllers: {
          controllers: {
            "PostsController" => {
              actions: %w[index],
              filters: [],
              strong_params: [ { name: "post_params", permits: %w[title body] } ],
              parent_class: "ApplicationController"
            }
          }
        }
      }

      output = described_class.new(context).call

      expect(output).to include("- Strong params: post_params")
    end
  end

  describe "the Views section" do
    # The introspector answers layouts as records; joining them printed a
    # Ruby hash into a file the app commits.
    it "names each layout file" do
      context = {
        views: {
          layouts: [ { name: "application.html.erb", yields: %w[content] }, { name: "mailer.html.erb" } ]
        }
      }

      output = described_class.new(context).call

      expect(output).to include("- Layouts: application.html.erb, mailer.html.erb")
      expect(output).not_to include("{name:")
    end
  end

  describe "the Internationalization section" do
    def i18n_output(source)
      described_class.new({ i18n: { default_locale: "en", available_locales: %w[en fr], available_locales_source: source } }).call
    end

    it "says a list read off the locale files is not the app's enabled list" do
      expect(i18n_output("locale_files")).to include("- Available locales (from locale files): en, fr")
    end

    it "states a configured list plainly" do
      expect(i18n_output("config")).to include("- Available locales: en, fr")
    end
  end

  describe "the Hotwire section against the static fixture" do
    it "names each model's broadcast macros" do
      output = described_class.new(IntrospectedFixture.context).call

      expect(output).to include("- `Comment`: broadcasts_to")
    end
  end

  describe "#call" do
    subject(:output) { described_class.new(context).call }

    it "returns a markdown string" do
      expect(output).to be_a(String)
      expect(output).to include("# ")
    end

    it "includes the app overview" do
      expect(output).to include("## Overview")
    end

    it "includes database schema section" do
      expect(output).to include("## Database Schema")
    end

    it "includes routes section" do
      expect(output).to include("## Routes")
    end

    context "with introspector warnings" do
      let(:context) do
        ctx = RailsAiContext.introspect
        ctx[:_warnings] = [
          { introspector: "database_stats", error: "Database connection failed" }
        ]
        ctx
      end

      it "renders a Warnings section" do
        expect(output).to include("## Warnings")
        expect(output).to include("**database_stats**")
        expect(output).to include("Database connection failed")
      end
    end

    context "without warnings" do
      let(:context) do
        ctx = RailsAiContext.introspect
        ctx.delete(:_warnings)
        ctx
      end

      it "does not render a Warnings section" do
        expect(output).not_to include("## Warnings")
      end
    end
  end

  # A section the static tier refused is not a section with a zero count.
  describe "a refused section" do
    it "renders no routes section when the static tier refused routes" do
      ctx = RailsAiContext.introspect
      ctx[:routes] = { unavailable: "requires a booted Rails app" }

      expect(described_class.new(ctx).call).not_to include("## Routes")
    end

    it "renders no conventions section when conventions failed" do
      ctx = RailsAiContext.introspect
      ctx[:conventions] = { error: "boom", directory_structure: { "app/models" => 3 } }

      expect(described_class.new(ctx).call).not_to include("## Project Structure")
    end

    it "renders no configuration section when the static tier refused config" do
      ctx = RailsAiContext.introspect
      ctx[:config] = { unavailable: "runtime only" }

      expect(described_class.new(ctx).call).not_to include("## Configuration")
    end

    it "renders no schema section when schema failed" do
      ctx = RailsAiContext.introspect
      ctx[:schema] = { error: "boom", total_tables: 3 }

      expect(described_class.new(ctx).call).not_to include("## Database Schema")
    end
  end
end

RSpec.describe RailsAiContext::Serializers::ClaudeSerializer do
  let(:context) { RailsAiContext.introspect }

  describe "#call" do
    subject(:output) { described_class.new(context).call }

    context "in compact mode (default)" do
      it "includes AI Context header" do
        expect(output).to include("AI Context")
      end

      it "includes MCP tools section" do
        expect(output).to include("MCP tools")
      end

      it "includes rules section" do
        expect(output).to include("## Rules")
      end

      context "with introspector warnings" do
        let(:context) do
          ctx = RailsAiContext.introspect
          ctx[:_warnings] = [
            { introspector: "schema", error: "No database" }
          ]
          ctx
        end

        it "renders warnings in compact mode" do
          expect(output).to include("## Warnings")
          expect(output).to include("**schema** skipped")
        end
      end
    end

    context "in full mode" do
      before { RailsAiContext.configuration.context_mode = :full }
      after { RailsAiContext.configuration.context_mode = :compact }

      it "includes Claude-specific header" do
        expect(output).to include("Claude Code")
      end

      it "includes behavioral rules section" do
        expect(output).to include("## Behavioral Rules")
      end
    end
  end
end

RSpec.describe RailsAiContext::Serializers::CopilotSerializer do
  let(:context) { RailsAiContext.introspect }

  describe "#call" do
    subject(:output) { described_class.new(context).call }

    context "in compact mode (default)" do
      it "uses Copilot-specific header" do
        expect(output).to include("Copilot Context")
      end
    end

    context "in full mode" do
      before { RailsAiContext.configuration.context_mode = :full }
      after { RailsAiContext.configuration.context_mode = :compact }

      it "uses Copilot Instructions header" do
        expect(output).to include("Copilot Instructions")
      end
    end
  end
end
