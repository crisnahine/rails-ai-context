# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetRoutes < BaseTool
      tool_name "rails_get_routes"
      description "Get all routes for the Rails app, optionally filtered by controller. Shows HTTP verb, path, controller#action, and route name. Supports detail levels and pagination."

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Filter routes by controller name (e.g. 'users', 'api/v1/posts')."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: route counts per controller. standard: paths and actions (default). full: everything including names and constraints."
          },
          limit: {
            type: "integer",
            description: "Max routes to return. Default: depends on detail level."
          },
          offset: {
            type: "integer",
            description: "Skip routes for pagination. Default: 0."
          },
          app_only: {
            type: "boolean",
            description: "Filter out internal Rails routes (Active Storage, Action Mailbox, Conductor, etc.). Default: true."
          }
        }
      )

      def self.route_prefixes
        RailsAiContext.configuration.excluded_route_prefixes
      end

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, detail: "standard", limit: nil, offset: 0, app_only: true, server_context: nil)
        routes = cached_context[:routes]
        return text_response("Route introspection not available. Add :routes to introspectors.") unless routes
        return text_response("Route introspection failed: #{routes[:error]}") if routes[:error]

        by_controller = routes[:by_controller] || {}
        offset = [ offset.to_i, 0 ].max

        # Filter out internal Rails routes by default
        if app_only
          by_controller = by_controller.reject { |k, _| route_prefixes.any? { |p| k.downcase.start_with?(p) } }
        end

        # Filter by controller — accepts both slash and :: notation
        if controller
          normalized = controller.downcase.tr("::", "/").delete_suffix("controller")
          filtered = by_controller.select { |k, _| k.downcase.include?(normalized) }
          return text_response("No routes for '#{controller}'. Controllers: #{by_controller.keys.sort.join(', ')}") if filtered.empty?
          by_controller = filtered
        end

        # Combine PUT/PATCH duplicates (Rails generates both for update routes)
        by_controller = by_controller.transform_values { |actions| dedupe_put_patch(actions) }
        filtered_total = by_controller.values.sum(&:size)

        case detail
        when "summary"
          # Separate app routes from framework routes for cleaner output
          app_routes = controller ? by_controller : by_controller.reject { |k, _| route_prefixes.any? { |p| k.downcase.start_with?(p) } }
          framework_routes = controller ? {} : by_controller.select { |k, _| route_prefixes.any? { |p| k.downcase.start_with?(p) } }

          lines = [ "# Routes Summary (#{filtered_total} routes)", "" ]

          # Group sibling routes with identical verb patterns (e.g., bonus/*)
          grouped = app_routes.keys.sort.group_by do |ctrl|
            actions = app_routes[ctrl]
            namespace = ctrl.include?("/") ? ctrl.split("/").first : nil
            verbs_sig = actions.map { |r| r[:verb] }.sort.join(",")
            count_sig = actions.size
            namespace && app_routes.count { |k, v| k.start_with?("#{namespace}/") && v.size == count_sig && v.map { |r| r[:verb] }.sort.join(",") == verbs_sig } > 2 ? "#{namespace}/*|#{count_sig}|#{verbs_sig}" : ctrl
          end

          grouped.each do |_key, ctrls|
            if ctrls.size > 2
              namespace = ctrls.first.split("/").first
              actions = app_routes[ctrls.first]
              verbs = actions.map { |r| r[:verb] }.tally.map { |v, c| "#{c} #{v}" }.join(", ")
              short_names = ctrls.map { |c| c.split("/").last }
              lines << "- **#{namespace}/*** (#{short_names.join(', ')}) — #{actions.size} routes each (#{verbs})"
            else
              ctrls.each do |ctrl|
                actions = app_routes[ctrl]
                verbs = actions.map { |r| r[:verb] }.tally.map { |v, c| "#{c} #{v}" }.join(", ")
                lines << "- **#{ctrl}** — #{actions.size} routes (#{verbs})"
              end
            end
          end

          # Show framework routes as a compact summary
          if framework_routes.any?
            total_fw = framework_routes.values.sum(&:size)
            fw_names = framework_routes.keys.map { |k| k.split("/").first }.uniq.join(", ")
            lines << "- _#{fw_names} framework routes: #{total_fw} total_"
          end

          if routes[:api_namespaces]&.any?
            lines << "" << "API namespaces: #{routes[:api_namespaces].join(', ')}"
          end
          lines << "" << "_Use `controller:\"name\"` to see routes for a specific controller._"
          text_response(lines.join("\n"))

        when "standard"
          limit ||= 100
          # Separate app vs framework routes (unless user filtered by controller)
          app_routes = controller ? by_controller : by_controller.reject { |k, _| route_prefixes.any? { |p| k.downcase.start_with?(p) } }
          framework_routes = controller ? {} : by_controller.select { |k, _| route_prefixes.any? { |p| k.downcase.start_with?(p) } }

          lines = [ "# Routes (#{filtered_total} routes)", "" ]
          count = 0

          # Group identical sibling route sets (e.g. bonus/*)
          grouped = app_routes.sort.group_by do |ctrl, actions|
            ns = ctrl.include?("/") ? ctrl.split("/").first : nil
            if ns
              sibling_count = app_routes.count { |k, v| k.start_with?("#{ns}/") && v.size == actions.size && v.map { |r| "#{r[:verb]}:#{r[:action]}" }.sort == actions.map { |r| "#{r[:verb]}:#{r[:action]}" }.sort }
              sibling_count > 2 ? "#{ns}/*" : ctrl
            else
              ctrl
            end
          end

          grouped.each do |key, ctrl_groups|
            if key.end_with?("/*") && ctrl_groups.size > 2
              # Show one representative with all sibling names
              ns = key.sub("/*", "")
              names = ctrl_groups.map { |c, _| c.split("/").last }
              _repr_ctrl, repr_actions = ctrl_groups.first
              lines << "## #{ns}/* (#{names.join(', ')})"
              repr_actions.each do |r|
                count += 1
                next if count <= offset
                break if count > offset + limit
                # Generalize paths: replace specific resource name with *
                path = r[:path].sub(%r{/#{ns}/\w+}, "/#{ns}/*")
                name_part = r[:name] ? " `#{r[:name].sub(/\w+$/, '*')}`" : ""
                lines << "- `#{r[:verb]}` `#{path}` → #{r[:action]}#{name_part}"
              end
              lines << ""
            else
              ctrl_groups.each do |ctrl, actions|
                next if count >= offset + limit
                ctrl_lines = []
                actions.each do |r|
                  count += 1
                  next if count <= offset
                  break if count > offset + limit
                  name_part = r[:name] ? " `#{r[:name]}`" : ""
                  ctrl_lines << "- `#{r[:verb]}` `#{r[:path]}` → #{r[:action]}#{name_part}"
                end
                if ctrl_lines.any?
                  lines << "## #{ctrl}"
                  lines.concat(ctrl_lines)
                  lines << ""
                end
              end
            end
          end

          if framework_routes.any?
            total_fw = framework_routes.values.sum(&:size)
            fw_names = framework_routes.keys.map { |k| k.split("/").first }.uniq.join(", ")
            lines << "_#{fw_names} framework routes: #{total_fw} total (use `controller:\"devise/sessions\"` to see details)_"
          end

          lines << "_Use `detail:\"summary\"` for overview, or `detail:\"full\"` for route names._" if routes[:total_routes] > limit
          text_response(lines.join("\n"))

        when "full"
          # Existing full table behavior
          limit ||= 200
          lines = [ "# Routes Full Detail (#{filtered_total} routes)", "" ]
          lines << "| Verb | Path | Controller#Action | Name |"
          lines << "|------|------|-------------------|------|"
          count = 0
          by_controller.sort.each do |ctrl, actions|
            actions.each do |r|
              count += 1
              next if count <= offset
              break if count > offset + limit
              lines << "| #{r[:verb]} | `#{r[:path]}` | #{ctrl}##{r[:action]} | #{r[:name] || '-'} |"
            end
          end
          if routes[:api_namespaces]&.any?
            lines << "" << "## API namespaces: #{routes[:api_namespaces].join(', ')}"
          end
          text_response(lines.join("\n"))
        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end
      end
      private_class_method def self.dedupe_put_patch(actions)
        deduped = []
        actions.each do |r|
          existing = deduped.find { |d| d[:path] == r[:path] && d[:action] == r[:action] }
          if existing && %w[PUT PATCH].include?(r[:verb]) && %w[PUT PATCH].include?(existing[:verb])
            existing[:verb] = "PATCH|PUT"
          else
            deduped << r.dup
          end
        end
        deduped
      end
    end
  end
end
