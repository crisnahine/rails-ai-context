# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::BaseTool do
  describe ".abstract?" do
    it "is abstract (excluded from registry)" do
      expect(described_class).to be_abstract
    end
  end

  describe ".registered_tools" do
    it "returns all 38 built-in tool classes" do
      tools = described_class.registered_tools
      expect(tools.size).to eq(38)
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
      expect(described_class.descendants.size).to eq(38)
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
      expect(RailsAiContext::Server::TOOLS.size).to eq(38)
    end
  end
end
