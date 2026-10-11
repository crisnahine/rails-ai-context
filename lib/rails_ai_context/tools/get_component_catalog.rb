# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetComponentCatalog < BaseTool
      tool_name "rails_get_component_catalog"
      description "Returns ViewComponent and Phlex component catalog: props, slots, previews, " \
        "which views render each component. " \
        "Use when: building views with components, understanding component API, finding reusable components. " \
        "Key params: component (filter by name), detail level."

      input_schema(
        properties: {
          component: {
            type: "string",
            description: "Component name to show details for (e.g., 'AlertComponent', 'alert')"
          },
          detail: RailsAiContext::DetailLevel.schema("Level of detail: summary (names + types), standard (+ props + slots), full (+ sidecar assets + usage)"),
          offset: {
            type: "integer",
            description: "Skip this many components for pagination. Default: 0."
          },
          limit: {
            type: "integer",
            description: "Max components to return. Default: 50."
          }
        }
      )

      guide_row(
        order: 25,
        mcp: "rails_get_component_catalog(component:\"X\")",
        cli_args: "component=X",
        summary: "ViewComponent/Phlex: props, slots, previews, usage"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(component: nil, detail: "standard", offset: 0, limit: nil, server_context: nil)
        blank = blank_name_response("component", component)
        return blank if blank

        fetch_section(:components, unusable_message: "No component data available. Ensure :components introspector is enabled and app/components/ exists.") do |data|
          components = data[:components] || []

          if component
            component = component.to_s.strip

            if components.empty?
              note = api_only_note("app/components", dir: "app/components")
              return text_response(note) if note

              return text_response("Component '#{echo_input(component)}' not found - no components exist in app/components/. Create ViewComponent or Phlex components first.")
            end

            found = matching_components(components + Array(data[:bases]), component)

            return not_found_response("component", component,
              components.map { |c| c[:name] },
              recovery_tool: "rails_get_component_catalog") if found.empty?
            return ambiguous_response(component, found) if found.size > 1

            text_response(render_single(found.first, detail))
          else
            if components.empty?
              note = api_only_note("app/components", dir: "app/components")
              return text_response(note) if note

              return text_response(
                "No components found in app/components/.\n\n" \
                "This app may use ERB partials instead of ViewComponent/Phlex. Try:\n" \
                "- `rails_get_partial_interface(partial:\"shared/partial_name\")` - partial locals contract + usage\n" \
                "- `rails_get_view(controller:\"name\")` - view templates with partial/Stimulus references"
              )
            end
            text_response(render_catalog(components, data[:summary], detail, offset: offset, limit: limit, bases: data[:bases]))
          end
        end
      end

      class << self
        private

        # Matched on whole constant segments, with or without the shared suffix; a substring hit
        # would be another component's answer.
        def matching_components(components, query)
          names = components.map { |c| c[:name] }.compact
          matched = exact_matches(query, names)
          matched = exact_matches("#{query}Component", names) if matched.empty?
          components.select { |c| matched.include?(c[:name]) }
        end

        # Several components of one name is a question, not a resolution.
        def ambiguous_response(query, found)
          lines = [ "Component '#{query}' names #{count_phrase(found.size, "component")}:", "" ]
          found.each { |c| lines << "- **#{c[:name]}** (`#{c[:file]}`)" }
          lines << "" << "_Pass one by its full name, e.g. `#{found.first[:name]}`._"
          empty_response(lines.join("\n"))
        end

        def render_catalog(components, summary, detail, offset: 0, limit: nil, bases: nil)
          page = paginate(components, offset: offset, limit: limit, default_limit: 50)

          lines = [ "# Component Catalog", "" ]

          if summary
            # The same partition the generated files print, so the buckets add up to the total.
            buckets = Serializers::SectionFacts.component_buckets(summary)
            lines << "**Total:** #{count_phrase(summary[:total], "component")} (#{buckets.join(', ')})"
            lines << "**With slots:** #{summary[:with_slots]} | **With previews:** #{summary[:with_previews]}"
            lines << ""
          end

          note = bases_note("components", Array(bases).map { |base| base[:name] })
          if note
            lines << note << ""
          end

          page[:items].each do |comp|
            case detail
            when "summary"
              lines << "- **#{comp[:name]}** (#{comp[:type]}) - #{count_phrase(comp[:slots]&.size || 0, "slot")}, #{count_phrase(comp[:props]&.size || 0, "prop")}"
            when "standard"
              lines.concat(render_component_standard(comp))
            when "full"
              lines.concat(render_component_full(comp))
            end
          end

          lines << "" << page[:hint] unless page[:hint].empty?
          lines.join("\n")
        end

        def render_single(comp, detail)
          lines = [ "# #{comp[:name]}", "" ]
          lines << "**Type:** #{comp[:type]}"
          lines << "**File:** #{comp[:file]}"
          lines << ""

          lines.concat(render_component_full(comp))
          lines.join("\n")
        end

        def render_component_standard(comp)
          lines = [ "## #{comp[:name]} (#{comp[:type]})", "" ]

          if comp[:props]&.any?
            lines << "**Props:**"
            comp[:props].each do |prop|
              default = prop[:default] ? " (default: #{prop[:default]})" : ""
              values = prop[:values]&.any? ? " -- values: #{prop[:values].join(', ')}" : ""
              lines << "  - `#{prop[:name]}`#{default}#{values}"
            end
          end

          if comp[:slots]&.any?
            lines << "**Slots:**"
            comp[:slots].each do |slot|
              lines << "  - `#{slot[:name]}` (#{slot[:type]})"
            end
          end

          lines << ""
          lines
        end

        def render_component_full(comp)
          lines = render_component_standard(comp)

          if comp[:sidecar_assets]&.any?
            lines << "**Sidecar assets:** #{comp[:sidecar_assets].join(', ')}"
          end

          if comp[:preview]
            lines << "**Preview:** #{comp[:preview]}"
          end

          # Generate usage example
          lines << ""
          lines << "**Usage:**"
          lines << "```erb"
          lines << generate_usage_example(comp)
          lines << "```"
          lines << ""

          lines
        end

        def generate_usage_example(comp)
          name = comp[:name]
          props = comp[:props] || []
          slots = comp[:slots] || []

          parts = props.map { |p|
            if p[:default]
              "#{p[:name]}: #{p[:default]}"
            else
              "#{p[:name]}: value"
            end
          }

          init = parts.any? ? "(#{parts.join(', ')})" : ".new"

          if slots.empty?
            if init == ".new"
              "<%= render #{name}.new %>"
            else
              "<%= render #{name}.new#{init} do %>\n  Content here\n<% end %>"
            end
          else
            result = "<%= render #{name}.new#{init == ".new" ? "" : init} do |c| %>"
            slots.each do |slot|
              if slot[:setters]
                filler = slot[:type] == :many ? "item" : "content"
                slot[:setters].each { |setter| result += "\n  <% c.with_#{setter} do %>#{filler}<% end %>" }
              elsif slot[:type] == :many
                result += "\n  <% c.with_#{slot[:name].to_s.singularize} do %>item<% end %>"
              else
                result += "\n  <% c.with_#{slot[:name]} do %>content<% end %>"
              end
            end
            result += "\n  Main content\n<% end %>"
            result
          end
        end
      end
    end
  end
end
