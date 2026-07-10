# frozen_string_literal: true

require "spec_helper"

RSpec.describe "introspection warnings over MCP" do
  let(:warned_context) do
    base = RailsAiContext::Tools::Onboard.cached_context
    base.merge(_warnings: [ { introspector: "schema", error: "db down" } ])
  end

  it "onboard appends a partial-context note when introspection produced warnings" do
    allow(RailsAiContext::Tools::Onboard).to receive(:cached_context).and_return(warned_context)
    response = RailsAiContext::Tools::Onboard.call(detail: "quick")
    expect(response.content.first[:text]).to include("Partial context")
    expect(response.content.first[:text]).to include("schema")
  end

  it "get_context appends the same note" do
    allow(RailsAiContext::Tools::GetContext).to receive(:cached_context).and_return(warned_context)
    response = RailsAiContext::Tools::GetContext.call(model: "Post")
    expect(response.content.first[:text]).to include("Partial context")
  end

  it "emits nothing when there are no warnings" do
    clean_context = RailsAiContext::Tools::Onboard.cached_context.dup
    clean_context.delete(:_warnings)
    allow(RailsAiContext::Tools::Onboard).to receive(:cached_context).and_return(clean_context)
    response = RailsAiContext::Tools::Onboard.call(detail: "quick")
    expect(response.content.first[:text]).not_to include("Partial context")
  end
end
