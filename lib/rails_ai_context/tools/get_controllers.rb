# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetControllers < BaseTool
      tool_name "rails_get_controllers"
      description "Get controller details: actions, before_action filters, strong params, and parent class. " \
        "Use when: adding/modifying controller actions, checking what filters apply, or reading action source code. " \
        "Filter with controller:\"PostsController\", drill into action:\"create\" for source code with line numbers."

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Optional: specific controller name (e.g. 'PostsController'). Omit for all controllers."
          },
          action: {
            type: "string",
            description: "Specific action name (e.g. 'index', 'create'). Requires controller. Returns the action source code and applicable filters."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level for controller listing. summary: names + action counts. standard: names + action list (default). full: everything. Ignored when specific controller is given."
          },
          limit: {
            type: "integer",
            description: "Max controllers to return when listing. Default: 50."
          },
          offset: {
            type: "integer",
            description: "Skip this many controllers for pagination. Default: 0."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, action: nil, detail: "standard", limit: nil, offset: 0, server_context: nil)
        data = cached_context[:controllers]
        return text_response("Controller introspection not available. Add :controllers to introspectors.") unless data
        return text_response("Controller introspection failed: #{data[:error]}") if data[:error]

        controllers = data[:controllers] || {}

        # Filter out framework-internal controllers for listings/error messages
        framework_controllers = RailsAiContext.configuration.excluded_controllers
        app_controller_names = controllers.keys.reject { |name| framework_controllers.include?(name) }.sort

        # Specific controller — always full detail (searches ALL controllers including framework)
        # Flexible matching: "cooks", "CooksController", "cookscontroller" all work
        if controller
          # Accept multiple formats: "CooksController", "cooks", "bonus/crises", "Bonus::CrisesController"
          # Use underscore for CamelCase→snake_case: "OmniauthCallbacks" → "omniauth_callbacks"
          # Also match on plain downcase to handle "userscontroller" → "users"
          input_snake = controller.gsub("/", "::").underscore.delete_suffix("_controller")
          input_down = controller.downcase.delete_suffix("controller").tr("/", "::")
          key = controllers.keys.find { |k|
            key_snake = k.underscore.delete_suffix("_controller")
            key_down = k.downcase.delete_suffix("controller")
            key_snake == input_snake || key_down == input_down
          } || controller
          info = controllers[key]
          unless info
            return not_found_response("Controller", controller, app_controller_names,
              recovery_tool: "Call rails_get_controllers(detail:\"summary\") to see all controllers")
          end
          return text_response("Error inspecting #{key}: #{info[:error]}") if info[:error]

          # Specific action — return source code
          if action
            return text_response(format_action_source(key, info, action))
          end

          return text_response(format_controller(key, info))
        end

        app_controllers = controllers.reject { |name, _| framework_controllers.include?(name) }

        # Pagination
        total = app_controllers.size
        offset = [ offset.to_i, 0 ].max
        limit = limit.nil? ? 50 : [ limit.to_i, 1 ].max
        all_names = app_controllers.keys.sort
        paginated_names = all_names.drop(offset).first(limit)

        if paginated_names.empty? && total > 0
          return text_response("No controllers at offset #{offset}. Total: #{total}. Use `offset:0` to start over.")
        end

        pagination_hint = offset + limit < total ? "\n_Showing #{paginated_names.size} of #{total}. Use `offset:#{offset + limit}` for more. cache_key: #{cache_key}_" : ""

        # Listing mode
        case detail
        when "summary"
          lines = [ "# Controllers (#{total})", "" ]
          paginated_names.each do |name|
            info = app_controllers[name]
            action_count = info[:actions]&.size || 0
            lines << "- **#{name}** — #{action_count} actions"
          end
          lines << "" << "_Use `controller:\"Name\"` for full detail._#{pagination_hint}"
          text_response(lines.join("\n"))

        when "standard"
          lines = [ "# Controllers (#{total})", "" ]
          paginated_names.each do |name|
            info = app_controllers[name]
            actions = info[:actions]&.join(", ") || "none"
            lines << "- **#{name}** — #{actions}"
          end
          lines << "" << "_Use `controller:\"Name\"` for filters and strong params, or `detail:\"full\"` for everything._#{pagination_hint}"
          text_response(lines.join("\n"))

        when "full"
          lines = [ "# Controllers (#{total})", "" ]

          # Group sibling controllers that share the same parent and identical structure
          paginated_ctrl = app_controllers.select { |k, _| paginated_names.include?(k) }
          grouped = paginated_ctrl.keys.sort.group_by do |name|
            info = app_controllers[name]
            parent = info[:parent_class]
            # Group by parent + actions + filters + params fingerprint
            if parent && parent != "ApplicationController"
              actions_sig = info[:actions]&.sort&.join(",")
              filters_sig = info[:filters]&.map { |f| "#{f[:kind]}:#{f[:name]}" }&.sort&.join(",")
              params_sig = info[:strong_params]&.sort&.join(",")
              "#{parent}|#{actions_sig}|#{filters_sig}|#{params_sig}"
            else
              name # unique key = no grouping
            end
          end

          grouped.each do |_key, names|
            if names.size > 2 && app_controllers[names.first][:parent_class] != "ApplicationController"
              # Compress group: show once with all names
              info = app_controllers[names.first]
              short_names = names.map { |n| n.sub(/Controller$/, "").split("::").last }
              parent = info[:parent_class] || "ApplicationController"
              lines << "## #{names.first.split('::').first}::* (#{short_names.join(', ')})"
              lines << "- Inherits: #{parent}"
              lines << "- Actions: #{info[:actions]&.join(', ')}" if info[:actions]&.any?
              if info[:filters]&.any?
                lines << "- Filters: #{info[:filters].map { |f| "#{f[:kind]} #{f[:name]}" }.join(', ')}"
              end
              lines << "- Strong params: #{info[:strong_params].join(', ')}" if info[:strong_params]&.any?
              lines << ""
            else
              names.each do |name|
                info = app_controllers[name]
                lines << "## #{name}"
                lines << "- Actions: #{info[:actions]&.join(', ')}" if info[:actions]&.any?
                if info[:filters]&.any?
                  lines << "- Filters: #{info[:filters].map { |f| "#{f[:kind]} #{f[:name]}" }.join(', ')}"
                end
                lines << "- Strong params: #{info[:strong_params].join(', ')}" if info[:strong_params]&.any?
                lines << ""
              end
            end
          end
          lines << pagination_hint unless pagination_hint.empty?
          text_response(lines.join("\n"))

        else
          list = paginated_names.map { |c| "- #{c}" }.join("\n")
          text_response("# Controllers (#{total})\n\n#{list}#{pagination_hint}")
        end
      end

      private_class_method def self.format_action_source(controller_name, info, action_name)
        actions = info[:actions] || []
        unless actions.map(&:to_s).include?(action_name.to_s)
          return "Action '#{action_name}' not found in #{controller_name}. Available: #{actions.join(', ')}"
        end

        # Find applicable filters
        filters = (info[:filters] || []).select do |f|
          if f[:only]&.any?
            f[:only].map(&:to_s).include?(action_name.to_s)
          elsif f[:except]&.any?
            !f[:except].map(&:to_s).include?(action_name.to_s)
          else
            true
          end
        end

        # Extract source code with line numbers
        source_path = Rails.root.join("app", "controllers", "#{controller_name.underscore}.rb")
        source_with_lines = extract_method_with_lines(source_path, action_name)

        lines = [ "# #{controller_name}##{action_name}", "" ]
        lines << "**File:** `app/controllers/#{controller_name.underscore}.rb`"

        if filters.any?
          lines << "" << "## Applicable Filters"
          filters.each do |f|
            line = "- `#{f[:kind]}` **#{f[:name]}**"
            line += " (only: #{f[:only].join(', ')})" if f[:only]&.any?
            lines << line
          end
        end

        if source_with_lines
          lines << "" << "## Source (lines #{source_with_lines[:start_line]}-#{source_with_lines[:end_line]})"
          lines << "```ruby" << source_with_lines[:code] << "```"
          lines << "" << "_Use this exact code as old_string for Edit — no need to Read the full file._"
        else
          lines << "" << "_Could not extract source code. File: #{source_path}_"
        end

        if info[:strong_params]&.any?
          lines << "" << "## Strong Params"
          info[:strong_params].each do |param_method|
            body = extract_method_with_lines(source_path, param_method)
            if body
              lines << "```ruby" << body[:code] << "```"
            else
              lines << "- `#{param_method}`"
            end
          end
        end

        lines.join("\n")
      end

      private_class_method def self.extract_method_with_lines(file_path, method_name)
        return nil unless File.exist?(file_path)
        return nil if File.size(file_path) > RailsAiContext.configuration.max_file_size
        source_lines = File.readlines(file_path)
        start_idx = source_lines.index { |l| l.match?(/^\s*def\s+#{Regexp.escape(method_name.to_s)}\b/) }
        return nil unless start_idx

        # Use indentation-based matching — much more reliable than regex depth counting.
        # The `end` for a `def` is always at the same indentation level.
        def_indent = source_lines[start_idx][/\A\s*/].length
        result = []
        end_idx = start_idx
        source_lines[start_idx..].each_with_index do |line, i|
          result << line.rstrip
          end_idx = start_idx + i
          # Stop at `end` with same indentation as `def` (skip the def line itself)
          break if i > 0 && line.match?(/\A\s{#{def_indent}}end\b/)
        end

        {
          code: result.join("\n"),
          start_line: start_idx + 1,
          end_line: end_idx + 1
        }
      rescue
        nil
      end

      private_class_method def self.format_controller(name, info)
        lines = [ "# #{name}", "" ]
        lines << "**Parent:** `#{info[:parent_class]}`" if info[:parent_class]
        lines << "**API controller:** yes" if info[:api_controller]

        if info[:actions]&.any?
          lines << "" << "## Actions"
          lines << info[:actions].map { |a| "- `#{a}`" }.join("\n")
        end

        if info[:filters]&.any?
          lines << "" << "## Filters"
          info[:filters].each do |f|
            detail = "- `#{f[:kind]}` **#{f[:name]}**"
            detail += " (only: #{f[:only].join(', ')})" if f[:only]&.any?
            lines << detail
          end
        end

        if info[:strong_params]&.any?
          lines << "" << "## Strong Params"
          lines << info[:strong_params].map { |p| "- `#{p}`" }.join("\n")
        end

        lines.join("\n")
      end
    end
  end
end
