# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Hydrators::ViewHydrator do
  let(:context) do
    {
      models: {
        "Post" => {
          table_name: "posts",
          associations: [ { name: "comments", type: "has_many" } ],
          validations: [ { kind: "presence", attributes: [ "title" ] } ]
        },
        "User" => {
          table_name: "users",
          associations: [],
          validations: [ { kind: "presence", attributes: [ "email" ] } ]
        },
        "OAuthClientConfig" => {
          table_name: "oauth_client_configs",
          associations: [],
          validations: []
        }
      },
      schema: {
        tables: {
          "posts" => {
            columns: [ { name: "id", type: "integer" }, { name: "title", type: "string" } ],
            primary_key: "id"
          },
          "users" => {
            columns: [ { name: "id", type: "integer" }, { name: "email", type: "string" } ],
            primary_key: "id"
          },
          "oauth_client_configs" => {
            columns: [ { name: "id", type: "integer" } ],
            primary_key: "id"
          }
        }
      }
    }
  end

  describe ".call" do
    it "resolves @post to Post model" do
      result = described_class.call(%w[post], context: context)
      expect(result.any?).to be true
      expect(result.hints.first.model_name).to eq("Post")
    end

    it "resolves plural @posts to Post model" do
      result = described_class.call(%w[posts], context: context)
      expect(result.any?).to be true
      expect(result.hints.first.model_name).to eq("Post")
    end

    it "resolves multiple ivars to different models" do
      result = described_class.call(%w[post user], context: context)
      expect(result.hints.size).to eq(2)
      expect(result.hints.map(&:model_name)).to contain_exactly("Post", "User")
    end

    it "skips framework ivars like page, query, flash" do
      result = described_class.call(%w[page query flash], context: context)
      expect(result.any?).to be false
    end

    it "returns empty for nil input" do
      result = described_class.call(nil, context: context)
      expect(result.any?).to be false
    end

    it "returns empty for empty array" do
      result = described_class.call([], context: context)
      expect(result.any?).to be false
    end

    it "includes warnings for unresolved models" do
      result = described_class.call(%w[post widget], context: context)
      expect(result.hints.map(&:model_name)).to include("Post")
      expect(result.warnings).to include(match(/Widget.*not found/))
    end

    it "deduplicates singular and plural forms" do
      result = described_class.call(%w[post posts], context: context)
      expect(result.hints.size).to eq(1)
      expect(result.hints.first.model_name).to eq("Post")
    end

    it "respects hydration_max_hints configuration" do
      allow(RailsAiContext.configuration).to receive(:hydration_max_hints).and_return(1)
      result = described_class.call(%w[post user], context: context)
      expect(result.hints.size).to eq(1)
    end

    it "hints once, without a warning, for a model the acronym inflects two ways" do
      result = described_class.call(%w[oauth_client_config oauth_client_configs], context: context)

      expect(result.hints.map(&:model_name)).to eq([ "OAuthClientConfig" ])
      expect(result.warnings).to eq([])
    end
  end
end
