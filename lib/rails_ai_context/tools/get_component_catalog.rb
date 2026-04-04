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
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Level of detail: summary (names + types), standard (+ props + slots), full (+ sidecar assets + usage)"
          },
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

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(component: nil, detail: "standard", offset: 0, limit: nil, server_context: nil)
        data = cached_context[:components]

        unless data.is_a?(Hash) && !data[:error]
          return text_response("No component data available. Ensure :components introspector is enabled and app/components/ exists.")
        end

        components = data[:components] || []

        if component
          component = component.to_s.strip

          if components.empty?
            return text_response("Component '#{component}' not found — no components exist in app/components/. Create ViewComponent or Phlex components first.")
          end

          found = components.find { |c|
            c[:name]&.downcase == component.downcase ||
            c[:name]&.underscore&.downcase == component.downcase ||
            c[:name]&.sub(/Component\z/, "")&.downcase == component.downcase
          }

          return not_found_response("component", component,
            components.map { |c| c[:name] },
            recovery_tool: "rails_get_component_catalog") unless found

          text_response(render_single(found, detail))
        else
          if components.empty?
            return text_response(
              "No components found in app/components/.\n\n" \
              "This app may use ERB partials instead of ViewComponent/Phlex. Try:\n" \
              "- `rails_get_partial_interface(partial:\"shared/partial_name\")` — partial locals contract + usage\n" \
              "- `rails_get_view(controller:\"name\")` — view templates with partial/Stimulus references\n" \
              "- `rails_get_design_system` — UI component patterns extracted from views"
            )
          end
          text_response(render_catalog(components, data[:summary], detail, offset: offset, limit: limit))
        end
      end

      class << self
        private

        def render_catalog(components, summary, detail, offset: 0, limit: nil)
          page = paginate(components, offset: offset, limit: limit, default_limit: 50)

          lines = [ "# Component Catalog", "" ]

          if summary
            lines << "**Total:** #{summary[:total]} components " \
              "(#{summary[:view_component]} ViewComponent, #{summary[:phlex]} Phlex)"
            lines << "**With slots:** #{summary[:with_slots]} | **With previews:** #{summary[:with_previews]}"
            lines << ""
          end

          page[:items].each do |comp|
            case detail
            when "summary"
              lines << "- **#{comp[:name]}** (#{comp[:type]}) — #{comp[:slots]&.size || 0} slots, #{comp[:props]&.size || 0} props"
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
              if slot[:type] == :many
                result += "\n  <% c.with_#{slot[:name]} do %>item<% end %>"
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
