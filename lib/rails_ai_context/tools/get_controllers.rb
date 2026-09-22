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
          detail: RailsAiContext::DetailLevel.schema("Detail level for controller listing. summary: names + action counts. standard: names + action list (default). full: everything. Ignored when specific controller is given."),
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

      guide_row(
        order: 4,
        mcp: "rails_get_controllers(controller:\"X\", action:\"Y\")",
        cli_args: "controller=X action=Y",
        summary: "Action source + inherited filters + render map + private methods"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, action: nil, detail: "standard", limit: nil, offset: 0, server_context: nil)
        fetch_section(:controllers, subject: "Controller introspection") do |data|
          controllers = data[:controllers] || {}

          # Every read of the shared cache deep-copies the whole payload, so
          # the listing reads it once and hands the copy down.
          ctx = cached_context
          app_controller_names = Payload.app_controllers(ctx).keys.sort

          # Specific controller - always full detail (searches ALL controllers including framework)
          if controller
            # Payload owns the name-to-key rule, so this tool and the
            # rails-ai-context://controllers resource answer a name the same
            # way. The raw string stays the fallback for a key this hash lacks.
            key = Payload.find_controller(ctx, controller) || controller
            info = controllers[key]
            unless info
              return not_found_response("Controller", controller, app_controller_names,
                recovery_tool: "Call rails_get_controllers(detail:\"summary\") to see all controllers")
            end
            return text_response("Error inspecting #{key}: #{info[:error]}") if info[:error]

            # Specific action - return source code
            if action
              return format_action_source(key, info, action)
            end

            return text_response(format_controller(key, info, ctx))
          end

          app_controllers = Payload.app_controllers(ctx)

          # Pagination
          all_names = app_controllers.keys.sort
          page = paginate(all_names, offset: offset, limit: limit, default_limit: 50)
          paginated_names = page[:items]

          if paginated_names.empty? && page[:total] > 0
            return text_response(page[:hint])
          end

          pagination_hint = page[:hint].empty? ? "" : "\n#{page[:hint]}"

          # Listing mode
          case detail
          when "summary"
            lines = [ "# Controllers (#{page[:total]})", "" ]
            paginated_names.each do |name|
              info = app_controllers[name]
              action_count = info[:actions]&.size || 0
              phrase = Serializers::SectionFacts.unread_marker(info) || count_phrase(action_count, "action")
              lines << "- **#{name}** - #{phrase}"
            end
            lines << "" << "_Use `controller:\"Name\"` for full detail._#{pagination_hint}"
            text_response(lines.join("\n"))

          when "standard"
            lines = [ "# Controllers (#{page[:total]})", "" ]
            paginated_names.each do |name|
              info = app_controllers[name]
              lines << "- **#{name}** - #{Serializers::SectionFacts.actions_phrase(info)}"
            end
            lines << "" << "_Use `controller:\"Name\"` for filters and strong params, or `detail:\"full\"` for everything._#{pagination_hint}"
            text_response(lines.join("\n"))

          when "full"
            lines = [ "# Controllers (#{page[:total]})", "" ]

            # Group sibling controllers that share the same parent and identical structure
            paginated_ctrl = app_controllers.select { |k, _| paginated_names.include?(k) }
            grouped = paginated_ctrl.keys.sort.group_by do |name|
              info = app_controllers[name]
              parent = resolved_parent(name, info, ctx)
              # Group by parent + actions + filters + params fingerprint
              if parent && parent != "ApplicationController"
                actions_sig = info[:actions]&.sort&.join(",")
                # The group renders one member's filter line for all of them,
                # so a skip and its constraints have to tell the fingerprints
                # apart: the constraint is what decides the rendered tail.
                filters_sig = info[:filters]&.map { |f|
                  "#{f[:kind]}:#{f[:name]}#{skip_sig(f)}"
                }&.sort&.join(",")
                params_sig = Serializers::SectionFacts.strong_param_names(info).sort.join(",")
                "#{parent}|#{actions_sig}|#{filters_sig}|#{params_sig}"
              else
                name # unique key = no grouping
              end
            end

            grouped.each do |_key, names|
              if names.size > 2 &&
                  resolved_parent(names.first, app_controllers[names.first], ctx) != "ApplicationController"
                # Compress group: show once with all names
                info = app_controllers[names.first]
                parent = resolved_parent(names.first, info, ctx) || "ApplicationController"
                lines << "## #{group_heading(names)}"
                lines << "- Members: #{names.join(', ')}"
                lines << "- Inherits: #{parent}"
                lines.concat(actions_lines(info))
                lines.concat(Serializers::SectionFacts.controller_summary_lines(
                  info, ctx: ctx, name: names.first, root: rails_app&.root&.to_s
                ))
                lines << ""
              else
                names.each do |name|
                  info = app_controllers[name]
                  lines << "## #{name}"
                  lines.concat(actions_lines(info))
                  lines.concat(Serializers::SectionFacts.controller_summary_lines(
                    info, rescue_handlers: true,
                    ctx: ctx, name: name, root: rails_app&.root&.to_s
                  ))
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
            text_response("# Controllers (#{page[:total]})\n\n#{list}#{pagination_hint}")
          end
        end
      end

      # The static walk stores the superclass as the source spells it, so two
      # namespaces that each define a BaseController arrive spelled the same.
      # The rendered chain resolves it, so the key has to resolve it too, and
      # against the full set the chain walk uses: an excluded base class is
      # still an ancestor.
      private_class_method def self.resolved_parent(name, info, ctx)
        Introspectors::ActionResolver.resolve_entry_name(
          Payload.controllers(ctx), info[:parent_class], name
        )
      end

      # A class that defines no action of its own is an answer, and dropping
      # the line left it reading as a walk that did not look. An unread entry
      # already gets a line of its own, so it is not said twice.
      private_class_method def self.actions_lines(info)
        return [] if Serializers::SectionFacts.unread_marker(info)

        [ "- Actions: #{Serializers::SectionFacts.actions_phrase(info)}" ]
      end

      # Only a skip's constraints reach the group's filter line: `only:` and
      # `except:` on an active filter are never rendered there.
      private_class_method def self.skip_sig(filter)
        return "" unless filter[:skipped]

        ":skipped:#{filter[:if]}:#{filter[:unless]}:#{filter[:only]}:#{filter[:except]}"
      end

      # A compressed group is headed by the namespace every member is really
      # in, and never by one taken from a single member's own class name. With
      # no namespace to name - a group of top-level controllers has none - the
      # heading names a member, because a count alone identifies nothing and
      # two such groups in one document would carry the same heading.
      private_class_method def self.group_heading(names)
        shared = shared_namespace(names)
        count = count_phrase(names.size, "controller")
        return "#{shared.join('::')}::* (#{count})" unless shared.empty?

        "#{names.first} and #{count_phrase(names.size - 1, "like it", plural: "like it")} (#{count})"
      end

      private_class_method def self.shared_namespace(names)
        names.map { |name| name.split("::")[0..-2] }.reduce do |common, segments|
          common.zip(segments).take_while { |a, b| a == b }.map(&:first)
        end
      end

      private_class_method def self.format_action_source(controller_name, info, action_name)
        actions = info[:actions] || []
        # Case-insensitive action lookup for consistency with other tools
        action_name = actions.find { |a| a.to_s.downcase == action_name.to_s.downcase }&.to_s || action_name.to_s
        unless actions.map(&:to_s).include?(action_name)
          return empty_response("Action '#{action_name}' not found in #{controller_name}. Available: #{actions.join(', ')}")
        end

        carried = RailsAiContext::Payload.controller_file(cached_context, controller_name)
        source_path = carried ? rails_app.root.join(carried) : nil
        source = source_path && safe_read(source_path.to_s)

        applicable = RailsAiContext::ActionFilters.for(cached_context, controller_name, action_name, source: source,
          root: rails_app.root.to_s)

        # Extract source code with line numbers
        source_with_lines = source && extract_method_with_lines(source_path, action_name, source: source)

        lines = [ "# #{controller_name}##{action_name}", "" ]
        lines << "**File:** `#{carried}`" if carried

        if applicable.values.any?(&:any?)
          lines << "" << "## Applicable Filters"
          applicable[:inherited].each { |f| lines << filter_line(f) }
          applicable[:own].each { |f| lines << filter_line(f) }
          applicable[:skipped].each { |name| lines << "- ~~#{name}~~ _(skipped)_" }
        end

        if source_with_lines
          lines << "" << "## Source (lines #{source_with_lines[:start_line]}-#{source_with_lines[:end_line]})"
          lines << "```ruby" << source_with_lines[:code] << "```"

          ivars = RailsAiContext::Introspectors::ActionResolver.assigned_ivars(source_with_lines[:code])
          lines << "" << "## Instance Variables" << ivars.map { |v| "- `@#{v}`" }.join("\n") if ivars.any?

          # Private methods called by this action - include their source inline
          called_methods = detect_called_private_methods(source_with_lines[:code], source_path, source: source)
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
          lines << "" << "_Could not extract source code. File: #{source_path || "not recorded for #{controller_name}"}_"
        end

        # One action's answer used to carry every strong-params method in the
        # controller, so `create_params`' permit list read as the fields
        # `deactivate` accepts.
        action_params = params_methods_for_action(info[:strong_params], source_with_lines, applicable,
          source_path, source)

        if action_params.any?
          lines << "" << "## Strong Params"
          action_params.each do |sp|
            if sp.is_a?(Hash)
              lines << "### #{sp[:name]}"
              if sp[:unrestricted]
                lines << "- **WARNING:** `params.permit!` - all parameters allowed"
              else
                lines << "- requires: `:#{sp[:requires]}`" if sp[:requires]
                lines << "- permits: #{sp[:permits].map { |p| "`:#{p}`" }.join(', ')}" if sp[:permits]&.any?
                sp[:nested]&.each do |key, fields|
                  lines << "- nested `#{key}:` #{fields.map { |f| "`:#{f}`" }.join(', ')}"
                end
                sp[:arrays]&.each { |a| lines << "- array: `#{a}: []`" }
              end
              body = extract_method_with_lines(source_path, sp[:name], source: source)
              lines << "```ruby" << body[:code] << "```" if body
            else
              body = extract_method_with_lines(source_path, sp, source: source)
              if body
                lines << "```ruby" << body[:code] << "```"
              else
                lines << "- `#{sp}`"
              end
            end
          end
        end

        # Hydrate with schema hints for models referenced in this action
        if RailsAiContext.configuration.hydration_enabled
          hydration = Hydrators::ControllerHydrator.call(source_path.to_s, context: cached_context)
          hydration_text = Hydrators::HydrationFormatter.format(hydration)
          lines << "" << hydration_text unless hydration_text.empty?
        end

        text_response(lines.join("\n"))
      end

      # Detect private methods called within an action's source
      private_class_method def self.detect_called_private_methods(action_code, source_path, source: nil)
        return [] unless File.exist?(source_path)
        return [] if File.size(source_path) > RailsAiContext.configuration.max_file_size

        # Find all method-like calls in the action (word followed by optional parens)
        candidates = action_code.scan(/\b([a-z_]\w*[!?]?)(?:\s*[\(,]|\s*$)/).flatten.uniq

        full_source = source || RailsAiContext::SafeFile.read(source_path) || ""
        private_methods = Introspectors::ActionResolver.private_methods_from_source(full_source).map { |m| m.split("(").first }

        called = candidates & private_methods
        called.filter_map do |method_name|
          body = extract_method_with_lines(source_path, method_name, source: source)
          next unless body
          { name: method_name, code: body[:code], start_line: body[:start_line], end_line: body[:end_line] }
        end.first(5) # Limit to 5 to avoid overwhelming response
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_called_private_methods")
      end

      # The params methods this action can reach: the ones its own body names,
      # plus the ones the filters that run before it name. With no source to
      # read, every method stays - a shorter list would be a guess.
      private_class_method def self.params_methods_for_action(strong_params, action_source, applicable, source_path, source)
        entries = Array(strong_params)
        return entries if entries.empty? || action_source.nil?

        reachable = action_source[:code].to_s.dup
        filter_names = (applicable[:own] + applicable[:inherited]).filter_map { |f| f[:name].to_s }
        filter_names.each do |name|
          body = extract_method_with_lines(source_path, name, source: source)
          reachable << "\n" << body[:code] if body
        end

        entries.select do |sp|
          name = sp.is_a?(Hash) ? sp[:name].to_s : sp.to_s
          name.empty? || reachable.match?(/(?<![\w:])#{Regexp.escape(name)}(?![\w])/)
        end
      end

      private_class_method def self.filter_line(filter)
        line = "- `#{filter[:kind]}` **#{filter[:name]}**"
        line += " _(from #{filter[:from]})_" if filter[:from]
        line += " _(#{filter[:provenance]})_" if !filter[:from] && filter[:provenance]
        line += " (only: #{filter[:only].join(', ')})" if filter[:only]&.any?
        line += " (except: #{filter[:except].join(', ')})" if filter[:except]&.any?
        line + Serializers::SectionFacts.skip_condition_tail(filter)
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
        RailsAiContext.debug_fail(e, { redirects: [], renders: [], side_effects: [] }, label: "extract_render_map")
      end

      private_class_method def self.extract_method_with_lines(file_path, method_name, source: nil)
        unless source
          return nil unless file_path && File.exist?(file_path)
          return nil if File.size(file_path) > RailsAiContext.configuration.max_file_size
        end
        RailsAiContext::Introspectors::ActionResolver.method_body(
          source || RailsAiContext::SafeFile.read(file_path) || "", method_name
        )
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_method_with_lines")
      end

      private_class_method def self.format_controller(name, info, ctx)
        lines = [ "# #{name}", "" ]
        lines << "**Parent:** `#{resolved_parent(name, info, ctx)}`" if info[:parent_class]
        lines << "**API controller:** yes" if info[:api_controller]
        lines << "**Formats:** #{info[:respond_to_formats].join(', ')}" if info[:respond_to_formats]&.any?

        lines << "" << "## Actions"
        lines << if info[:actions]&.any?
          info[:actions].map { |a| "- `#{a}`" }.join("\n")
        else
          Serializers::SectionFacts.actions_phrase(info)
        end

        chain = RailsAiContext::ActionFilters.for_controller(ctx, name, root: rails_app.root.to_s)
        if chain.values.any?(&:any?)
          lines << "" << "## Filters"
          chain[:inherited].each { |f| lines << filter_line(f) }
          chain[:own].each { |f| lines << filter_line(f) }
          chain[:skipped].each { |skipped| lines << "- ~~#{skipped}~~ _(skipped)_" }
        end

        if info[:strong_params]&.any?
          lines << "" << "## Strong Params"
          info[:strong_params].each do |sp|
            if sp.is_a?(Hash)
              permits_summary = sp[:permits]&.map { |p| ":#{p}" }&.join(", ") || ""
              lines << "- `#{sp[:name]}`#{sp[:requires] ? " (requires: :#{sp[:requires]})" : ""}#{permits_summary.empty? ? "" : " permits: #{permits_summary}"}"
            else
              lines << "- `#{sp}`"
            end
          end
        end

        # Rescue handlers
        if info[:rescue_from]&.any?
          lines << "" << "## Rescue Handlers"
          Serializers::SectionFacts.rescue_handler_lines(info).each { |r| lines << "- `rescue_from` #{r}" }
        end

        # Rate limiting
        lines << "" << "**Rate limit:** #{info[:rate_limit]}" if info[:rate_limit]

        # Turbo Stream actions
        if info[:turbo_stream_actions]&.any?
          lines << "" << "## Turbo Stream Actions"
          info[:turbo_stream_actions].each { |a| lines << "- `#{a}`" }
        end

        # Hydrate with schema hints for models referenced in this controller
        carried = RailsAiContext::Payload.controller_file(ctx, name)
        if RailsAiContext.configuration.hydration_enabled && carried
          hydration = Hydrators::ControllerHydrator.call(rails_app.root.join(carried).to_s, context: ctx)
          hydration_text = Hydrators::HydrationFormatter.format(hydration)
          lines << "" << hydration_text unless hydration_text.empty?
        end

        # Cross-reference hints. The route key is the controller's path, which
        # the class name does not reproduce wherever an inflection is in play.
        ctrl_path = RailsAiContext::Payload.controller_route_key(ctx, name)
        # The model is a guess off the path, so it is only offered when the
        # payload carries one by that name.
        model_name = ctrl_path.split("/").last.singularize.camelize
        model_name = nil unless RailsAiContext::Payload.models(ctx).key?(model_name)
        lines << ""
        lines << "_Next: `rails_get_routes(controller:\"#{ctrl_path}\")` for routes"
        lines << " | `rails_get_model_details(model:\"#{model_name}\")` for model" if model_name
        lines << " | `rails_get_view(controller:\"#{ctrl_path.split('/').last}\")` for views_"

        lines.join("\n")
      end
    end
  end
end
