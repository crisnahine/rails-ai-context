# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetRoutes < BaseTool
      tool_name "rails_get_routes"
      description "Get routing table: HTTP verbs, paths, controller#action, route names. " \
        "Use when: building links/redirects, checking available endpoints, verifying route helpers exist. " \
        "Filter with controller:\"users\", use detail:\"summary\" for counts or detail:\"full\" for route names."

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

        # Filter by controller — accepts "posts", "PostsController", "posts_controller", "Api::V1::Posts"
        if controller
          normalized = controller.underscore.delete_suffix("_controller")
          normalized_alt = controller.downcase.delete_suffix("_controller").delete_suffix("controller")
          filtered = by_controller.select { |k, _| k.downcase.include?(normalized) || k.downcase.include?(normalized_alt) }
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
          # Flatten all routes into a tagged array, then paginate
          app_routes = controller ? by_controller : by_controller.reject { |k, _| route_prefixes.any? { |p| k.downcase.start_with?(p) } }
          framework_routes = controller ? {} : by_controller.select { |k, _| route_prefixes.any? { |p| k.downcase.start_with?(p) } }

          flat_routes = app_routes.sort.flat_map { |ctrl, actions| actions.map { |r| r.merge(_ctrl: ctrl) } }
          page = paginate(flat_routes, offset: offset, limit: limit, default_limit: 150)

          lines = [ "# Routes (#{filtered_total} routes)", "" ]
          current_ctrl = nil

          page[:items].each do |r|
            ctrl = r[:_ctrl]
            if ctrl != current_ctrl
              current_ctrl = ctrl
              ctrl_class = "#{ctrl.camelize}Controller"
              ctrl_data = cached_context.dig(:controllers, :controllers, ctrl_class)
              ctrl_summary = ""
              if ctrl_data
                filters = (ctrl_data[:filters] || []).map { |f| f[:name] }.first(3)
                formats = ctrl_data[:respond_to_formats]
                parts = []
                parts << "filters: #{filters.join(', ')}" if filters.any?
                parts << "formats: #{formats.join(', ')}" if formats&.any?
                ctrl_summary = " (#{parts.join(' | ')})" if parts.any?
              end
              lines << "## #{ctrl}#{ctrl_summary}"
            end

            params = r[:path].scan(/:(\w+)/).flatten
            params_part = params.any? ? " [#{params.join(', ')}]" : ""
            helper_part = if r[:name]
              args = params.any? ? "(#{params.map { |p| p == 'id' ? '@record' : ":#{p}" }.join(', ')})" : ""
              " `#{r[:name]}_path#{args}`"
            else
              ""
            end
            lines << "- `#{r[:verb]}` `#{r[:path]}` → #{r[:action]}#{helper_part}#{params_part}"
          end

          if framework_routes.any?
            total_fw = framework_routes.values.sum(&:size)
            fw_names = framework_routes.keys.map { |k| k.split("/").first }.uniq.join(", ")
            lines << "" << "_#{fw_names} framework routes: #{total_fw} total (use `controller:\"devise/sessions\"` to see details)_"
          end

          lines << "" << page[:hint] unless page[:hint].empty?
          text_response(lines.join("\n"))

        when "full"
          flat_routes = by_controller.sort.flat_map { |ctrl, actions| actions.map { |r| r.merge(_ctrl: ctrl) } }
          page = paginate(flat_routes, offset: offset, limit: limit, default_limit: 200)

          lines = [ "# Routes Full Detail (#{filtered_total} routes)", "" ]
          lines << "| Verb | Path | Controller#Action | Name |"
          lines << "|------|------|-------------------|------|"
          page[:items].each do |r|
            lines << "| #{r[:verb]} | `#{r[:path]}` | #{r[:_ctrl]}##{r[:action]} | #{r[:name] || '-'} |"
          end
          if routes[:api_namespaces]&.any?
            lines << "" << "## API namespaces: #{routes[:api_namespaces].join(', ')}"
          end
          lines << "" << page[:hint] unless page[:hint].empty?
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
