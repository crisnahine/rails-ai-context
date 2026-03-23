# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetDesignSystem < BaseTool
      tool_name "rails_get_design_system"
      description "Returns the app's design system: color palette with semantic roles, component patterns " \
        "with real HTML/ERB examples from actual views, typography scale, layout conventions, " \
        "responsive breakpoints, and interactive state patterns. " \
        "Use when: building new views/pages, matching existing UI style, or ensuring design consistency. " \
        "Key params: detail (summary for palette + components, standard for + page examples, full for everything)."

      input_schema(
        properties: {
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Level of detail: summary (palette + components), standard (+ canonical page examples), full (+ responsive/typography/dark mode)"
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(detail: "standard", server_context: nil) # rubocop:disable Metrics
        vt = cached_context[:view_templates]
        dt = cached_context[:design_tokens]

        unless vt.is_a?(Hash) && !vt[:error]
          return text_response("No view templates found. Ensure your app has views in app/views/ and the :view_templates introspector is enabled.")
        end

        patterns = vt[:ui_patterns] || {}
        components = patterns[:components] || []

        if components.empty?
          return text_response("No UI components detected. The app may not have enough view templates with CSS classes to extract design patterns.")
        end

        lines = [ "# Design System", "" ]

        # Color palette with semantic roles
        lines.concat(render_colors(patterns, dt))

        # Component patterns
        lines.concat(render_components(components, detail))

        if %w[standard full].include?(detail)
          # Canonical page examples (real HTML snippets)
          lines.concat(render_canonical_examples(patterns))

          # Design rules
          lines.concat(render_rules(patterns))
        end

        if detail == "full"
          # Typography
          lines.concat(render_typography(patterns))

          # Layout & spacing
          lines.concat(render_layout(patterns))

          # Responsive patterns
          lines.concat(render_responsive(patterns))

          # Interactive states
          lines.concat(render_interactive(patterns))

          # Dark mode
          lines.concat(render_dark_mode(patterns))

          # Icons
          lines.concat(render_icons(patterns))

          # Animations
          lines.concat(render_animations(patterns))

          # Design tokens
          lines.concat(render_tokens(dt))
        end

        text_response(lines.join("\n"))
      end

      class << self
        private

        def render_colors(patterns, dt)
          scheme = patterns[:color_scheme] || {}
          lines = [ "## Color Palette", "" ]

          lines << "- **Primary:** #{scheme[:primary]} — use for CTAs, active states, links" if scheme[:primary]
          lines << "- **Danger:** #{scheme[:danger]} — destructive actions only (delete, remove)" if scheme[:danger]
          lines << "- **Success:** #{scheme[:success]} — confirmations, positive feedback" if scheme[:success]
          lines << "- **Warning:** #{scheme[:warning]} — warnings, important notices" if scheme[:warning]
          lines << "- **Text:** #{scheme[:text]}" if scheme[:text]

          if scheme[:background_palette]&.any?
            lines << "- **Backgrounds:** #{scheme[:background_palette].first(6).join(', ')}"
          end
          if scheme[:text_palette]&.any?
            lines << "- **Text colors:** #{scheme[:text_palette].first(6).join(', ')}"
          end
          if scheme[:border_palette]&.any?
            lines << "- **Borders:** #{scheme[:border_palette].first(4).join(', ')}"
          end

          # Design token colors (DS21: filter oklch noise from summary)
          if dt.is_a?(Hash) && !dt[:error]
            colors = dt.dig(:categorized, :colors) || {}
            # Filter oklch/complex values in non-full modes — show only hex/rgb/named
            readable_colors = colors.reject { |_, v| v.to_s.match?(/oklch|calc|var\(/) }
            if readable_colors.any?
              lines << "" << "### Token Colors"
              readable_colors.first(10).each { |name, value| lines << "- `#{name}`: #{value}" }
            end
          end

          lines << ""
          lines
        end

        def render_components(components, detail)
          lines = [ "## Components — Copy These Patterns", "" ]

          by_type = components.group_by { |c| c[:type] }
          by_type.each do |_type, comps|
            comps.each do |c|
              lines << "**#{c[:label]}:** `#{c[:classes]}`"
              if detail == "full" && c[:variants]&.any?
                c[:variants].each do |v|
                  lines << "  - variant: `#{v[:classes]}` (#{v[:count]}x)"
                end
              end
            end
          end

          lines << ""
          lines
        end

        def render_canonical_examples(patterns)
          examples = patterns[:canonical_examples] || []
          return [] if examples.empty?

          lines = [ "## Page Examples — Copy These Patterns", "" ]

          labels = { form_page: "Form Page", list_page: "List/Grid Page",
                     show_page: "Detail Page", dashboard: "Dashboard" }

          examples.each do |ex|
            label = labels[ex[:type]] || ex[:type].to_s.tr("_", " ").capitalize
            lines << "### #{label} (`#{ex[:template]}`)"
            lines << ""
            lines << "Components used: #{ex[:components_used].join(', ')}" if ex[:components_used]&.any?
            lines << ""
            lines << "```erb"
            lines.concat(ex[:snippet].lines.map(&:chomp))
            lines << "```"
            lines << ""
          end

          lines
        end

        def render_rules(patterns)
          lines = [ "## Design Rules", "" ]

          lines << "- Always use responsive breakpoints (mobile-first with md: and lg: variants)" if patterns[:responsive]&.any?
          lines << "- All interactive elements MUST have hover: and focus: states" if patterns.dig(:interactive_states, "hover") || patterns.dig(:interactive_states, "focus")

          if patterns.dig(:layout, :spacing_scale)&.any?
            top = patterns[:layout][:spacing_scale].keys.first(4).join(", ")
            lines << "- Use existing spacing scale: #{top}"
          end

          radius = patterns[:radius] || {}
          if radius.any?
            lines << "- Border radius: #{radius.map { |type, r| "#{r} (#{type})" }.join(', ')}"
          end

          lines << "- Mirror all bg/text colors with dark: variants" if patterns.dig(:dark_mode, :used)
          lines << "- Reuse shared partials from app/views/shared/ before creating new markup"
          lines << ""
          lines
        end

        def render_typography(patterns)
          typo = patterns[:typography] || {}
          return [] if typo.empty?

          lines = [ "## Typography", "" ]
          if typo[:heading_styles]&.any?
            typo[:heading_styles].each { |tag, classes| lines << "- **#{tag}:** `#{classes}`" }
          end
          lines << "- Sizes: #{typo[:sizes].keys.join(', ')}" if typo[:sizes]&.any?
          lines << "- Weights: #{typo[:weights].keys.join(', ')}" if typo[:weights]&.any?
          lines << "- Line height: #{typo[:line_height].keys.join(', ')}" if typo[:line_height]&.any?
          lines << ""
          lines
        end

        def render_layout(patterns)
          layout = patterns[:layout] || {}
          fl = patterns[:form_layout] || {}
          return [] if layout.empty? && fl.empty?

          lines = [ "## Layout & Spacing", "" ]
          lines << "- Containers: #{layout[:containers].keys.join(', ')}" if layout[:containers]&.any?
          lines << "- Grid: #{layout[:grid].keys.join(', ')}" if layout[:grid]&.any?
          lines << "- Flex: #{layout[:flex].keys.first(5).join(', ')}" if layout[:flex]&.any?
          lines << "- Spacing scale: #{layout[:spacing_scale].keys.join(', ')}" if layout[:spacing_scale]&.any?
          lines << "- Form spacing: #{fl[:spacing]}" if fl[:spacing]
          lines << "- Form grid: #{fl[:grid]}" if fl[:grid]
          lines << ""
          lines
        end

        def render_responsive(patterns)
          responsive = patterns[:responsive] || {}
          return [] if responsive.empty?

          lines = [ "## Responsive Breakpoints", "" ]
          responsive.each do |bp, classes|
            lines << "- **#{bp}:** #{classes.keys.first(5).join(', ')}"
          end
          lines << ""
          lines
        end

        def render_interactive(patterns)
          states = patterns[:interactive_states] || {}
          return [] if states.empty?

          lines = [ "## Interactive States", "" ]
          states.each do |state, classes|
            lines << "- **#{state}:** #{classes.keys.first(4).join(', ')}"
          end
          lines << ""
          lines
        end

        def render_dark_mode(patterns)
          dark = patterns[:dark_mode] || {}
          return [] unless dark[:used]

          lines = [ "## Dark Mode", "" ]
          lines << "Dark mode is active. Use `dark:` prefix for all color-dependent classes."
          lines << "- Common patterns: #{dark[:patterns].keys.first(8).join(', ')}" if dark[:patterns]&.any?
          lines << ""
          lines
        end

        def render_icons(patterns)
          icons = patterns[:icons]
          return [] unless icons.is_a?(Hash) && (icons[:library] || icons[:inline_svg_count])

          lines = [ "## Icons", "" ]
          lines << "- Library: #{icons[:library]}" if icons[:library]
          lines << "- Inline SVGs: #{icons[:inline_svg_count]}" if icons[:inline_svg_count]
          lines << "- Sizes: #{icons[:sizes].keys.first(3).join(', ')}" if icons[:sizes]&.any?
          lines << ""
          lines
        end

        def render_animations(patterns)
          anims = patterns[:animations]
          return [] unless anims.is_a?(Hash) && anims.any?

          lines = [ "## Animations & Transitions", "" ]
          lines << "- Transitions: #{anims[:transitions].keys.join(', ')}" if anims[:transitions]&.any?
          lines << "- Durations: #{anims[:durations].keys.join(', ')}" if anims[:durations]&.any?
          lines << "- Animations: #{anims[:animates].keys.join(', ')}" if anims[:animates]&.any?
          lines << "- Easing: #{anims[:easing].keys.join(', ')}" if anims[:easing]&.any?
          lines << ""
          lines
        end

        def render_tokens(dt)
          return [] unless dt.is_a?(Hash) && !dt[:error]

          categorized = dt[:categorized] || {}
          return [] if categorized.empty?

          lines = [ "## Design Tokens (from #{dt[:framework]} config)", "" ]

          categorized.each do |category, tokens|
            next if category == :other || category == :colors # colors shown above
            lines << "### #{category.to_s.capitalize}"
            tokens.first(8).each { |name, value| lines << "- `#{name}`: #{value}" }
            lines << ""
          end

          lines
        end
      end
    end
  end
end
