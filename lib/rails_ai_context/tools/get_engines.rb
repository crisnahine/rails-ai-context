# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetEngines < BaseTool
      tool_name "rails_get_engines"
      description "Get what config/routes.rb mounts - engines and plain Rack apps alike, with known-engine descriptions - and every loaded Rails::Engine subclass (routes and model counts). " \
        "Use when: checking what is mounted where, finding an admin dashboard's path, or understanding engine-provided routes."

      input_schema(properties: {})

      guide_row(
        order: 42,
        mcp: "rails_get_engines",
        summary: "Mounted apps (engines and Rack apps) + loaded engine classes with route/model counts"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context: nil)
        fetch_section(:engines, subject: "Engine introspection") do |engines|
          mounted = engines[:mounted_engines] || []
          loaded  = engines[:rails_engines] || []

          lines = [ "# Engines" ]

          # Engines and plain Rack apps both: `mount App => path` and
          # `match path, to: App` build the same endpoint, and neither the
          # heading nor the empty line calls one of them the other.
          lines << "" << "## Mounted apps (config/routes.rb)"
          if mounted.any?
            mounted.each do |e|
              line = "- **#{e[:engine]}** at `#{e[:path]}`"
              line += " (#{e[:category]})" if e[:category]
              line += " - #{e[:description]}" if e[:description]
              lines << line
            end
          else
            lines << "_Nothing mounted in config/routes.rb._"
          end

          lines << "" << "## Loaded Engine Classes"
          if loaded.is_a?(Hash) && loaded[:unavailable]
            lines << RailsAiContext::Confidence.unavailable(loaded[:unavailable])
          elsif loaded.any?
            loaded.each do |e|
              parts = []
              parts << count_phrase(e[:route_count], "route") if e[:route_count]
              parts << count_phrase(e[:model_count], "model") if e[:model_count]
              line = "- **#{e[:name]}**"
              line += " - #{parts.join(', ')}" if parts.any?
              lines << line
            end
          else
            lines << "_No loaded Rails::Engine subclasses detected._"
          end

          text_response(lines.join("\n"))
        end
      end
    end
  end
end
