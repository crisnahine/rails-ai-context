# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetRoutes < BaseTool
      tool_name "rails_get_routes"
      description "Get all routes for the Rails app, optionally filtered by controller. Shows HTTP verb, path, controller#action, and route name."

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Optional: filter routes by controller name (e.g. 'users', 'api/v1/posts')."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, server_context: nil)
        routes = cached_context[:routes]
        return text_response("Route introspection failed: #{routes[:error]}") if routes[:error]

        by_controller = routes[:by_controller]

        if controller
          filtered = by_controller.select { |k, _| k.include?(controller) }
          return text_response("No routes found for '#{controller}'. Controllers: #{by_controller.keys.sort.join(', ')}") if filtered.empty?
          by_controller = filtered
        end

        lines = [ "# Routes (#{routes[:total_routes]} total)", "" ]
        lines << "| Verb | Path | Controller#Action | Name |"
        lines << "|------|------|-------------------|------|"

        by_controller.sort.each do |ctrl, actions|
          actions.each do |r|
            lines << "| #{r[:verb]} | `#{r[:path]}` | #{ctrl}##{r[:action]} | #{r[:name] || '-'} |"
          end
        end

        if routes[:api_namespaces]&.any?
          lines << "" << "## API namespaces: #{routes[:api_namespaces].join(', ')}"
        end

        text_response(lines.join("\n"))
      end
    end
  end
end
