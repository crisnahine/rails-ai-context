# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::TestHelper do
  include described_class

  describe "#execute_tool" do
    it "executes a tool by full MCP name" do
      response = execute_tool("rails_get_schema", detail: "summary")
      expect(response).to be_a(MCP::Tool::Response)
    end

    it "executes a tool by short name" do
      response = execute_tool("schema", detail: "summary")
      expect(response).to be_a(MCP::Tool::Response)
    end

    it "executes a tool by class" do
      response = execute_tool(RailsAiContext::Tools::GetSchema, detail: "summary")
      expect(response).to be_a(MCP::Tool::Response)
    end

    it "raises ArgumentError for unknown tool name" do
      expect { execute_tool("nonexistent_tool") }.to raise_error(ArgumentError, /not found/)
    end
  end

  describe "#execute_tool_with_error" do
    it "returns the response even for error cases" do
      response = execute_tool_with_error("rails_query", sql: "DROP TABLE users")
      expect(response).to be_a(MCP::Tool::Response)
    end
  end

  describe "#assert_tool_findable" do
    it "passes for a registered tool" do
      assert_tool_findable("rails_get_schema")
    end

    it "passes for a tool class" do
      assert_tool_findable(RailsAiContext::Tools::GetSchema)
    end

    it "passes with short name resolution" do
      assert_tool_findable("schema")
    end

    it "fails for an unregistered tool" do
      expect { assert_tool_findable("nonexistent_tool") }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
    end
  end

  describe "#assert_tool_response_includes" do
    it "passes when text is present in response" do
      response = execute_tool("rails_get_conventions")
      assert_tool_response_includes(response, "Convention")
    end
  end

  describe "#assert_tool_response_excludes" do
    it "passes when text is absent from response" do
      response = execute_tool("rails_get_schema", detail: "summary")
      assert_tool_response_excludes(response, "XYZZY_NONEXISTENT_TABLE")
    end
  end

  describe "#extract_response_text" do
    it "extracts text content from a response" do
      response = execute_tool("rails_get_conventions")
      text = extract_response_text(response)
      expect(text).to be_a(String)
      expect(text).not_to be_empty
    end
  end
end
