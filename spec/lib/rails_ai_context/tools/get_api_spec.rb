# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetApi do
  before { described_class.reset_cache! }

  let(:api_data) do
    {
      api_only: true,
      serializers: {
        jbuilder: 3,
        serializer_classes: %w[OrderSerializer UserSerializer]
      },
      graphql: { types: 12, mutations: 4, queries: 2 },
      api_versioning: %w[v1 v2],
      rate_limiting: { rack_attack: true },
      openapi_spec: [ "openapi/schema.yaml" ],
      cors_config: { file: "config/initializers/cors.rb", origins: [ "example.com", "*" ] },
      api_client_generation: [ "openapi-typescript" ],
      graphql_details: {
        resolvers: %w[OrdersResolver],
        subscriptions: %w[OrderUpdated],
        dataloaders: %w[RecordLoader]
      },
      pagination: %w[pagy]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ api: api_data })
  end

  describe ".call" do
    context "with detail:summary" do
      it "returns a one-liner covering every detected area" do
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]

        expect(text).to include("API-only app (config.api_only = true)")
        expect(text).to include("Jbuilder (3 templates)")
        expect(text).to include("2 serializer classes")
        expect(text).to include("GraphQL: 12 types, 4 mutations, 2 queries")
        expect(text).to include("Versions: v1, v2")
        expect(text).to include("Rack::Attack")
        expect(text).to include("CORS configured (config/initializers/cors.rb)")
        expect(text).to include("Pagination: pagy")
        expect(text).not_to include("Not detected")
      end

      it "lists undetected areas honestly when nothing is configured" do
        allow(described_class).to receive(:cached_context).and_return({
          api: { api_only: true, serializers: {}, graphql: nil, api_versioning: [],
                 rate_limiting: {}, openapi_spec: [], cors_config: nil,
                 api_client_generation: [], graphql_details: nil, pagination: nil }
        })
        result = described_class.call(detail: "summary")
        text = result.content.first[:text]

        expect(text).to include("API-only app (config.api_only = true)")
        expect(text).to include("Not detected: serializers, GraphQL, API versioning, rate limiting, CORS config, pagination gems.")
      end
    end

    context "with detail:standard" do
      it "includes the api_only mode" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Mode:** API-only app (config.api_only = true)")
      end

      it "includes serialization strategy" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Serialization:** Jbuilder (3 templates) + 2 serializer classes (OrderSerializer, UserSerializer)")
      end

      it "includes GraphQL counts" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**GraphQL:** 12 types, 4 mutations, 2 queries (app/graphql)")
      end

      it "includes API versioning" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Versioning:** v1, v2 (app/controllers/api/)")
      end

      it "includes rate limiting" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Rate limiting:** Rack::Attack (config/initializers/rack_attack.rb)")
      end

      it "includes CORS file and origins" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**CORS:** config/initializers/cors.rb (origins: example.com, *)")
      end

      it "includes pagination gems" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Pagination:** pagy")
      end

      it "shows the Rails rate_limit macro variant" do
        api_data[:rate_limiting] = { rails_rate_limiting: true }
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Rate limiting:** Rails rate_limit macro (controller-level)")
      end

      it "does not include full-only sections" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).not_to include("OpenAPI Specs")
        expect(text).not_to include("API Client Generation")
        expect(text).not_to include("GraphQL Details")
      end
    end

    context "with detail:full" do
      it "includes everything from standard" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("**Mode:** API-only app (config.api_only = true)")
        expect(text).to include("**Serialization:** Jbuilder (3 templates)")
        expect(text).to include("**Pagination:** pagy")
      end

      it "includes OpenAPI spec files" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("OpenAPI Specs")
        expect(text).to include("`openapi/schema.yaml`")
      end

      it "includes API client generation tools" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("API Client Generation")
        expect(text).to include("openapi-typescript")
      end

      it "includes GraphQL details" do
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("GraphQL Details")
        expect(text).to include("**Resolvers:** OrdersResolver")
        expect(text).to include("**Subscriptions:** OrderUpdated")
        expect(text).to include("**Dataloaders:** RecordLoader")
      end

      it "states when no OpenAPI specs exist instead of omitting the section" do
        api_data[:openapi_spec] = []
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("No OpenAPI/Swagger spec files detected.")
      end

      it "lists all serializer classes when more than eight exist" do
        api_data[:serializers] = { serializer_classes: (1..10).map { |i| "Serializer#{i}" } }
        result = described_class.call(detail: "full")
        text = result.content.first[:text]

        expect(text).to include("Serializer Classes")
        expect(text).to include("- Serializer9")
        expect(text).to include("- Serializer10")
      end
    end

    context "on a full-stack HTML app with minimal API surface" do
      let(:html_app_data) do
        {
          api_only: false,
          serializers: { jbuilder: 3 },
          graphql: nil,
          api_versioning: [],
          rate_limiting: {},
          openapi_spec: [],
          cors_config: nil,
          api_client_generation: [],
          graphql_details: nil,
          pagination: nil
        }
      end

      before do
        allow(described_class).to receive(:cached_context).and_return({ api: html_app_data })
      end

      it "reports full-stack mode and honest not-detected lines" do
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Mode:** Full-stack app (config.api_only = false)")
        expect(text).to include("**Serialization:** Jbuilder (3 templates)")
        expect(text).to include("**GraphQL:** not detected (no app/graphql directory)")
        expect(text).to include("**Versioning:** not detected (no app/controllers/api/v* directories)")
        expect(text).to include("**Rate limiting:** not detected (no Rack::Attack initializer, no rate_limit macro)")
        expect(text).to include("**CORS:** not detected (no CORS initializer with active origins)")
        expect(text).to include("**Pagination:** no pagination gem detected (pagy/kaminari/will_paginate)")
      end

      it "says none detected for serialization when nothing exists" do
        html_app_data[:serializers] = {}
        result = described_class.call(detail: "standard")
        text = result.content.first[:text]

        expect(text).to include("**Serialization:** none detected (no .jbuilder templates, no app/serializers classes)")
      end
    end

    context "when api data is missing" do
      it "returns a helpful message about enabling the introspector" do
        allow(described_class).to receive(:cached_context).and_return({})
        result = described_class.call
        text = result.content.first[:text]

        expect(text).to include("No API layer data available")
        expect(text).to include(":api")
        expect(text).to include("config.introspectors")
      end
    end

    context "when api data has an error" do
      it "returns a helpful message about enabling the introspector" do
        allow(described_class).to receive(:cached_context).and_return({ api: { error: "boom" } })
        result = described_class.call
        text = result.content.first[:text]

        expect(text).to include("No API layer data available")
        expect(text).to include(":api")
      end
    end

    context "with unknown detail level" do
      it "returns an error message" do
        result = described_class.call(detail: "verbose")
        text = result.content.first[:text]

        expect(text).to include("Unknown detail level: verbose")
        expect(text).to include("summary, standard, or full")
      end
    end
  end
end
