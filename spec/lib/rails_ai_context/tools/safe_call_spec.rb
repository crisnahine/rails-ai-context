# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::SafeCall do
  def build_tool(&call_body)
    Class.new(RailsAiContext::Tools::BaseTool) do
      tool_name "rails_safe_call_test_tool"
      description "test-only tool"
      input_schema(properties: {})
      define_singleton_method(:call, &call_body)
    end
  end

  it "converts an unexpected exception into an isError tool response" do
    tool = build_tool { |server_context: nil| raise "kaboom" }
    response = tool.call(server_context: nil)
    tool.abstract!

    expect(response).to be_a(MCP::Tool::Response)
    expect(response.error?).to be(true)
    text = response.content.first[:text]
    expect(text).to include("rails_safe_call_test_tool")
    expect(text).to include("RuntimeError")
    expect(text).to include("kaboom")
    expect(text).to include("Recovery:")
  end

  it "passes successful responses through untouched" do
    tool = build_tool { |server_context: nil| text_response("fine") }
    response = tool.call(server_context: nil)
    tool.abstract!

    expect(response.error?).to be(false)
    expect(response.content.first[:text]).to eq("fine")
  end

  it "clears leftover call params so a failed call cannot leak into the next session record" do
    tool = build_tool do |server_context: nil|
      set_call_params(table: "users")
      raise "kaboom"
    end
    tool.call(server_context: nil)
    tool.abstract!

    expect(Thread.current[:rails_ai_context_call_params]).to be_nil
  end
end
