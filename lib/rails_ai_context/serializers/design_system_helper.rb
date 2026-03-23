# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Shared module that renders design system context as actionable guidance for AI.
    # Replaces the old render_ui_patterns flat component listing with:
    # - Color palette with semantic roles
    # - Component patterns with usage guidance
    # - Canonical template examples (real HTML/ERB snippets)
    # - Typography, layout, spacing conventions
    # - Interactive states & responsive patterns
    # - Explicit design rules
    #
    # Include in any serializer that has a `context` reader.
    module DesignSystemHelper
      def render_design_system(ctx = context, max_lines: 40) # rubocop:disable Metrics
        lines = []
        vt = ctx[:view_templates]
        dt = ctx[:design_tokens]

        return lines unless vt.is_a?(Hash) && !vt[:error]
        patterns = vt[:ui_patterns] || {}
        components = patterns[:components] || []
        return lines if components.empty?

        lines << "## Design System"
        lines << ""

        lines.concat(render_color_palette(patterns, dt))
        lines.concat(render_component_guide(components))
        lines.concat(render_typography_summary(patterns))
        lines.concat(render_spacing_summary(patterns))
        lines.concat(render_interaction_summary(patterns))
        lines.concat(render_dark_mode_summary(patterns))
        lines.concat(render_decision_guide(patterns))
        lines.concat(render_design_rules(patterns))

        lines.first(max_lines)
      end

      def render_design_system_full(ctx = context) # rubocop:disable Metrics
        lines = render_design_system(ctx, max_lines: 200)

        vt = ctx[:view_templates]
        return lines unless vt.is_a?(Hash) && !vt[:error]

        patterns = vt[:ui_patterns] || {}
        examples = patterns[:canonical_examples] || []

        if examples.any?
          lines << ""
          lines << "## Page Examples — Copy These Patterns"
          lines << ""

          examples.each do |ex|
            label = { form_page: "Form Page", list_page: "List/Grid Page", show_page: "Detail Page",
                      dashboard: "Dashboard" }[ex[:type]] || ex[:type].to_s.tr("_", " ").capitalize
            lines << "### #{label} (#{ex[:template]})"
            lines << ""
            lines << "```erb"
            lines.concat(ex[:snippet].lines.map(&:chomp))
            lines << "```"
            lines << ""
          end
        end

        # Responsive patterns
        responsive = patterns[:responsive] || {}
        if responsive.any?
          lines << "## Responsive Breakpoints"
          lines << ""
          responsive.each do |bp, classes|
            lines << "- **#{bp}:** #{classes.keys.first(4).join(', ')}"
          end
          lines << ""
        end

        # Icons
        icons = patterns[:icons]
        if icons.is_a?(Hash) && icons[:library]
          lines << "## Icons"
          lines << "- Library: #{icons[:library]}"
          lines << "- Sizes: #{icons[:sizes]&.keys&.first(3)&.join(', ')}" if icons[:sizes]&.any?
          lines << ""
        end

        # Shared partials with descriptions
        shared = patterns[:shared_partials] || []
        if shared.any?
          lines << "## Shared Partials — Reuse Before Creating New Markup"
          lines << ""
          shared.each do |p|
            lines << "- `#{p[:name]}` — #{p[:description]}"
          end
          lines << ""
        end

        lines
      end

      private

      def render_color_palette(patterns, design_tokens)
        scheme = patterns[:color_scheme] || {}
        return [] if scheme.empty? && (design_tokens.nil? || design_tokens[:error])

        lines = [ "### Colors" ]

        # Semantic roles
        lines << "- **Primary:** #{scheme[:primary]} — use for CTAs, active states, links" if scheme[:primary]
        lines << "- **Danger:** #{scheme[:danger]} — destructive actions only (delete, remove)" if scheme[:danger]
        lines << "- **Success:** #{scheme[:success]} — confirmations, positive feedback" if scheme[:success]
        lines << "- **Warning:** #{scheme[:warning]} — warnings, important notices" if scheme[:warning]

        # Text and background palettes
        lines << "- **Text:** #{scheme[:text]}" if scheme[:text]
        lines << "- **Backgrounds:** #{scheme[:background_palette]&.first(5)&.join(', ')}" if scheme[:background_palette]&.any?

        # Merge design tokens if available
        if design_tokens.is_a?(Hash) && !design_tokens[:error]
          categorized = design_tokens[:categorized] || {}
          colors = categorized[:colors] || {}
          if colors.any? && !scheme[:primary]
            colors.first(5).each do |name, value|
              lines << "- #{name}: `#{value}`"
            end
          end
        end

        lines << ""
        lines
      end

      def render_component_guide(components)
        lines = [ "### Components — Copy These Patterns" ]

        by_type = components.group_by { |c| c[:type] }

        by_type.each do |_type, comps|
          comps.each do |c|
            lines << "- **#{c[:label]}:** `#{c[:classes]}`"
          end
        end

        lines << ""
        lines
      end

      def render_typography_summary(patterns)
        typo = patterns[:typography] || {}
        return [] if typo.empty?

        lines = [ "### Typography" ]

        if typo[:heading_styles]&.any?
          typo[:heading_styles].each do |tag, classes|
            lines << "- **#{tag}:** `#{classes}`"
          end
        end

        if typo[:sizes]&.any?
          lines << "- Sizes: #{typo[:sizes].first(5).map(&:first).join(', ')}"
        end

        if typo[:weights]&.any?
          lines << "- Weights: #{typo[:weights].first(3).map(&:first).join(', ')}"
        end

        lines << ""
        lines
      end

      def render_spacing_summary(patterns)
        layout = patterns[:layout] || {}
        fl = patterns[:form_layout] || {}
        return [] if layout.empty? && fl.empty?

        lines = [ "### Layout & Spacing" ]

        lines << "- Container: #{layout[:containers].keys.first(2).join(', ')}" if layout[:containers]&.any?
        lines << "- Grid: #{layout[:grid].keys.first(3).join(', ')}" if layout[:grid]&.any?
        lines << "- Spacing: #{layout[:spacing_scale].keys.first(6).join(', ')}" if layout[:spacing_scale]&.any?
        lines << "- Form spacing: #{fl[:spacing]}" if fl[:spacing]

        lines << ""
        lines
      end

      def render_interaction_summary(patterns)
        states = patterns[:interactive_states] || {}
        return [] if states.empty?

        lines = [ "### Interactive States" ]

        %w[hover focus active disabled].each do |state|
          next unless states[state]&.any?
          top = states[state].keys.first(3).join(", ")
          lines << "- **#{state}:** #{top}"
        end

        lines << ""
        lines
      end

      def render_dark_mode_summary(patterns)
        dark = patterns[:dark_mode] || {}
        return [] unless dark[:used]

        lines = [ "### Dark Mode" ]
        lines << "- Active — use `dark:` prefix for all color-dependent classes"
        lines << "- Common: #{dark[:patterns].keys.first(5).join(', ')}" if dark[:patterns]&.any?
        lines << ""
        lines
      end

      # DS8: Decision guide — when to use what
      def render_decision_guide(patterns)
        components = patterns[:components] || []
        return [] if components.size < 3

        lines = [ "### When to Use What" ]

        # Button decisions
        has_primary = components.any? { |c| c[:label]&.include?("primary") }
        has_danger = components.any? { |c| c[:label]&.include?("danger") }
        has_secondary = components.any? { |c| c[:label]&.include?("secondary") }
        if has_primary || has_danger
          lines << "- **Primary action** (Save, Submit, Continue) → Primary button"
          lines << "- **Secondary action** (Cancel, Back, Skip) → Secondary button" if has_secondary
          lines << "- **Destructive action** (Delete, Remove) → Danger button" if has_danger
        end

        # Turbo confirm
        lines << "- **Confirmation needed** → `data: { turbo_confirm: \"Are you sure?\" }` on `button_to`"

        # Shared partials usage
        shared = patterns[:shared_partials] || []
        shared.each do |p|
          case p[:name]
          when /flash|notification/ then lines << "- **Show feedback** → `render \"shared/#{p[:name].sub(/\A_/, '').sub(/\..*/, '')}\"` "
          when /status|badge/ then lines << "- **Show status** → `render \"shared/#{p[:name].sub(/\A_/, '').sub(/\..*/, '')}\"` "
          when /modal|dialog/ then lines << "- **Need overlay/dialog** → `render \"shared/#{p[:name].sub(/\A_/, '').sub(/\..*/, '')}\"` "
          when /loading|spinner/ then lines << "- **Show loading** → `render \"shared/#{p[:name].sub(/\A_/, '').sub(/\..*/, '')}\"` "
          end
        end

        lines << ""
        lines
      end

      def render_design_rules(patterns)
        lines = [ "### Design Rules" ]

        responsive = patterns[:responsive] || {}
        lines << "- Always add responsive breakpoints (mobile-first with md: and lg: variants)" if responsive.any?

        states = patterns[:interactive_states] || {}
        lines << "- All interactive elements MUST have hover: and focus: states" if states.key?("hover") || states.key?("focus")

        layout = patterns[:layout] || {}
        if layout[:spacing_scale]&.any?
          top = layout[:spacing_scale].keys.first(4).join(", ")
          lines << "- Use existing spacing scale: #{top}"
        end

        radius = patterns[:radius] || {}
        if radius.any?
          lines << "- Border radius: #{radius.map { |type, r| "#{r} (#{type})" }.join(', ')}"
        end

        dark = patterns[:dark_mode] || {}
        lines << "- Mirror all bg/text colors with dark: variants" if dark[:used]

        lines << "- Reuse shared partials from app/views/shared/ before creating new markup"
        lines << ""
        lines
      end
    end
  end
end
