# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::BaseTool do
  describe ".abstract?" do
    it "is abstract (excluded from registry)" do
      expect(described_class).to be_abstract
    end
  end

  describe ".registered_tools" do
    it "returns all 45 built-in tool classes" do
      tools = described_class.registered_tools
      expect(tools.size).to eq(45)
    end

    it "excludes BaseTool itself" do
      expect(described_class.registered_tools).not_to include(described_class)
    end

    it "returns only MCP::Tool subclasses" do
      described_class.registered_tools.each do |tool|
        expect(tool).to be < MCP::Tool
      end
    end

    it "includes core tools" do
      tools = described_class.registered_tools
      expect(tools).to include(RailsAiContext::Tools::GetSchema)
      expect(tools).to include(RailsAiContext::Tools::GetRoutes)
      expect(tools).to include(RailsAiContext::Tools::Query)
    end

    it "does not include abstract tools" do
      described_class.registered_tools.each do |tool|
        expect(tool).not_to be_abstract
      end
    end
  end

  describe ".descendants" do
    it "tracks all subclasses" do
      expect(described_class.descendants).to be_an(Array)
      expect(described_class.descendants.size).to eq(45)
    end
  end

  describe "Server.builtin_tools integration" do
    it "returns the same tools as registered_tools" do
      expect(RailsAiContext::Server.builtin_tools).to eq(described_class.registered_tools)
    end
  end

  describe "const_missing backwards compatibility" do
    it "Server::TOOLS still works" do
      expect(RailsAiContext::Server::TOOLS).to be_an(Array)
      expect(RailsAiContext::Server::TOOLS.size).to eq(45)
    end
  end

  describe ".empty_response and .empty?" do
    it "marks an answer that found nothing without changing what the reader sees" do
      response = described_class.empty_response("No views found for posts.")
      expect(described_class.empty?(response)).to be true
      expect(response.content.first[:text]).to eq("No views found for posts.")
    end

    it "treats a not-found response as empty" do
      response = described_class.not_found_response("Model", "Nope", %w[Post])
      expect(described_class.empty?(response)).to be true
    end

    # The old test was a substring search on the prose, so a real answer
    # whose body mentioned "not found" was dropped by every composing tool.
    it "does not treat a real answer that mentions not found as empty" do
      response = described_class.text_response("## PostsController\n- rescue_from ActiveRecord::RecordNotFound")
      expect(described_class.empty?(response)).to be false
    end

    context "on an mcp version whose Response carries no meta" do
      before { stub_const("#{described_class}::META_RESPONSES", false) }

      it "marks the answer with a zero-width prefix the reader never sees" do
        response = described_class.empty_response("No views found for posts.")
        expect(described_class.empty?(response)).to be true
        expect(described_class.response_text(response)).to eq("No views found for posts.")
      end
    end
  end
end
