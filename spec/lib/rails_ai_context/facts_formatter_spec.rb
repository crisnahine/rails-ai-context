# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::FactsFormatter do
  let(:text) { described_class.render(IntrospectedFixture.context) }

  it "renders the key dependencies from the gems the introspector emits" do
    expect(text).to include("## Key Dependencies")
    expect(text).to include("- devise (auth)")
  end

  it "renders tables, associations and architecture from the fixture" do
    expect(text).to include("## Tables")
    expect(text).to include("## Associations")
  end
end
