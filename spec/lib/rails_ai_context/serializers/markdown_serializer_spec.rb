# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::MarkdownSerializer do
  let(:context) { RailsAiContext.introspect }

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
