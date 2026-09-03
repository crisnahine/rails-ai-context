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
  let(:describe_missing) { ->(name) { "Model '#{name}' not found" } }

  it "resolves a name in another spelling without warning about it" do
    result = described_class.resolve(%w[oauth_client_config], context: context, describe: describe_missing)

    expect(result.hints.map(&:model_name)).to eq(%w[OAuthClientConfig])
    expect(result.warnings).to eq([])
  end

  it "dedupes two spellings of one model to one hint" do
    result = described_class.resolve(%w[Post post Posts], context: context, describe: describe_missing)
    expect(result.hints.size).to eq(1)
  end

  it "warns once, in the caller's words, for a model that is not there" do
    result = described_class.resolve(%w[Post Widget], context: context, describe: describe_missing)
    expect(result.warnings).to eq([ "Model 'Widget' not found" ])
  end

  it "caps the hints at the configured maximum" do
    allow(RailsAiContext.configuration).to receive(:hydration_max_hints).and_return(1)
    result = described_class.resolve(%w[Post OAuthClientConfig], context: context, describe: describe_missing)
    expect(result.hints.size).to eq(1)
  end
end
