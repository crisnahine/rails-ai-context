# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetEngines < BaseTool
      tool_name "rails_get_engines"
      description "Get Rails engines: engines mounted in config/routes.rb (with known-engine descriptions) and every loaded Rails::Engine subclass (routes and model counts). " \
        "Use when: checking which engines are mounted, finding an admin dashboard's path, or understanding engine-provided routes."

      input_schema(properties: {})

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context: nil)
        engines = cached_context[:engines]
        return text_response("Engine introspection not available. Add :engines to introspectors.") unless engines
        return text_response("Engine introspection failed: #{engines[:error]}") if engines[:error]
        note = unavailable_note(engines)
        return text_response(note) if note

        mounted = engines[:mounted_engines] || []
        loaded  = engines[:rails_engines] || []

        lines = [ "# Engines" ]

        lines << "" << "## Mounted (config/routes.rb)"
        if mounted.any?
          mounted.each do |e|
            line = "- **#{e[:engine]}** at `#{e[:path]}`"
            line += " (#{e[:category]})" if e[:category]
            line += " - #{e[:description]}" if e[:description]
            lines << line
          end
        else
          lines << "_No engines mounted in config/routes.rb._"
        end

        lines << "" << "## Loaded Engine Classes"
        if loaded.any?
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
