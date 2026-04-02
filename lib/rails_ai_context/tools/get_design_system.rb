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
          # Layout patterns (stat cards, progress bars, section headers)
          lines.concat(render_layout_patterns)

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

          # Font loading
          if dt.is_a?(Hash) && dt[:font_loading].is_a?(Hash) && dt[:font_loading].any?
            lines << "## Font Loading" << ""
            dt[:font_loading].each { |key, val| lines << "- **#{key}:** #{val}" }
            lines << ""
          end
        end

        # ViewComponents — grouped by category
        if cached_context[:components].is_a?(Hash) && !cached_context[:components][:error] && cached_context[:components][:components]&.any?
          comp_data = cached_context[:components][:components]

          # Group components by inferred category from file path or name
          grouped = comp_data.group_by { |c| categorize_component(c) }
          lines << "## Components (#{comp_data.size})" << ""

          grouped.sort_by { |cat, _| cat }.each do |category, comps|
            lines << "### #{category}"
            comps.each do |c|
              slots = c[:slots]&.size || 0
              props = c[:props]&.size || 0
              meta = []
              meta << "#{slots} slots" if slots > 0
              meta << "#{props} props" if props > 0
              meta_str = meta.any? ? " (#{meta.join(', ')})" : ""
              lines << "- **#{c[:name]}**#{meta_str}"
            end
            lines << ""
          end
        end

        # Accessibility
        if cached_context[:accessibility].is_a?(Hash) && !cached_context[:accessibility][:error]
          a11y = cached_context[:accessibility]
          if a11y[:score] || a11y[:aria_usage]&.any? || a11y[:landmarks]&.any?
            lines << "## Accessibility" << ""
            lines << "- **Score:** #{a11y[:score]}" if a11y[:score]
            lines << "- **ARIA usage:** #{a11y[:aria_usage].first(5).join(', ')}" if a11y[:aria_usage]&.any?
            lines << "- **Landmarks:** #{a11y[:landmarks].first(5).join(', ')}" if a11y[:landmarks]&.any?
            lines << "- **Alt text coverage:** #{a11y[:alt_text_coverage]}" if a11y[:alt_text_coverage]
            lines << ""
          end
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

        def render_components(components, detail) # rubocop:disable Metrics
          lines = [ "## Components — Copy These Patterns", "" ]

          by_type = components.group_by { |c| c[:type] }
          by_type.each do |_type, comps|
            comps.each do |c|
              canonical_variant = find_canonical_variant(c)

              case detail
              when "summary"
                # Just class strings (original behavior)
                lines << "**#{c[:label]}:** `#{c[:classes]}`"

              when "standard"
                # Class strings + canonical HTML/ERB examples
                lines << "**#{c[:label]}** (CANONICAL): `#{c[:classes]}`"
                lines << ""
                lines.concat(format_component_html(c[:label], c[:classes]))
                lines << ""

              when "full"
                # Canonical + all variants used 2+ times
                lines << "**#{c[:label]}** (CANONICAL): `#{c[:classes]}`"
                lines << ""
                lines.concat(format_component_html(c[:label], c[:classes]))
                lines << ""

                if c[:variants]&.any?
                  significant_variants = c[:variants].select { |v| v[:count] && v[:count] >= 2 }
                  significant_variants.each do |v|
                    next if v[:classes] == canonical_variant

                    lines << "  - variant: `#{v[:classes]}` (#{v[:count]}x)"
                  end
                end
              end
            end
          end

          lines << ""
          lines
        end

        # Find the most-used variant's classes (the canonical one)
        def find_canonical_variant(component)
          return component[:classes] unless component[:variants]&.any?

          best = component[:variants].max_by { |v| v[:count] || 0 }
          best ? best[:classes] : component[:classes]
        end

        # Generate HTML/ERB examples based on the component type detected from the label
        def format_component_html(label, classes) # rubocop:disable Metrics
          downcased = label.downcase
          lines = []

          if downcased.match?(/button|btn/)
            lines << "```html"
            lines << "<button type=\"submit\" class=\"#{classes}\">Label</button>"
            lines << "```"
            lines << ""
            lines << "```erb"
            lines << "<%= link_to \"Label\", path, class: \"#{classes}\" %>"
            lines << "<%= f.submit \"Save\", class: \"#{classes}\" %>"
            lines << "```"
          elsif downcased.match?(/textarea|text_area/)
            lines << "```erb"
            lines << "<%= f.text_area :field_name, class: \"#{classes}\" %>"
            lines << "```"
          elsif downcased.match?(/select/)
            lines << "```erb"
            lines << "<%= f.select :field_name, options, {}, class: \"#{classes}\" %>"
            lines << "```"
          elsif downcased.match?(/input|field/)
            lines << "```erb"
            lines << "<%= f.text_field :field_name, class: \"#{classes}\" %>"
            lines << "```"
          elsif downcased.match?(/card/)
            lines << "```html"
            lines << "<div class=\"#{classes}\">content</div>"
            lines << "```"
          elsif downcased.match?(/badge/)
            lines << "```html"
            lines << "<span class=\"#{classes}\">status</span>"
            lines << "```"
          elsif downcased.match?(/link/)
            lines << "```erb"
            lines << "<%= link_to \"Label\", path, class: \"#{classes}\" %>"
            lines << "```"
          elsif downcased.match?(/heading/)
            tag = if downcased.include?("page") then "h1"
            elsif downcased.include?("section") then "h2"
            elsif downcased.include?("sub") then "h3"
            else "h2"
            end
            lines << "```html"
            lines << "<#{tag} class=\"#{classes}\">Title</#{tag}>"
            lines << "```"
          elsif downcased.match?(/label/)
            lines << "```erb"
            lines << "<%= f.label :field_name, class: \"#{classes}\" %>"
            lines << "```"
          elsif downcased.match?(/flash|alert/)
            lines << "```html"
            lines << "<div class=\"#{classes}\">message</div>"
            lines << "```"
          elsif downcased.match?(/modal|overlay/)
            lines << "```html"
            lines << "<div class=\"#{classes}\">content</div>"
            lines << "```"
          elsif downcased.match?(/list/)
            lines << "```html"
            lines << "<div class=\"#{classes}\">item</div>"
            lines << "```"
          elsif downcased.match?(/nav/)
            lines << "```html"
            lines << "<nav class=\"#{classes}\">links</nav>"
            lines << "```"
          else
            lines << "```html"
            lines << "<div class=\"#{classes}\">content</div>"
            lines << "```"
          end

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

        def render_layout_patterns
          lines = []
          views_dir = Rails.root.join("app", "views")
          return lines unless Dir.exist?(views_dir)

          has_stat_card = false
          has_progress_bar = false
          has_section_header = false

          Dir.glob(File.join(views_dir, "**", "*.html.erb")).each do |path|
            content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            has_stat_card = true if content.match?(/text-3xl\s+font-bold.*text-gray-900/) && content.match?(/text-sm\s+text-gray-500/)
            has_progress_bar = true if content.match?(/bg-gray-\d+\s+rounded-full\s+h-\d/) && content.match?(/bg-orange-\d+\s+h-\d+\s+rounded-full/)
            has_section_header = true if content.match?(/flex.*justify-between.*items-center/) && content.match?(/text-lg\s+font-semibold/)
          end

          return lines unless has_stat_card || has_progress_bar || has_section_header

          lines << "## Layout Patterns — Copy These Structures" << ""

          if has_stat_card
            lines << "**Stat Card Grid** (CANONICAL):"
            lines << "```erb"
            lines << '<div class="grid grid-cols-2 lg:grid-cols-4 gap-4">'
            lines << '  <div class="bg-white rounded-2xl p-6 shadow-sm border border-gray-100">'
            lines << '    <div class="text-sm text-gray-500 mb-1">Label</div>'
            lines << '    <div class="text-3xl font-bold text-gray-900">Value</div>'
            lines << '    <div class="text-xs text-gray-400 mt-1">Subtext</div>'
            lines << "  </div>"
            lines << "</div>"
            lines << "```" << ""
          end

          if has_section_header
            lines << "**Section Header with Action** (CANONICAL):"
            lines << "```erb"
            lines << '<div class="flex justify-between items-center mb-4">'
            lines << '  <h2 class="text-lg font-semibold">Section Title</h2>'
            lines << '  <%= link_to "View All", path, class: "text-orange-600 text-sm font-medium hover:text-orange-700" %>'
            lines << "</div>"
            lines << "```" << ""
          end

          if has_progress_bar
            lines << "**Progress Bar** (CANONICAL):"
            lines << "```erb"
            lines << '<div class="w-32 bg-gray-100 rounded-full h-2">'
            lines << '  <div class="bg-orange-500 h-2 rounded-full" style="width: <%= percentage %>%"></div>'
            lines << "</div>"
            lines << "```" << ""
          end

          lines
        rescue => e
          $stderr.puts "[rails-ai-context] render_layout_patterns failed: #{e.message}" if ENV["DEBUG"]
          []
        end

        def render_rules(patterns)
          lines = [ "## Design Rules", "" ]

          lines << "- Always use responsive breakpoints (mobile-first with md: and lg: variants)" if patterns[:responsive]&.any?
          lines << "- All interactive elements MUST have hover: and focus: states" if patterns.dig(:interactive_states, "hover") || patterns.dig(:interactive_states, "focus")

          if patterns.dig(:layout, :spacing_scale)&.any?
            top = safe_keys(patterns[:layout][:spacing_scale], 4).join(", ")
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
          lines << "- Sizes: #{safe_keys(typo[:sizes]).join(', ')}" if typo[:sizes]&.any?
          lines << "- Weights: #{safe_keys(typo[:weights]).join(', ')}" if typo[:weights]&.any?
          lines << "- Line height: #{safe_keys(typo[:line_height]).join(', ')}" if typo[:line_height]&.any?
          lines << ""
          lines
        end

        def render_layout(patterns)
          layout = patterns[:layout] || {}
          fl = patterns[:form_layout] || {}
          return [] if layout.empty? && fl.empty?

          lines = [ "## Layout & Spacing", "" ]
          lines << "- Containers: #{safe_keys(layout[:containers]).join(', ')}" if layout[:containers]&.any?
          lines << "- Grid: #{safe_keys(layout[:grid]).join(', ')}" if layout[:grid]&.any?
          lines << "- Flex: #{safe_keys(layout[:flex], 5).join(', ')}" if layout[:flex]&.any?
          lines << "- Spacing scale: #{safe_keys(layout[:spacing_scale]).join(', ')}" if layout[:spacing_scale]&.any?
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
            lines << "- **#{bp}:** #{safe_keys(classes, 5).join(', ')}"
          end
          lines << ""
          lines
        end

        def render_interactive(patterns)
          states = patterns[:interactive_states] || {}
          return [] if states.empty?

          lines = [ "## Interactive States", "" ]
          states.each do |state, classes|
            lines << "- **#{state}:** #{safe_keys(classes, 4).join(', ')}"
          end
          lines << ""
          lines
        end

        def render_dark_mode(patterns)
          dark = patterns[:dark_mode] || {}
          return [] unless dark[:used]

          lines = [ "## Dark Mode", "" ]
          lines << "Dark mode is active. Use `dark:` prefix for all color-dependent classes."
          lines << "- Common patterns: #{safe_keys(dark[:patterns], 8).join(', ')}" if dark[:patterns]&.any?
          lines << ""
          lines
        end

        def render_icons(patterns)
          icons = patterns[:icons]
          return [] unless icons.is_a?(Hash) && (icons[:library] || icons[:inline_svg_count])

          lines = [ "## Icons", "" ]
          lines << "- Library: #{icons[:library]}" if icons[:library]
          lines << "- Inline SVGs: #{icons[:inline_svg_count]}" if icons[:inline_svg_count]
          lines << "- Sizes: #{safe_keys(icons[:sizes], 3).join(', ')}" if icons[:sizes]&.any?
          lines << ""
          lines
        end

        def render_animations(patterns)
          anims = patterns[:animations]
          return [] unless anims.is_a?(Hash) && anims.any?

          lines = [ "## Animations & Transitions", "" ]
          lines << "- Transitions: #{safe_keys(anims[:transitions]).join(', ')}" if anims[:transitions]&.any?
          lines << "- Durations: #{safe_keys(anims[:durations]).join(', ')}" if anims[:durations]&.any?
          lines << "- Animations: #{safe_keys(anims[:animates]).join(', ')}" if anims[:animates]&.any?
          lines << "- Easing: #{safe_keys(anims[:easing]).join(', ')}" if anims[:easing]&.any?
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

        def categorize_component(component)
          file = (component[:file] || "").downcase
          name = (component[:name] || "").downcase

          # Categorize by directory structure first
          if file.include?("/ruby_ui/") || file.include?("/ui/")
            # Sub-categorize UI primitives
            return "UI / Form" if name.match?(/input|select|textarea|form|radio|checkbox/)
            return "UI / Feedback" if name.match?(/alert|toast|dialog|modal/)
            return "UI / Navigation" if name.match?(/breadcrumb|pagination|nav|link|menu|tabs/)
            return "UI / Layout" if name.match?(/card|separator|heading|text|badge/)
            return "UI / Media" if name.match?(/avatar|carousel|image/)
            return "UI / Overlay" if name.match?(/dialog|popover|tooltip|dropdown/)
            return "UI / Primitives"
          end

          return "Domain / Articles" if name.match?(/article/)
          return "Domain / Comments" if name.match?(/comment/)
          return "Domain / Posts" if name.match?(/post/)
          return "Domain / Users" if name.match?(/user|profile/)
          return "Domain / Likes" if name.match?(/like/)
          return "Domain / Tags" if name.match?(/tag/)
          return "Layout" if name.match?(/layout|flash|pagination|sidebar|login/)

          "Other"
        end

        # Safe key extraction — handles both Hash and Array
        def safe_keys(value, limit = nil)
          names = value.is_a?(Hash) ? value.keys : Array(value)
          limit ? names.first(limit) : names
        end
      end
    end
  end
end
