# frozen_string_literal: true

# Self-sufficient on purpose: with the gem in group :development,
# Bundler.require never loads it in the test environment, so this file is
# often the first (and only) entry point required from a test suite.
require_relative "../rails_ai_context"
# A custom tool subclasses MCP::Tool, and nothing else has loaded the SDK yet.
require "mcp"

module RailsAiContext
  # Reusable test helper for verifying MCP tools - both built-in and custom.
  # Works with RSpec and Minitest.
  #
  #   # RSpec
  #   RSpec.configure { |c| c.include RailsAiContext::TestHelper }
  #
  #   # Minitest
  #   class MyToolTest < ActiveSupport::TestCase
  #     include RailsAiContext::TestHelper
  #   end
  #
  module TestHelper
    # Execute a tool by name or class, returning the MCP::Tool::Response.
    # Raises if the tool is not found or returns an error.
    #
    #   response = execute_tool("rails_get_schema", table: "users")
    #   response = execute_tool(MyApp::CustomTool, query: "test")
    #
    def execute_tool(name_or_class, **args)
      tool_class = resolve_tool(name_or_class)
      raise ArgumentError, "Tool not found: #{name_or_class.inspect}. Available: #{available_tool_names.join(', ')}" unless tool_class

      response = tool_class.call(**args)
      unless response.is_a?(MCP::Tool::Response)
        raise "Expected MCP::Tool::Response, got #{response.class}"
      end
      raise "#{tool_class.tool_name} returned an error: #{extract_response_text(response)}" if response.error?

      response
    end

    # Execute a tool expecting an error response. Fails if the call succeeds.
    #
    #   response = execute_tool_with_error("rails_query", sql: "DROP TABLE users")
    #
    def execute_tool_with_error(name_or_class, **args)
      tool_class = resolve_tool(name_or_class)
      raise ArgumentError, "Tool not found: #{name_or_class.inspect}" unless tool_class

      response = tool_class.call(**args)
      _test_assert response.is_a?(MCP::Tool::Response) && response.error?,
        "Expected #{tool_class.tool_name} to return an error, but it succeeded"
      response
    end

    # Assert that a tool is registered and discoverable.
    #
    #   assert_tool_findable("rails_get_schema")
    #   assert_tool_findable(MyApp::CustomTool)
    #
    def assert_tool_findable(name_or_class)
      tool_class = resolve_tool(name_or_class)
      label = name_or_class.is_a?(Class) ? name_or_class.name : name_or_class
      _test_assert tool_class, "Expected tool '#{label}' to be registered, but it was not found"
    end

    # Assert the response text includes the expected string.
    #
    #   assert_tool_response_includes(response, "users")
    #
    def assert_tool_response_includes(response, expected)
      text = extract_response_text(response)
      _test_assert text.include?(expected),
        "Expected tool response to include #{expected.inspect}, but got:\n#{text[0..500]}"
    end

    # Assert the response text does NOT include the given string.
    #
    #   assert_tool_response_excludes(response, "password_digest")
    #
    def assert_tool_response_excludes(response, excluded)
      text = extract_response_text(response)
      _test_assert !text.include?(excluded),
        "Expected tool response NOT to include #{excluded.inspect}, but it was present"
    end

    # Extract the text content from an MCP::Tool::Response.
    #
    #   text = extract_response_text(response)
    #
    def extract_response_text(response)
      content = response.is_a?(MCP::Tool::Response) ? response.content : response.to_h[:content]
      return "" unless content.is_a?(Array)

      content.filter_map { |c| c[:text] || c["text"] }.join("\n")
    end

    private

    def resolve_tool(name_or_class)
      return name_or_class if name_or_class.is_a?(Class) && name_or_class < MCP::Tool

      name = name_or_class.to_s
      found = all_tools.find do |t|
        t.tool_name == name ||
          t.tool_name == "rails_#{name}" ||
          t.tool_name == "rails_get_#{name}" ||
          t.tool_name == "get_#{name}"
      end
      found || RailsAiContext::CLI::ToolRunner.candidate_names(name)
        .filter_map { |candidate| RailsAiContext::Tools::GetConfig.retired_section(candidate) }.first&.renderer
    end

    def all_tools
      tools = RailsAiContext::Tools::BaseTool.registered_tools
      tools + RailsAiContext::Server.resolve_custom_tools
    end

    def available_tool_names
      all_tools.map(&:tool_name)
    end

    # Framework-agnostic assert: works with both RSpec and Minitest
    def _test_assert(condition, message = nil)
      if respond_to?(:expect)
        # RSpec
        expect(condition).to be_truthy, message
      elsif respond_to?(:assert)
        # Minitest
        assert condition, message
      else
        raise message unless condition
      end
    end
  end
end
