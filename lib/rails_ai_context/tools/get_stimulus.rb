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
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: names + counts. standard: names + targets + actions (default). full: everything including values, outlets, classes."
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

      def self.call(controller: nil, detail: "standard", limit: nil, offset: 0, server_context: nil)
        data = cached_context[:stimulus]
        return text_response("Stimulus introspection not available. Add :stimulus to introspectors.") unless data
        return text_response("Stimulus introspection failed: #{data[:error]}") if data[:error]

        all_controllers = data[:controllers] || []
        return text_response("No Stimulus controllers found.") if all_controllers.empty?

        # Specific controller — accepts both dash and underscore naming
        # (HTML uses data-controller="weekly-chart", file is weekly_chart_controller.js)
        if controller
          normalized = controller.downcase.tr("-", "_")
          ctrl = all_controllers.find { |c| c[:name]&.downcase&.tr("-", "_") == normalized }
          unless ctrl
            names = all_controllers.map { |c| c[:name] }.sort
            return not_found_response("Stimulus controller", controller, names,
              recovery_tool: "Call rails_get_stimulus(detail:\"summary\") to see all controllers. Note: use dashes in HTML, underscores for lookup.")
          end
          return text_response(format_controller_full(ctrl))
        end

        # Pagination
        total = all_controllers.size
        offset_val = [ offset.to_i, 0 ].max
        limit_val = limit.nil? ? 50 : [ limit.to_i, 1 ].max
        sorted_all = all_controllers.sort_by { |c| c[:name]&.to_s || "" }
        controllers = sorted_all.drop(offset_val).first(limit_val)

        if controllers.empty? && total > 0
          return text_response("No controllers at offset #{offset_val}. Total: #{total}. Use `offset:0` to start over.")
        end

        pagination_hint = offset_val + limit_val < total ? "\n_Showing #{controllers.size} of #{total}. Use `offset:#{offset_val + limit_val}` for more. cache_key: #{cache_key}_" : ""

        case detail
        when "summary"
          active = controllers.select { |c| (c[:targets] || []).any? || (c[:actions] || []).any? }
          empty = controllers.reject { |c| (c[:targets] || []).any? || (c[:actions] || []).any? }

          lines = [ "# Stimulus Controllers (#{total})", "" ]
          active.each do |ctrl|
            targets = (ctrl[:targets] || []).size
            actions = (ctrl[:actions] || []).size
            lines << "- **#{ctrl[:name]}** — #{targets} targets, #{actions} actions"
          end
          if empty.any?
            names = empty.map { |c| c[:name] }.join(", ")
            lines << "- _#{names}_ (lifecycle only)"
          end
          lines << "" << "_Use `controller:\"name\"` for full detail._#{pagination_hint}"
          text_response(lines.join("\n"))

        when "standard"
          active = controllers.select { |c| (c[:targets] || []).any? || (c[:actions] || []).any? }
          empty = controllers.reject { |c| (c[:targets] || []).any? || (c[:actions] || []).any? }

          lines = [ "# Stimulus Controllers (#{total})", "" ]
          active.each do |ctrl|
            lines << "## #{ctrl[:name]}"
            lines << "- Targets: #{(ctrl[:targets] || []).join(', ')}" if ctrl[:targets]&.any?
            lines << "- Actions: #{(ctrl[:actions] || []).join(', ')}" if ctrl[:actions]&.any?
            lines << ""
          end
          if empty.any?
            names = empty.map { |c| c[:name] }.join(", ")
            lines << "_Lifecycle only (no targets/actions): #{names}_"
          end
          lines << pagination_hint unless pagination_hint.empty?
          text_response(lines.join("\n"))

        when "full"
          lines = [ "# Stimulus Controllers (#{total})", "" ]
          lines << "_HTML naming: `data-controller=\"my-name\"` (dashes in HTML, underscores in filenames)_" << ""
          controllers.each do |ctrl|
            lines << format_controller_full(ctrl) << ""
          end
          text_response(lines.join("\n"))

        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end
      end

      private_class_method def self.format_controller_full(ctrl)
        lines = [ "## #{ctrl[:name]}" ]
        lines << "- **Targets:** #{ctrl[:targets].join(', ')}" if ctrl[:targets]&.any?
        lines << "- **Actions:** #{ctrl[:actions].join(', ')}" if ctrl[:actions]&.any?
        lines << "- **Values:** #{ctrl[:values].map { |k, v| "#{k}:#{v}" }.join(', ')}" if ctrl[:values]&.any?
        lines << "- **Outlets:** #{ctrl[:outlets].join(', ')}" if ctrl[:outlets]&.any?
        lines << "- **Classes:** #{ctrl[:classes].join(', ')}" if ctrl[:classes]&.any?

        # Detect lifecycle methods from source
        lifecycle = detect_lifecycle(ctrl[:file])
        lines << "- **Lifecycle:** #{lifecycle.join(', ')}" if lifecycle&.any?

        lines << "- **File:** #{ctrl[:file]}" if ctrl[:file]

        # HTML data-attribute format — copy-paste ready
        html_attrs = generate_html_attrs(ctrl)
        if html_attrs.any?
          lines << "" << "### HTML Usage (copy-paste)"
          lines << "```html"
          lines << html_attrs.join("\n")
          lines << "```"
        end

        # Reverse view lookup — where this controller is used
        views_using = find_views_using(ctrl[:name])
        if views_using.any?
          lines << "" << "### Used in views"
          views_using.each { |v| lines << "- `#{v}`" }
        end

        lines.join("\n")
      end

      private_class_method def self.generate_html_attrs(ctrl)
        name = ctrl[:name]
        attrs = []
        attrs << "data-controller=\"#{name}\""

        (ctrl[:targets] || []).each do |t|
          attrs << "data-#{name}-target=\"#{t}\""
        end

        (ctrl[:values] || {}).each do |k, _v|
          # Convert camelCase to kebab-case for HTML attribute
          kebab = k.to_s.gsub(/([a-z])([A-Z])/, '\1-\2').downcase
          attrs << "data-#{name}-#{kebab}-value=\"...\""
        end

        (ctrl[:actions] || []).each do |a|
          attrs << "data-action=\"click->#{name}##{a}\""
        end

        attrs
      end

      private_class_method def self.find_views_using(controller_name)
        views_dir = Rails.root.join("app", "views")
        return [] unless Dir.exist?(views_dir)

        pattern = "data-controller=\"#{controller_name}\""
        # Also check for multi-controller declarations
        alt_pattern = controller_name

        Dir.glob(File.join(views_dir, "**", "*.{erb,html.erb}")).filter_map do |path|
          content = File.read(path) rescue next
          next unless content.include?(alt_pattern)
          path.sub("#{Rails.root}/app/views/", "")
        end.first(10)
      rescue
        []
      end

      private_class_method def self.detect_lifecycle(relative_path)
        return nil unless relative_path
        path = Rails.root.join("app/javascript/controllers", relative_path)
        return nil unless File.exist?(path)

        content = File.read(path) rescue nil
        return nil unless content

        methods = []
        methods << "connect" if content.match?(/\bconnect\s*\(\s*\)/)
        methods << "disconnect" if content.match?(/\bdisconnect\s*\(\s*\)/)
        methods << "initialize" if content.match?(/\binitialize\s*\(\s*\)/)
        methods
      end
    end
  end
end
