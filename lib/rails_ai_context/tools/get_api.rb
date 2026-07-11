# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetApi < BaseTool
      tool_name "rails_get_api"
      description "Returns the app's API layer: api_only mode, serialization strategy (Jbuilder templates, " \
        "serializer classes), GraphQL schema size, API versioning, rate limiting, CORS origins, pagination gems, " \
        "and OpenAPI specs. " \
        "Use when: building or changing JSON endpoints, choosing a serialization approach, or checking how the " \
        "app handles versioning, CORS, rate limiting, or pagination. " \
        "Key params: detail (summary for one-liner, standard for per-area breakdown, full adds OpenAPI spec " \
        "files, API client codegen, and GraphQL internals)."

      input_schema(
        properties: {
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Level of detail: summary (one-liner), standard (per-area breakdown), " \
              "full (+ OpenAPI spec files, API client codegen, GraphQL resolvers/subscriptions/dataloaders)"
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(detail: "standard", server_context: nil)
        data = cached_context[:api]

        note = unavailable_note(data)
        return text_response(note) if note

        unless data.is_a?(Hash) && !data[:error]
          return text_response(
            "No API layer data available. Ensure the :api introspector is enabled in your " \
            "rails_ai_context configuration.\n\n" \
            "Example:\n```ruby\nRailsAiContext.configure do |config|\n  config.introspectors << :api\nend\n```"
          )
        end

        case detail
        when "summary"
          text_response(build_summary(data))
        when "standard"
          text_response(build_standard(data))
        when "full"
          text_response(build_full(data))
        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end
      end

      class << self
        private

        def build_summary(data)
          parts = [ mode_label(data) ]
          parts << "Serialization: #{serialization_label(data[:serializers])}" if serializers?(data)
          parts << "GraphQL: #{graphql_label(data[:graphql])}" if data[:graphql].is_a?(Hash)
          parts << "Versions: #{data[:api_versioning].join(', ')}" if versioning?(data)
          rate = rate_limiting_label(data[:rate_limiting])
          parts << "Rate limiting: #{rate}" if rate
          parts << "CORS configured (#{data[:cors_config][:file]})" if data[:cors_config].is_a?(Hash)
          parts << "Pagination: #{data[:pagination].join(', ')}" if pagination?(data)

          summary = parts.join(". ")
          missing = missing_areas(data)
          summary += ". Not detected: #{missing.join(', ')}." if missing.any?
          summary
        end

        def build_standard(data)
          versions = data[:api_versioning]
          lines = [ "# API Layer", "" ]
          lines << "- **Mode:** #{mode_label(data)}"
          lines << "- **Serialization:** #{serialization_line(data)}"
          lines << "- **GraphQL:** #{data[:graphql].is_a?(Hash) ? graphql_label(data[:graphql]) : 'not detected (no app/graphql directory)'}"
          lines << "- **Versioning:** #{versioning?(data) ? "#{versions.join(', ')} (app/controllers/api/)" : 'not detected (no app/controllers/api/v* directories)'}"
          lines << "- **Rate limiting:** #{rate_limiting_label(data[:rate_limiting]) || 'not detected (no Rack::Attack initializer, no rate_limit macro)'}"
          lines << "- **CORS:** #{cors_line(data[:cors_config])}"
          lines << "- **Pagination:** #{pagination?(data) ? data[:pagination].join(', ') : 'no pagination gem detected (pagy/kaminari/will_paginate)'}"
          lines.join("\n")
        end

        def build_full(data)
          lines = build_standard(data).lines.map(&:chomp)
          append_openapi(lines, data[:openapi_spec])
          append_client_generation(lines, data[:api_client_generation])
          append_graphql_details(lines, data[:graphql_details])
          append_serializer_classes(lines, data.dig(:serializers, :serializer_classes))
          lines.join("\n")
        end

        def append_openapi(lines, specs)
          lines << "" << "## OpenAPI Specs" << ""
          if specs.is_a?(Array) && specs.any?
            specs.each { |path| lines << "- `#{path}`" }
          else
            lines << "No OpenAPI/Swagger spec files detected."
          end
        end

        def append_client_generation(lines, codegen)
          return unless codegen.is_a?(Array) && codegen.any?

          lines << "" << "## API Client Generation" << ""
          codegen.each { |tool| lines << "- #{tool}" }
        end

        def append_graphql_details(lines, details)
          return unless details.is_a?(Hash) && details.any?

          lines << "" << "## GraphQL Details" << ""
          %i[resolvers subscriptions dataloaders].each do |key|
            values = details[key]
            next unless values.is_a?(Array) && values.any?
            lines << "- **#{key.to_s.capitalize}:** #{values.join(', ')}"
          end
        end

        # Standard truncates the class list to the first few names; full lists
        # everything, so only the longer lists need this section.
        def append_serializer_classes(lines, classes)
          return unless classes.is_a?(Array) && classes.size > 8

          lines << "" << "## Serializer Classes" << ""
          classes.each { |name| lines << "- #{name}" }
        end

        def mode_label(data)
          data[:api_only] ? "API-only app (config.api_only = true)" : "Full-stack app (config.api_only = false)"
        end

        def serializers?(data)
          serializers = data[:serializers]
          return false unless serializers.is_a?(Hash)
          serializers[:jbuilder].to_i > 0 || (serializers[:serializer_classes].is_a?(Array) && serializers[:serializer_classes].any?)
        end

        def versioning?(data)
          data[:api_versioning].is_a?(Array) && data[:api_versioning].any?
        end

        def pagination?(data)
          data[:pagination].is_a?(Array) && data[:pagination].any?
        end

        def serialization_label(serializers)
          parts = []
          jbuilder = serializers[:jbuilder].to_i
          parts << "Jbuilder (#{jbuilder} #{jbuilder == 1 ? 'template' : 'templates'})" if jbuilder > 0

          classes = serializers[:serializer_classes]
          if classes.is_a?(Array) && classes.any?
            shown = classes.first(8).join(", ")
            shown += ", ..." if classes.size > 8
            parts << "#{classes.size} serializer #{classes.size == 1 ? 'class' : 'classes'} (#{shown})"
          end

          parts.join(" + ")
        end

        def serialization_line(data)
          return serialization_label(data[:serializers]) if serializers?(data)
          "none detected (no .jbuilder templates, no app/serializers classes)"
        end

        def graphql_label(graphql)
          "#{graphql[:types]} types, #{graphql[:mutations]} mutations, #{graphql[:queries]} queries (app/graphql)"
        end

        def rate_limiting_label(rate)
          return nil unless rate.is_a?(Hash)
          return "Rack::Attack (config/initializers/rack_attack.rb)" if rate[:rack_attack]
          return "Rails rate_limit macro (controller-level)" if rate[:rails_rate_limiting]
          nil
        end

        # The introspector returns nil both when config/initializers/cors.rb is
        # absent and when it exists with no active origins call (Rails --api
        # generates it fully commented out), so the empty state covers both.
        def cors_line(cors)
          return "not detected (no CORS initializer with active origins)" unless cors.is_a?(Hash)

          origins = Array(cors[:origins]).map(&:to_s)
          origins.any? ? "#{cors[:file]} (origins: #{origins.join(', ')})" : cors[:file].to_s
        end

        def missing_areas(data)
          missing = []
          missing << "serializers" unless serializers?(data)
          missing << "GraphQL" unless data[:graphql].is_a?(Hash)
          missing << "API versioning" unless versioning?(data)
          missing << "rate limiting" unless rate_limiting_label(data[:rate_limiting])
          missing << "CORS config" unless data[:cors_config].is_a?(Hash)
          missing << "pagination gems" unless pagination?(data)
          missing
        end
      end
    end
  end
end
