# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Hydrators::ModelHints do
  let(:context) do
    {
      models: { "OAuthClientConfig" => { table_name: "oauth_client_configs", associations: [], validations: [] },
                "Post" => { table_name: "posts", associations: [], validations: [] } },
      schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" } ] },
                          "oauth_client_configs" => { columns: [] } } }
    }
  end

  it "resolves a name in another spelling" do
    result = described_class.resolve(%w[oauth_client_config], context: context)

    expect(result.hints.map(&:model_name)).to eq(%w[OAuthClientConfig])
  end

  it "dedupes two spellings of one model to one hint" do
    result = described_class.resolve(%w[Post post Posts], context: context)
    expect(result.hints.size).to eq(1)
  end

  it "reads a name that resolves to no model as no model" do
    result = described_class.resolve(%w[Post Widget], context: context)
    expect(result.hints.map(&:model_name)).to eq(%w[Post])
  end

  it "caps the hints at the configured maximum" do
    allow(RailsAiContext.configuration).to receive(:hydration_max_hints).and_return(1)
    result = described_class.resolve(%w[Post OAuthClientConfig], context: context)
    expect(result.hints.size).to eq(1)
  end
end
