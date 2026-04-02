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
                lines << "- Rescue from: #{info[:rescue_from].join(', ')}" if info[:rescue_from]&.any?
                lines << "- Rate limit: #{info[:rate_limit]}" if info[:rate_limit]
                lines << "- Turbo Stream actions: #{info[:turbo_stream_actions].join(', ')}" if info[:turbo_stream_actions]&.any?
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
        # Case-insensitive action lookup for consistency with other tools
        action_name = actions.find { |a| a.to_s.downcase == action_name.to_s.downcase }&.to_s || action_name.to_s
        unless actions.map(&:to_s).include?(action_name)
          return "Action '#{action_name}' not found in #{controller_name}. Available: #{actions.join(', ')}"
        end

        # Find applicable filters from this controller
        filters = (info[:filters] || []).select do |f|
          if f[:only]&.any?
            f[:only].map(&:to_s).include?(action_name.to_s)
          elsif f[:except]&.any?
            !f[:except].map(&:to_s).include?(action_name.to_s)
          else
            true
          end
        end

        # Detect skip_before_action declarations in the child controller source
        source_path = Rails.root.join("app", "controllers", "#{controller_name.underscore}.rb")
        skipped_filters = detect_skipped_filters(source_path, action_name)

        # Include inherited filters from parent controller, excluding skipped ones
        parent_filters = detect_parent_filters(info[:parent_class]).reject do |f|
          skipped_filters.include?(f[:name])
        end

        # Extract source code with line numbers
        source_with_lines = extract_method_with_lines(source_path, action_name)

        lines = [ "# #{controller_name}##{action_name}", "" ]
        lines << "**File:** `app/controllers/#{controller_name.underscore}.rb`"

        if parent_filters.any? || filters.any? || skipped_filters.any?
          lines << "" << "## Applicable Filters"
          parent_filters.each do |f|
            lines << "- `#{f[:kind]}` **#{f[:name]}** _(from #{info[:parent_class]})_"
          end
          filters.each do |f|
            line = "- `#{f[:kind]}` **#{f[:name]}**"
            line += " (only: #{f[:only].join(', ')})" if f[:only]&.any?
            lines << line
          end
          skipped_filters.each do |name|
            lines << "- ~~#{name}~~ _(skipped)_"
          end
        end

        if source_with_lines
          lines << "" << "## Source (lines #{source_with_lines[:start_line]}-#{source_with_lines[:end_line]})"
          lines << "```ruby" << source_with_lines[:code] << "```"

          # Instance variables set by this action
          # Detect instance variables — handles both @var = x and @a, @b = x
          ivars = []
          source_with_lines[:code].each_line do |line|
            next unless line.include?("=")
            left_side = line.split("=", 2).first
            left_side.scan(/@(\w+)/).each { |m| ivars << m[0] }
          end
          ivars.uniq!
          lines << "" << "## Instance Variables" << ivars.map { |v| "- `@#{v}`" }.join("\n") if ivars.any?

          # Private methods called by this action — include their source inline
          called_methods = detect_called_private_methods(source_with_lines[:code], source_path)
          if called_methods.any?
            lines << "" << "## Private Methods Called"
            called_methods.each do |pm|
              lines << "### #{pm[:name]} (lines #{pm[:start_line]}-#{pm[:end_line]})"
              lines << "```ruby" << pm[:code] << "```"
            end
          end

          # Render map: redirects, renders, and side effects
          render_map = extract_render_map(source_with_lines[:code])
          if render_map[:redirects].any? || render_map[:renders].any?
            lines << "" << "## Render Map"
            render_map[:redirects].each { |r| lines << "- **Redirect:** #{r}" }
            render_map[:renders].each { |r| lines << "- **Render:** #{r}" }
          end
          if render_map[:side_effects].any?
            lines << "" << "## Side Effects"
            render_map[:side_effects].each { |s| lines << "- #{s}" }
          end
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

      # Detect private methods called within an action's source
      private_class_method def self.detect_called_private_methods(action_code, source_path)
        return [] unless File.exist?(source_path)
        return [] if File.size(source_path) > RailsAiContext.configuration.max_file_size

        # Find all method-like calls in the action (word followed by optional parens)
        candidates = action_code.scan(/\b([a-z_]\w*[!?]?)(?:\s*[\(,]|\s*$)/).flatten.uniq

        # Read the full file to find private methods
        full_source = File.readlines(source_path)
        in_private = false
        private_methods = Set.new

        full_source.each do |line|
          in_private = true if line.match?(/\A\s*private\s*$/)
          if in_private && (m = line.match(/\A\s*def\s+(\w+[!?]?)/))
            private_methods << m[1]
          end
        end

        # Extract source of private methods that are called
        called = candidates & private_methods.to_a
        called.filter_map do |method_name|
          body = extract_method_with_lines(source_path, method_name)
          next unless body
          { name: method_name, code: body[:code], start_line: body[:start_line], end_line: body[:end_line] }
        end.first(5) # Limit to 5 to avoid overwhelming response
      rescue => e
        $stderr.puts "[rails-ai-context] detect_called_private_methods failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Detect before_action filters from parent controller source file
      private_class_method def self.detect_parent_filters(parent_class)
        return [] unless parent_class

        # Try introspector data first
        controllers = cached_context.dig(:controllers, :controllers) || {}
        parent_data = controllers[parent_class]
        if parent_data
          return (parent_data[:filters] || []).select { |f| f[:kind] == "before" && !f[:only]&.any? && !f[:except]&.any? }
        end

        # Fallback: read ApplicationController source directly
        path = Rails.root.join("app", "controllers", "#{parent_class.underscore}.rb")
        return [] unless File.exist?(path)
        return [] if File.size(path) > RailsAiContext.configuration.max_file_size

        source = File.read(path, encoding: "UTF-8") rescue nil
        return [] unless source

        filters = []
        source.each_line do |line|
          if (m = line.match(/\A\s*before_action\s+:(\w+)/))
            next if line.include?("only:") || line.include?("except:")
            filters << { kind: "before", name: m[1] }
          end
        end
        filters
      rescue => e
        $stderr.puts "[rails-ai-context] detect_parent_filters failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Detect skip_before_action declarations in a controller source file
      private_class_method def self.detect_skipped_filters(source_path, action_name)
        return [] unless File.exist?(source_path)
        return [] if File.size(source_path) > RailsAiContext.configuration.max_file_size

        source = File.read(source_path, encoding: "UTF-8") rescue nil
        return [] unless source

        skipped = []
        source.each_line do |line|
          if (m = line.match(/\A\s*skip_before_action\s+:(\w+)/))
            # Check if the skip applies to this action
            if line.include?("only:")
              only_match = line.match(/only:\s*\[?\s*([^\]]+)\]?/)
              if only_match
                only_actions = only_match[1].scan(/:(\w+)/).flatten
                next unless only_actions.map(&:to_s).include?(action_name.to_s)
              end
            end
            skipped << m[1]
          end
        end
        skipped
      rescue => e
        $stderr.puts "[rails-ai-context] detect_skipped_filters failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Extract render map from action source: redirects, renders, and side effects
      private_class_method def self.extract_render_map(code)
        redirects = []
        renders = []
        side_effects = []

        code.each_line do |line|
          stripped = line.strip

          # Detect redirect_to calls
          if (m = stripped.match(/redirect_to\s+(.+)/))
            target = m[1].sub(/\s*,\s*(status|notice|alert|flash):.*/, "")
            desc = "redirect_to #{target.strip}"
            flash_parts = []
            flash_parts << "notice: #{Regexp.last_match(1)}" if stripped.match(/notice:\s*("[^"]*"|'[^']*'|[^,)]+)/)
            flash_parts << "alert: #{Regexp.last_match(1)}" if stripped.match(/alert:\s*("[^"]*"|'[^']*'|[^,)]+)/)
            desc += " (#{flash_parts.join(', ')})" if flash_parts.any?
            redirects << desc
          end

          # Detect render calls
          if (m = stripped.match(/render\s+(.+)/))
            render_args = m[1]
            desc = "render #{render_args.sub(/\s*\}?\s*$/, "").strip}"
            renders << desc
          end

          # Detect side effects
          if stripped.match?(/\.save[!]?(\s|\(|$)/)
            obj = stripped.match(/(\S+)\.save/)&.send(:[], 1) || "object"
            side_effects << "#{obj}.save"
          end
          if stripped.match?(/\.update[!]?[\s(]/)
            obj = stripped.match(/(\S+)\.update/)&.send(:[], 1) || "object"
            side_effects << "#{obj}.update"
          end
          if stripped.match?(/\.destroy[!]?(\s|\(|$)/)
            obj = stripped.match(/(\S+)\.destroy/)&.send(:[], 1) || "object"
            side_effects << "#{obj}.destroy"
          end
          if (m = stripped.match(/(\S+)\.perform_later/))
            side_effects << "#{m[1]}.perform_later"
          end
          if (m = stripped.match(/(\S+)\.(increment_\w+[!]?)/))
            side_effects << "#{m[1]}.#{m[2]}"
          end
          if (m = stripped.match(/(\S+)\.deliver(_later|_now)?/))
            side_effects << "#{m[1]}.deliver#{m[2]}"
          end
        end

        { redirects: redirects.uniq, renders: renders.uniq, side_effects: side_effects.uniq }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_render_map failed: #{e.message}" if ENV["DEBUG"]
        { redirects: [], renders: [], side_effects: [] }
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
      rescue => e
        $stderr.puts "[rails-ai-context] extract_method_with_lines failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      private_class_method def self.format_controller(name, info)
        lines = [ "# #{name}", "" ]
        lines << "**Parent:** `#{info[:parent_class]}`" if info[:parent_class]
        lines << "**API controller:** yes" if info[:api_controller]
        lines << "**Formats:** #{info[:respond_to_formats].join(', ')}" if info[:respond_to_formats]&.any?

        if info[:actions]&.any?
          lines << "" << "## Actions"
          lines << info[:actions].map { |a| "- `#{a}`" }.join("\n")
        end

        # Show full filter chain including inherited from parent controller
        all_filters = info[:filters] || []
        parent_filters = detect_parent_filters(info[:parent_class])
        if parent_filters.any? || all_filters.any?
          lines << "" << "## Filters"
          parent_filters.each do |f|
            lines << "- `#{f[:kind]}` **#{f[:name]}** _(from #{info[:parent_class]})_"
          end
          all_filters.each do |f|
            detail = "- `#{f[:kind]}` **#{f[:name]}**"
            detail += " (only: #{f[:only].join(', ')})" if f[:only]&.any?
            lines << detail
          end
        end

        if info[:strong_params]&.any?
          lines << "" << "## Strong Params"
          lines << info[:strong_params].map { |p| "- `#{p}`" }.join("\n")
        end

        # Rescue handlers
        if info[:rescue_from]&.any?
          lines << "" << "## Rescue Handlers"
          info[:rescue_from].each { |r| lines << "- `rescue_from` #{r}" }
        end

        # Rate limiting
        lines << "" << "**Rate limit:** #{info[:rate_limit]}" if info[:rate_limit]

        # Turbo Stream actions
        if info[:turbo_stream_actions]&.any?
          lines << "" << "## Turbo Stream Actions"
          info[:turbo_stream_actions].each { |a| lines << "- `#{a}`" }
        end

        # Cross-reference hints
        ctrl_path = name.underscore.delete_suffix("_controller")
        model_name = ctrl_path.split("/").last.singularize.camelize
        lines << ""
        lines << "_Next: `rails_get_routes(controller:\"#{ctrl_path}\")` for routes"
        lines << " | `rails_get_model_details(model:\"#{model_name}\")` for model"
        lines << " | `rails_get_view(controller:\"#{ctrl_path.split('/').last}\")` for views_"

        lines.join("\n")
      end
    end
  end
end
