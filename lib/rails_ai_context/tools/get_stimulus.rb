# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetStimulus < BaseTool
      tool_name "rails_get_stimulus"
      description "Get Stimulus controllers: targets, values, actions, outlets, classes. " \
        "Use when: wiring up data-controller attributes in views, adding targets/values, or checking existing Stimulus behavior. " \
        "Filter with controller:\"filter-form\" for one controller's full API, or list all with detail:\"summary\"."

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Specific Stimulus controller name (e.g. 'hello', 'filter-form'). Case-insensitive."
          },
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: names + counts. standard: targets + values + actions (default). full: everything including outlets, classes, HTML usage."),
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
        order: 10,
        mcp: "rails_get_stimulus(controller:\"X\")",
        cli_args: "controller=X",
        summary: "Targets, values, actions + HTML data-attributes + view lookup"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, detail: "standard", limit: nil, offset: 0, server_context: nil)
        fetch_section(:stimulus, subject: "Stimulus introspection") do |data|
          all_controllers = data[:controllers] || []
          if all_controllers.empty?
            note = api_only_note("Stimulus")
            return text_response(note) if note

            roots = RailsAiContext::Introspectors::StimulusIntrospector::JS_ROOTS.join(", ")
            return text_response("No Stimulus controllers found under #{roots}.")
          end

          # Specific controller, however it is spelled: the identifier with
          # dashes or underscores, PascalCase, or the path the file sits at.
          if controller
            found = lookup_controllers(all_controllers, controller)
            if found.empty?
              names = all_controllers.map { |c| c[:name] }.sort
              return not_found_response("Stimulus controller", controller, names,
                recovery_tool: "Call rails_get_stimulus(detail:\"summary\") to see all controllers. The identifier resolves with dashes or underscores, and so does the file's path or name.")
            end
            if found.size > 1
              lines = [ "Stimulus controller '#{controller}' matches #{found.size} controllers:", "" ]
              lines.concat(found.map { |c| "- **#{c[:name]}** (`#{c[:file] || c[:package]}`)" })
              lines << "" << "_Pass one of these names._"
              return text_response(lines.join("\n"))
            end
            return text_response(format_controller_full(found.first))
          end

          # Pagination
          total = all_controllers.size
          sorted_all = all_controllers.sort_by { |c| c[:name]&.to_s || "" }
          page = paginate(sorted_all, offset: offset, limit: limit)
          controllers = page[:items]

          if controllers.empty? && total > 0
            return text_response("No controllers at offset #{page[:offset]}. Total: #{total}. Use `offset:0` to start over.")
          end

          pagination_hint = page[:offset] + page[:limit] < total ? "\n_Showing #{controllers.size} of #{total}. Use `offset:#{page[:offset] + page[:limit]}` for more. cache_key: #{cache_key}_" : ""
          # A controller registered from a package has no source here to read,
          # so it is named with its package rather than filed as lifecycle-only.
          own = controllers.reject { |c| c[:package] }
          packaged = controllers.select { |c| c[:package] }
          pagination_hint = "\n_Registered from a package (source not read): #{packaged.map { |c| "#{c[:name]} (`#{c[:package]}`)" }.join(', ')}_#{pagination_hint}" if packaged.any?
          inferred = controllers.select { |c| c[:identifier_inferred] }.map { |c| c[:name] }
          pagination_hint = "\n_Names inferred from the file path: these sit outside `app/javascript/controllers`, where the app's own loader decides the identifier, and no view or component writes the derived name: #{inferred.join(', ')}_#{pagination_hint}" if inferred.any?

          case detail
          when "summary"
            active = own.select { |c| (c[:targets] || []).any? || (c[:actions] || []).any? || (c[:values].is_a?(Hash) ? c[:values] : {}).any? }
            empty = own.reject { |c| (c[:targets] || []).any? || (c[:actions] || []).any? || (c[:values].is_a?(Hash) ? c[:values] : {}).any? }

            lines = [ "# Stimulus Controllers (#{total})", "" ]
            active.each do |ctrl|
              targets = (ctrl[:targets] || []).size
              values = (ctrl[:values].is_a?(Hash) ? ctrl[:values] : {}).size
              actions = (ctrl[:actions] || []).size
              parts = []
              parts << count_phrase(targets, "target") if targets > 0
              parts << count_phrase(values, "value") if values > 0
              parts << count_phrase(actions, "action") if actions > 0
              lines << "- **#{ctrl[:name]}** - #{parts.join(', ')}"
            end
            if empty.any?
              names = empty.map { |c| c[:name] }.join(", ")
              lines << "- _#{names}_ (lifecycle only)"
            end
            lines << "" << "_Use `controller:\"name\"` for full detail._#{pagination_hint}"
            text_response(lines.join("\n"))

          when "standard"
            active = own.select { |c| (c[:targets] || []).any? || (c[:actions] || []).any? || (c[:values].is_a?(Hash) ? c[:values] : {}).any? }
            empty = own.reject { |c| (c[:targets] || []).any? || (c[:actions] || []).any? || (c[:values].is_a?(Hash) ? c[:values] : {}).any? }

            lines = [ "# Stimulus Controllers (#{total})", "" ]
            active.each do |ctrl|
              lines << "## #{ctrl[:name]}"
              lines << "- Targets: #{(ctrl[:targets] || []).join(', ')}" if ctrl[:targets]&.any?
              lines << "- Values: #{(ctrl[:values].is_a?(Hash) ? ctrl[:values] : {}).map { |k, v| "#{k} (#{v})" }.join(', ')}" if (ctrl[:values].is_a?(Hash) ? ctrl[:values] : {}).any?
              lines << "- Actions: #{(ctrl[:actions] || []).join(', ')}" if ctrl[:actions]&.any?
              if ctrl[:complexity].is_a?(Hash)
                parts = []
                parts << "#{ctrl[:complexity][:loc]} LOC" if ctrl[:complexity][:loc]
                parts << count_phrase(ctrl[:complexity][:method_count], "method") if ctrl[:complexity][:method_count]
                lines << "- Complexity: #{parts.join(', ')}" if parts.any?
              end
              lines << "- Imports: #{ctrl[:import_graph].join(', ')}" if ctrl[:import_graph]&.any?
              lines << "- Turbo events: #{ctrl[:turbo_event_listeners].join(', ')}" if ctrl[:turbo_event_listeners]&.any?
              lines << ""
            end
            if empty.any?
              names = empty.map { |c| c[:name] }.join(", ")
              lines << "_Lifecycle only (no targets/values/actions): #{names}_"
            end

            # Cross-controller composition
            if data[:cross_controller_composition]&.any?
              lines << "" << "## Cross-Controller Composition"
              lines.concat(composition_lines(data[:cross_controller_composition]))
            end

            lines << pagination_hint unless pagination_hint.empty?
            text_response(lines.join("\n"))

          when "full"
            lines = [ "# Stimulus Controllers (#{total})", "" ]
            lines << "_HTML naming: `data-controller=\"my-name\"` (dashes in HTML, underscores in filenames)_" << ""
            controllers.each do |ctrl|
              lines << format_controller_full(ctrl) << ""
            end

            # Cross-controller composition
            if data[:cross_controller_composition]&.any?
              lines << "## Cross-Controller Composition"
              lines.concat(composition_lines(data[:cross_controller_composition]))
              lines << ""
            end

            text_response(lines.join("\n"))

          end
        end
      end

      # Tightest reading first (name, path spelling, file, end of the file's path, single
      # underscores); every controller the first matching reading finds is returned.
      private_class_method def self.lookup_controllers(controllers, asked)
        keys = [ lookup_key(asked), lookup_key(asked.underscore) ].uniq
        readings = [
          ->(c) { keys.include?(lookup_key(c[:name])) },
          ->(c) { c[:path_name] && keys.include?(lookup_key(c[:path_name])) },
          ->(c) { c[:file] && keys.include?(lookup_key(c[:file])) },
          ->(c) { c[:file] && keys.any? { |k| "--#{lookup_key(c[:file])}".end_with?("--#{k}") } },
          ->(c) { keys.map { |k| k.gsub("--", "-") }.include?(lookup_key(c[:name]).gsub("--", "-")) }
        ]
        readings.each do |reading|
          found = controllers.select(&reading)
          return found if found.any?
        end
        []
      end

      # One spelling to compare by: `users/tools/ajax_controller.js`, `users__tools__ajax`
      # and `users--tools--ajax` all become `users--tools--ajax`.
      private_class_method def self.lookup_key(text)
        text.to_s.downcase
            .sub(/\.(?:js|ts|jsx|tsx)\z/, "")
            .sub(/[._-]controller\z/, "")
            .gsub("/", "--").tr("_", "-")
      end

      private_class_method def self.composition_lines(compositions)
        compositions.first(10).map do |comp|
          "- `#{comp[:file]}` - #{Array(comp[:controllers]).join(' + ')}"
        end
      end

      private_class_method def self.format_controller_full(ctrl)
        lines = [ "## #{ctrl[:name]}" ]
        lines << "- **Targets:** #{ctrl[:targets].join(', ')}" if ctrl[:targets]&.any?
        lines << "- **Actions:** #{ctrl[:actions].join(', ')}" if ctrl[:actions]&.any?
        lines << "- **Values:** #{ctrl[:values].map { |k, v| "#{k}:#{v}" }.join(', ')}" if ctrl[:values]&.any?
        lines << "- **Outlets:** #{ctrl[:outlets].join(', ')}" if ctrl[:outlets]&.any?
        lines << "- **Classes:** #{ctrl[:classes].join(', ')}" if ctrl[:classes]&.any?

        # Complexity metrics
        if ctrl[:complexity].is_a?(Hash)
          parts = []
          parts << "#{ctrl[:complexity][:loc]} LOC" if ctrl[:complexity][:loc]
          parts << count_phrase(ctrl[:complexity][:method_count], "method") if ctrl[:complexity][:method_count]
          lines << "- **Complexity:** #{parts.join(', ')}" if parts.any?
        end

        # Import graph
        lines << "- **Imports:** #{ctrl[:import_graph].join(', ')}" if ctrl[:import_graph]&.any?

        # Turbo event listeners
        lines << "- **Turbo events:** #{ctrl[:turbo_event_listeners].join(', ')}" if ctrl[:turbo_event_listeners]&.any?

        lifecycle = ctrl[:lifecycle]
        lines << "- **Lifecycle:** #{lifecycle.join(', ')}" if lifecycle&.any?

        lines << "- **File:** #{ctrl[:file]}" if ctrl[:file]
        lines << "- **Registered from package:** `#{ctrl[:package]}` (source not read, so no targets, values or actions)" if ctrl[:package]
        lines << "- **Path spelling:** `#{ctrl[:path_name]}` (also resolves in a lookup)" if ctrl[:path_name]
        lines << "- **Identifier:** inferred from the file path (outside `app/javascript/controllers`, and no view or component writes it)" if ctrl[:identifier_inferred]

        # HTML data-attribute format - copy-paste ready
        html_attrs = generate_html_attrs(ctrl)
        if html_attrs.any?
          lines << "" << "### HTML Usage (copy-paste)"
          lines << "```html"
          lines << html_attrs.join("\n")
          lines << "```"
        end

        # Reverse view lookup - where this controller is used
        views_using = find_views_using(ctrl[:name])
        if views_using.any?
          lines << "" << (views_using.all? { |_, view| view } ? "### Used in views" : "### Used in")
          views_using.each { |file, _| lines << "- `#{file}`" }
        end

        lines.join("\n")
      end

      private_class_method def self.generate_html_attrs(ctrl)
        # Stimulus uses dashes in HTML, underscores only in filenames
        html_name = ctrl[:name].tr("_", "-")
        attrs = []
        attrs << "data-controller=\"#{html_name}\""

        (ctrl[:targets] || []).each do |t|
          attrs << "data-#{html_name}-target=\"#{t}\""
        end

        (ctrl[:values] || {}).each do |k, _v|
          # Convert camelCase to kebab-case for HTML attribute
          kebab = k.to_s.gsub(/([a-z])([A-Z])/, '\1-\2').downcase
          attrs << "data-#{html_name}-#{kebab}-value=\"...\""
        end

        (ctrl[:actions] || []).each do |a|
          attrs << "data-action=\"click->#{html_name}##{a}\""
        end

        attrs
      end

      # Views are named by their path under their views root, anything else from the app root.
      private_class_method def self.find_views_using(controller_name)
        root = rails_app.root.to_s
        real_root = File.realpath(root)
        token = controller_name.to_s.tr("_", "-")
        view_dirs = RailsAiContext::PathResolver.view_dirs(root)

        hits = Introspectors::StimulusIntrospector.template_files(root).filter_map do |path|
          next unless RailsAiContext::SafePath.contained?(File.realpath(path), real_root)

          raw = RailsAiContext::SafeFile.read(path) or next
          next unless Introspectors::StimulusIntrospector.identifiers_in(path, raw).include?(token)

          dir = RailsAiContext::ViewFile.root_for(path, view_dirs)
          dir ? [ path.delete_prefix("#{dir}/"), true ] : [ path.delete_prefix("#{root}/"), false ]
        rescue SystemCallError
          next
        end
        views, others = hits.partition { |_, view| view }
        (views + others).first(10)
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "find_views_using")
      end
    end
  end
end
