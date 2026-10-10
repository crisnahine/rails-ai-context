# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::FactsFormatter do
  let(:text) { described_class.render(IntrospectedFixture.context, full_json: "Run `x` for the JSON.") }

  it "renders the key dependencies from the gems the introspector emits" do
    expect(text).to include("## Key Dependencies")
    expect(text).to include("- devise (auth)")
  end

  it "renders the tables and associations the fixture declares" do
    expect(text).to include("## Tables")
    expect(text).to include("## Associations")
  end

  # rake's ai:inspect prints a text summary, so a footer naming it as the
  # full JSON sent the reader to the wrong command.
  it "closes with the caller's line for the full JSON" do
    expect(text).to end_with("---\nRun `x` for the JSON.")
  end

  it "names a command each surface has for the full JSON" do
    rake = File.read(File.expand_path("../../../lib/rails_ai_context/tasks/rails_ai_context.rake", __dir__))
    binary = File.read(File.expand_path("../../../exe/rails-ai-context", __dir__))

    expect(rake).to include("Run `rails ai:context:json` for the full introspection as JSON, in .ai-context.json.")
    expect(binary).to include("Run `rails-ai-context inspect` for the full introspection as JSON.")
  end
end
