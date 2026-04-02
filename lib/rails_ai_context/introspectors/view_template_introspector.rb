# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Reads actual view template contents and extracts metadata:
    # partial references, Stimulus controller usage, line counts.
    # Separate from ViewIntrospector which focuses on structural discovery.
    class ViewTemplateIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        views_dir = File.join(app.root.to_s, "app", "views")
        return { templates: {}, partials: {}, ui_patterns: {} } unless Dir.exist?(views_dir)

        all_content = collect_all_view_content(views_dir)
        {
          templates: scan_templates(views_dir),
          partials: scan_partials(views_dir),
          ui_patterns: extract_ui_patterns(all_content).merge(
            canonical_examples: extract_canonical_examples(views_dir),
            shared_partials: discover_shared_partials(views_dir)
          )
        }
      rescue => e
        { error: e.message }
      end

      private

      def scan_templates(views_dir)
        templates = {}
        Dir.glob(File.join(views_dir, "**", "*")).each do |path|
          next if File.directory?(path)
          next if File.basename(path).start_with?("_") # skip partials
          next if path.include?("/layouts/")

          relative = path.sub("#{views_dir}/", "")
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next

          if phlex_view?(path, content)
            templates[relative] = {
              lines: content.lines.count,
              partials: extract_partial_refs(content),
              stimulus: extract_stimulus_refs(content),
              components: extract_phlex_component_renders(content),
              helpers: extract_phlex_helper_calls(content),
              phlex: true
            }
          else
            templates[relative] = {
              lines: content.lines.count,
              partials: extract_partial_refs(content),
              stimulus: extract_stimulus_refs(content)
            }
          end
        end
        templates
      end

      def scan_partials(views_dir)
        partials = {}
        Dir.glob(File.join(views_dir, "**", "_*")).each do |path|
          next if File.directory?(path)
          relative = path.sub("#{views_dir}/", "")
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
          partials[relative] = {
            lines: content.lines.count,
            fields: extract_model_fields(content),
            helpers: extract_helper_calls(content)
          }
        end
        partials
      end

      def collect_all_view_content(views_dir)
        max_total = RailsAiContext.configuration.max_view_total_size
        max_single = RailsAiContext.configuration.max_view_file_size
        content = +""
        Dir.glob(File.join(views_dir, "**", "*.{erb,haml,slim,rb}")).each do |path|
          next if File.directory?(path)
          next if File.size(path) > max_single
          break if content.bytesize >= max_total
          content << (File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue "")
        end
        content
      end

      def extract_ui_patterns(all_content) # rubocop:disable Metrics
        # Collect all class attributes with context
        class_groups = Hash.new(0)
        extract_classes_from_content(all_content, class_groups)

        return {} if class_groups.size < 3

        components = []
        used = Set.new

        # DS13-15: Framework-aware component extraction
        extract_bootstrap_components(all_content, components, used) if all_content.match?(/btn-|form-control|card-body/)

        # Extract element-aware patterns (Tailwind + generic)
        extract_buttons(all_content, class_groups, components, used)
        extract_cards(class_groups, components, used)
        extract_inputs(all_content, class_groups, components, used)
        extract_selects(all_content, components)
        extract_textareas(all_content, components)
        extract_labels(class_groups, components, used)
        extract_badges(class_groups, components, used)
        extract_links(class_groups, components, used)
        extract_headings(all_content, components)
        extract_flashes(all_content, components)
        extract_alerts(class_groups, components, used)
        extract_modals(all_content, class_groups, components, used)
        extract_list_items(class_groups, components, used)

        # Design tokens
        color_scheme = extract_color_scheme(all_content, class_groups)
        radius_convention = extract_radius_convention(components)
        form_layout = extract_form_layout(all_content)

        {
          color_scheme: color_scheme,
          radius: radius_convention,
          form_layout: form_layout,
          components: components,
          typography: extract_typography(all_content),
          layout: extract_layout_patterns(all_content),
          responsive: extract_responsive_patterns(all_content),
          interactive_states: extract_interactive_states(all_content),
          dark_mode: extract_dark_mode_patterns(all_content),
          icons: extract_icon_system(all_content),
          animations: extract_animations(all_content),
          form_builders: extract_form_builders(all_content),
          semantic_html: extract_semantic_html(all_content),
          accessibility_patterns: extract_accessibility_patterns(all_content)
        }
      end

      def extract_classes_from_content(content, groups)
        content.scan(/class="([^"]+)"/).each do |m|
          classes = m[0].gsub(/<%=.*?%>/, "").strip
          next if classes.length < 5
          groups[classes] += 1
        end
        content.scan(/class='([^']+)'/).each do |m|
          classes = m[0].gsub(/<%=.*?%>/, "").strip
          next if classes.length < 5
          groups[classes] += 1
        end
      end

      def extract_buttons(content, groups, components, used)
        candidates = {}
        # Scan for button/submit/link_to elements with classes
        content.scan(/<(?:button|input[^>]*type=["']submit)[^>]*class=["']([^"']+)["']/i).each do |m|
          c = m[0].gsub(/<%=.*?%>/, "").strip
          candidates[c] = (candidates[c] || 0) + 1
        end
        # Also check class groups for button-like patterns
        groups.each do |c, count|
          next if count < 2
          candidates[c] = count if c.match?(/bg-\w+-\d+.*text-white.*hover:|btn-|button/)
        end

        # Classify by role
        classified = {}
        candidates.each do |c, count|
          role = if c.match?(/bg-red-|btn-danger|danger/)
            "danger"
          elsif c.match?(/bg-gray-\d+\s.*text-gray|btn-secondary|secondary/) && !c.match?(/cursor-not-allowed|disabled|opacity-/)
            "secondary"
          elsif c.match?(/border-\d?\s|border-\w+-\d+/) && !c.match?(/bg-\w+-[5-9]00/)
            "outline"
          elsif c.match?(/bg-\w+-[5-9]00.*text-white|btn-primary|primary/)
            "primary"
          end
          next unless role # skip unclassified buttons
          classified[role] ||= { classes: c, count: count, variants: [] }
          classified[role][:variants] << { classes: c, count: count }
          if count > classified[role][:count]
            classified[role][:classes] = c
            classified[role][:count] = count
          end
        end

        classified.each do |role, data|
          label = role == "default" ? "Button" : "Button (#{role})"
          entry = { type: :button, label: label, classes: data[:classes] }
          entry[:variants] = data[:variants] if data[:variants]&.size&.> 1
          components << entry
          used << data[:classes]
        end
      end

      def extract_cards(groups, components, used)
        candidates = groups.select do |c, count|
          count >= 2 && c.match?(/(?:bg-white|card).*?(?:shadow|rounded|border)/) && c.match?(/p-\d/)
        end
        return if candidates.empty?

        # Separate empty state cards from regular cards
        regular = candidates.reject { |c, _| c.match?(/text-center.*?p-(?:8|10|12)|p-(?:8|10|12).*?text-center/) }
        empty_state = candidates.select { |c, _| c.match?(/text-center.*?p-(?:8|10|12)|p-(?:8|10|12).*?text-center/) }

        if regular.any?
          best = regular.max_by { |_, count| count }
          components << { type: :card, label: "Card", classes: best[0] }
          used << best[0]
        end
        if empty_state.any?
          best = empty_state.max_by { |_, count| count }
          components << { type: :card, label: "Card (empty state)", classes: best[0] }
          used << best[0]
        end
      end

      def extract_inputs(content, groups, components, used)
        candidates = {}
        # Only match actual <input> elements, not alert/flash divs
        content.scan(/<input[^>]*type=["'](?:text|email|password|number|date|url|tel|search)[^>]*class=["']([^"']+)["']/i).each do |m|
          c = m[0].gsub(/<%=.*?%>/, "").strip
          candidates[c] = (candidates[c] || 0) + 1
        end
        # Also check class groups for input-like patterns (must have focus: styles)
        groups.each do |c, count|
          next if count < 2
          next if c.match?(/bg-\w+-50/) # skip alert-colored elements
          candidates[c] = count if c.match?(/(?:border.*?rounded|form-control).*?focus:/)
        end
        return if candidates.empty?

        best = candidates.max_by { |_, count| count }
        components << { type: :input, label: "Input", classes: best[0] }
        used << best[0]
      end

      def extract_selects(content, components)
        classes = content.scan(/<select[^>]*class=["']([^"']+)["']/i).map { |m| m[0].gsub(/<%=.*?%>/, "").strip }
        return if classes.empty?
        best = classes.tally.max_by { |_, c| c }
        components << { type: :select, label: "Select", classes: best[0] }
      end

      def extract_textareas(content, components)
        classes = content.scan(/<textarea[^>]*class=["']([^"']+)["']/i).map { |m| m[0].gsub(/<%=.*?%>/, "").strip }
        return if classes.empty?
        best = classes.tally.max_by { |_, c| c }
        components << { type: :textarea, label: "Textarea", classes: best[0] }
      end

      def extract_labels(groups, components, used)
        candidates = groups.select do |c, count|
          count >= 2 && c.match?(/(?:label|block.*?text-sm.*?font-|font-semibold.*?mb-|font-medium.*?mb-)/) && !used.include?(c)
        end
        return if candidates.empty?
        best = candidates.max_by { |_, count| count }
        components << { type: :label, label: "Label", classes: best[0] }
        used << best[0]
      end

      def extract_badges(groups, components, used)
        # Real badges: must have text sizing + padding + rounded-full
        candidates = groups.select do |c, count|
          count >= 2 && c.match?(/text-(?:xs|sm)/) && c.match?(/px-\d/) && c.match?(/rounded-full/) && !used.include?(c)
        end
        # Exclude progress bars (only h-* + rounded-full, no text/padding)
        candidates.reject! { |c, _| c.match?(/\Ah-\d/) || c.match?(/\A(?:mt-|mb-)?\d*\.?\d*\s*h-\d/) }
        return if candidates.empty?
        best = candidates.max_by { |_, count| count }
        components << { type: :badge, label: "Badge", classes: best[0] }
        used << best[0]
      end

      def extract_links(groups, components, used)
        candidates = groups.select do |c, count|
          count >= 2 && c.match?(/hover:text-|hover:underline/) && !c.match?(/bg-\w+-[5-9]00.*text-white/) && !used.include?(c)
        end
        return if candidates.empty?
        sorted = candidates.sort_by { |_, count| -count }
        best = sorted.first
        components << { type: :link, label: "Link", classes: best[0] }
        used << best[0]
        if sorted.size > 1
          components << { type: :link, label: "Link (secondary)", classes: sorted[1][0] }
        end
      end

      def extract_headings(content, components)
        %w[h1 h2 h3].each do |tag|
          classes = content.scan(/<#{tag}[^>]*class=["']([^"']+)["']/i).map { |m| m[0].gsub(/<%=.*?%>/, "").strip }
          next if classes.empty?
          best = classes.tally.max_by { |_, c| c }
          label = { "h1" => "Heading (page)", "h2" => "Heading (section)", "h3" => "Heading (sub)" }[tag]
          components << { type: :heading, label: label, classes: best[0] }
        end
      end

      def extract_flashes(content, components)
        # Look for flash/notice/alert patterns
        content.scan(/(?:notice|success|flash).*?class=["']([^"']+)["']/i).each do |m|
          c = m[0].gsub(/<%=.*?%>/, "").strip
          next if c.length < 10
          components << { type: :flash, label: "Flash (success)", classes: c }
          break
        end
        content.scan(/(?:alert|error|danger).*?class=["']([^"']+)["']/i).each do |m|
          c = m[0].gsub(/<%=.*?%>/, "").strip
          next if c.length < 10
          components << { type: :flash, label: "Flash (error)", classes: c }
          break
        end
      end

      def extract_alerts(groups, components, used)
        candidates = groups.select do |c, count|
          c.match?(/bg-\w+-50.*border.*border-\w+-200|alert/) && !used.include?(c)
        end
        return if candidates.empty?
        best = candidates.max_by { |_, count| count }
        components << { type: :alert, label: "Alert", classes: best[0] }
      end

      # DS13-15: Bootstrap component extraction
      def extract_bootstrap_components(content, components, used)
        bootstrap_patterns = {
          "btn-primary" => { type: :button, label: "Button (primary)" },
          "btn-secondary" => { type: :button, label: "Button (secondary)" },
          "btn-danger" => { type: :button, label: "Button (danger)" },
          "btn-outline-primary" => { type: :button, label: "Button (outline)" },
          "card" => { type: :card, label: "Card" },
          "modal" => { type: :modal_card, label: "Modal" },
          "form-control" => { type: :input, label: "Input" },
          "form-select" => { type: :select, label: "Select" },
          "badge" => { type: :badge, label: "Badge" },
          "alert" => { type: :alert, label: "Alert" },
          "nav" => { type: :nav, label: "Navigation" }
        }

        bootstrap_patterns.each do |pattern, meta|
          matches = content.scan(/class=["'][^"']*\b#{pattern}\b[^"']*["']/).map do |m|
            m.gsub(/class=["']|["']/, "").strip
          end
          next if matches.empty?

          best = matches.tally.max_by { |_, c| c }
          unless used.include?(best[0])
            components << meta.merge(classes: best[0])
            used << best[0]
          end
        end
      end

      # DS1: Modal/overlay patterns
      def extract_modals(content, groups, components, used)
        # Detect overlay pattern (fixed inset-0 bg-black/50 or similar)
        overlay = groups.select { |c, _| c.match?(/fixed.*inset-0|fixed.*z-\d+.*bg-/) && !used.include?(c) }
        if overlay.any?
          best = overlay.max_by { |_, count| count }
          components << { type: :modal_overlay, label: "Modal overlay", classes: best[0] }
          used << best[0]
        end

        # Detect modal card (usually the child of overlay)
        modal_card = groups.select do |c, _|
          c.match?(/bg-white.*rounded.*shadow.*max-w-|modal/) && c.match?(/p-\d/) && !used.include?(c)
        end
        if modal_card.any?
          best = modal_card.max_by { |_, count| count }
          components << { type: :modal_card, label: "Modal card", classes: best[0] }
          used << best[0]
        end
      end

      # DS5: List item / repeating card pattern
      def extract_list_items(groups, components, used)
        candidates = groups.select do |c, count|
          count >= 3 && # appears 3+ times (repeating pattern)
            c.match?(/(?:flex|grid).*(?:items-|justify-|gap-)/) &&
            c.match?(/(?:bg-white|border|shadow|rounded)/) &&
            !used.include?(c)
        end
        return if candidates.empty?
        best = candidates.max_by { |_, count| count }
        components << { type: :list_item, label: "List item", classes: best[0] }
        used << best[0]
      end

      def extract_color_scheme(content, groups)
        # Find primary color from button backgrounds
        primary_colors = Hash.new(0)
        groups.each do |c, count|
          next unless c.match?(/bg-(\w+)-[5-9]00.*text-white/)
          color = c.match(/bg-(\w+)-[5-9]00/)[1]
          primary_colors[color] += count
        end
        primary = primary_colors.max_by { |_, c| c }&.first

        # Find text colors
        text_colors = []
        %w[gray-900 gray-700 gray-500].each do |tc|
          text_colors << tc if groups.any? { |c, _| c.include?("text-#{tc}") }
        end

        scheme = {}
        scheme[:primary] = primary if primary
        scheme[:text] = text_colors.join("/") if text_colors.any?

        # Full palette: background colors used
        bg_colors = Hash.new(0)
        content.scan(/bg-(\w+)-(\d+)/).each { |color, shade| bg_colors["#{color}-#{shade}"] += 1 }
        scheme[:background_palette] = bg_colors.sort_by { |_, c| -c }.first(10).map(&:first) if bg_colors.any?

        # Text color palette
        text_palette = Hash.new(0)
        content.scan(/text-(\w+)-(\d+)/).each { |color, shade| text_palette["#{color}-#{shade}"] += 1 }
        scheme[:text_palette] = text_palette.sort_by { |_, c| -c }.first(8).map(&:first) if text_palette.any?

        # Border color palette
        border_colors = Hash.new(0)
        content.scan(/border-(\w+)-(\d+)/).each { |color, shade| border_colors["#{color}-#{shade}"] += 1 }
        scheme[:border_palette] = border_colors.sort_by { |_, c| -c }.first(5).map(&:first) if border_colors.any?

        # Semantic roles inferred from usage
        scheme[:danger] = "red" if bg_colors.any? { |k, _| k.start_with?("red-") }
        scheme[:success] = "green" if bg_colors.any? { |k, _| k.start_with?("green-") }
        scheme[:warning] = "yellow" if bg_colors.any? { |k, _| k.start_with?("yellow-") || k.start_with?("amber-") }

        scheme
      end

      def extract_radius_convention(components)
        radii = {}
        components.each do |comp|
          if (match = comp[:classes].match(/rounded-(\w+)/))
            radii[comp[:type]] ||= match[0]
          end
        end
        radii
      end

      def extract_form_layout(content)
        layout = {}
        # Spacing between form groups
        if (match = content.match(/space-y-(\d+)/))
          layout[:spacing] = "space-y-#{match[1]}"
        end
        # Grid patterns in forms
        if (match = content.match(/grid\s+grid-cols-(\d+)/))
          layout[:grid] = "grid grid-cols-#{match[1]}"
        end
        layout
      end

      def extract_responsive_patterns(content)
        breakpoints = {}
        %w[sm md lg xl 2xl].each do |bp|
          matches = content.scan(/#{bp}:[\w-]+/).map { |m| m.sub("#{bp}:", "") }
          next if matches.empty?
          breakpoints[bp] = matches.tally.sort_by { |_, c| -c }.first(5).to_h
        end
        breakpoints
      end

      def extract_interactive_states(content)
        states = {}
        %w[hover focus active disabled group-hover focus-within focus-visible].each do |state|
          matches = content.scan(/#{state}:[\w-]+/)
          next if matches.empty?
          states[state] = matches.tally.sort_by { |_, c| -c }.first(5).to_h
        end
        states
      end

      def extract_dark_mode_patterns(content)
        dark_classes = content.scan(/dark:[\w-]+/)
        return {} if dark_classes.empty?
        { used: true, patterns: dark_classes.tally.sort_by { |_, c| -c }.first(10).to_h }
      end

      def extract_layout_patterns(content)
        layout = {}

        containers = content.scan(/(?:max-w-\w+|container)\b/).tally
        layout[:containers] = containers.sort_by { |_, c| -c }.first(3).to_h unless containers.empty?

        flex = content.scan(/(?:flex-(?:row|col|wrap)|items-\w+|justify-\w+)\b/).tally
        layout[:flex] = flex.sort_by { |_, c| -c }.first(5).to_h unless flex.empty?

        grids = content.scan(/grid-cols-\d+/).tally
        layout[:grid] = grids.sort_by { |_, c| -c }.first(3).to_h unless grids.empty?

        spacing = content.scan(/(?:space-[xy]-|gap-|p-|px-|py-|m-|mx-|my-|mt-|mb-)\d+/).tally
        layout[:spacing_scale] = spacing.sort_by { |_, c| -c }.first(8).to_h unless spacing.empty?

        layout
      end

      def extract_typography(content)
        typo = {}

        sizes = content.scan(/text-(?:xs|sm|base|lg|xl|2xl|3xl|4xl|5xl|6xl)/).tally
        typo[:sizes] = sizes.sort_by { |_, c| -c }.to_h unless sizes.empty?

        weights = content.scan(/font-(?:thin|extralight|light|normal|medium|semibold|bold|extrabold|black)/).tally
        typo[:weights] = weights.sort_by { |_, c| -c }.to_h unless weights.empty?

        headings = {}
        %w[h1 h2 h3 h4].each do |tag|
          classes = content.scan(/<#{tag}[^>]*class=["']([^"']+)["']/i).map { |m| m[0].gsub(/<%=.*?%>/, "").strip }
          next if classes.empty?
          headings[tag] = classes.tally.max_by { |_, c| c }[0]
        end
        typo[:heading_styles] = headings unless headings.empty?

        leading = content.scan(/leading-\w+/).tally
        typo[:line_height] = leading.sort_by { |_, c| -c }.first(3).to_h unless leading.empty?

        typo
      end

      def extract_icon_system(content)
        icons = {}

        icons[:library] = "heroicons" if content.match?(/heroicon|hero_icon/)
        icons[:library] = "lucide" if content.match?(/lucide|data-lucide/)
        icons[:library] = "font-awesome" if content.match?(/fa-\w+|font-awesome/)
        icons[:library] = "bootstrap-icons" if content.match?(/bi-\w+/)

        svg_count = content.scan(/<svg\b/).size
        icons[:inline_svg_count] = svg_count if svg_count > 0

        icon_sizes = content.scan(/(?:w-\d+\s+h-\d+|size-\d+)/).tally
        icons[:sizes] = icon_sizes.sort_by { |_, c| -c }.first(3).to_h unless icon_sizes.empty?

        icons.empty? ? nil : icons
      end

      # DS19: Animation and transition patterns
      def extract_animations(content)
        animations = {}

        # Transition classes
        transitions = content.scan(/transition(?:-\w+)*/).tally
        animations[:transitions] = transitions.sort_by { |_, c| -c }.first(5).to_h unless transitions.empty?

        # Duration classes
        durations = content.scan(/duration-\d+/).tally
        animations[:durations] = durations.sort_by { |_, c| -c }.first(3).to_h unless durations.empty?

        # Animate classes
        animates = content.scan(/animate-\w+/).tally
        animations[:animates] = animates.sort_by { |_, c| -c }.first(5).to_h unless animates.empty?

        # Ease classes
        eases = content.scan(/ease-\w+/).tally
        animations[:easing] = eases.sort_by { |_, c| -c }.first(3).to_h unless eases.empty?

        animations.empty? ? nil : animations
      end

      def extract_form_builders(content)
        builders = {}
        builders[:form_with] = content.scan(/\bform_with\b/).size
        builders[:form_for] = content.scan(/\bform_for\b/).size
        builders[:simple_form_for] = content.scan(/\bsimple_form_for\b/).size
        builders[:formtastic] = content.scan(/\bsemantic_form_for\b/).size
        builders.reject { |_, v| v == 0 }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_form_builders failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def extract_semantic_html(content)
        tags = {}
        %w[nav main article section aside dialog details].each do |tag|
          count = content.scan(/<#{tag}[\s>]/i).size
          tags[tag.to_sym] = count if count > 0
        end
        tags
      rescue => e
        $stderr.puts "[rails-ai-context] extract_semantic_html failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def extract_accessibility_patterns(content)
        patterns = {}
        aria_count = content.scan(/aria-\w+/).size
        patterns[:aria_attributes] = aria_count if aria_count > 0
        role_count = content.scan(/role=["'][^"']+["']/).size
        patterns[:roles] = role_count if role_count > 0
        sr_only_count = content.scan(/\bsr-only\b/).size
        patterns[:sr_only] = sr_only_count if sr_only_count > 0
        patterns
      rescue => e
        $stderr.puts "[rails-ai-context] extract_accessibility_patterns failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      # Analyzes individual templates to find canonical examples of common page types.
      # Returns up to 5 representative ERB snippets that AI can copy.
      def extract_canonical_examples(views_dir) # rubocop:disable Metrics
        max_snippet = 80 # lines per example
        max_file = RailsAiContext.configuration.max_view_file_size
        examples = {}

        Dir.glob(File.join(views_dir, "**", "*.{erb,haml,slim}")).each do |path|
          next if File.directory?(path)
          next if File.basename(path).start_with?("_") # skip partials
          next if path.include?("/layouts/")
          next if File.size(path) > max_file

          relative = path.sub("#{views_dir}/", "")
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next

          page_type = classify_template(content)
          next unless page_type

          score = score_template(content)
          existing = examples[page_type]

          if !existing || score > existing[:score]
            snippet = content.lines.first(max_snippet).join
            # Strip large SVG blocks
            snippet = snippet.gsub(/<svg[^>]*>.*?<\/svg>/m, "<!-- svg icon -->")
            components_used = detect_components_in_template(content)

            examples[page_type] = {
              type: page_type,
              template: relative,
              snippet: snippet,
              components_used: components_used,
              score: score
            }
          end
        end

        examples.values.map { |e| e.except(:score) }.first(5)
      rescue => e
        $stderr.puts "[rails-ai-context] extract_canonical_examples failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def classify_template(content)
        has_form = content.match?(/form_with|form_for|<form\b/i)
        has_collection = content.match?(/\.each\s+do\b|render\s+collection:|render\s+@\w+/)
        has_grid = content.match?(/grid-cols-|grid\s+grid-/)
        has_show = content.match?(/\A(?:(?!\.each).)*@\w+\.\w+/m) && !has_collection

        if has_form && !has_collection
          :form_page
        elsif has_collection || has_grid
          :list_page
        elsif has_show
          :show_page
        end
      end

      def score_template(content)
        score = 0
        # Prefer templates with more design patterns
        score += content.scan(/class=["'][^"']+["']/).size.clamp(0, 20)
        # Responsive classes
        score += 5 if content.match?(/(?:sm|md|lg|xl):/)
        # Interactive states
        score += 3 if content.match?(/hover:|focus:/)
        # Component variety
        score += 2 if content.match?(/<button|btn/i)
        score += 2 if content.match?(/shadow.*rounded|card/i)
        score += 2 if content.match?(/<input|form_with|form_for/i)
        # Not too short, not too long (sweet spot: 30-100 lines)
        lines = content.lines.size
        score += 5 if lines.between?(30, 100)
        score -= 3 if lines < 10
        score
      end

      def detect_components_in_template(content)
        used = []
        used << :button if content.match?(/bg-\w+-[5-9]00.*text-white|btn-|<button/i)
        used << :card if content.match?(/shadow.*rounded|card/i)
        used << :input if content.match?(/<input|text_field|email_field|password_field/i)
        used << :form if content.match?(/form_with|form_for|<form/i)
        used << :link if content.match?(/link_to|<a\b/i)
        used << :badge if content.match?(/rounded-full.*text-(?:xs|sm)|badge/i)
        used << :grid if content.match?(/grid-cols-|grid\s+grid-/)
        used
      end

      # DS7: Shared partials with one-line descriptions
      def discover_shared_partials(views_dir)
        shared_dir = File.join(views_dir, "shared")
        return [] unless Dir.exist?(shared_dir)

        Dir.glob(File.join(shared_dir, "_*.{erb,haml,slim}")).sort.map do |path|
          name = File.basename(path)
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue ""
          description = infer_partial_description(name, content)
          { name: name, lines: content.lines.size, description: description }
        end
      rescue => e
        $stderr.puts "[rails-ai-context] discover_shared_partials failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def infer_partial_description(name, content)
        # Infer from content patterns
        return "Flash/notification messages" if name.include?("flash") || name.include?("notification")
        return "Navigation bar" if name.include?("nav") || name.include?("header")
        return "Footer" if name.include?("footer")
        return "Status badge/indicator" if name.include?("status") || name.include?("badge")
        return "Loading/spinner" if name.include?("loading") || name.include?("spinner") || content.include?("animate-spin")
        return "Modal dialog" if name.include?("modal") || name.include?("dialog")
        return "Form component" if name.include?("form") || content.match?(/form_with|form_for/)
        return "Upgrade prompt" if name.include?("upgrade") || name.include?("nudge")
        return "Share dialog" if name.include?("share")
        return "Error display" if name.include?("error")
        "Shared partial (#{content.lines.size} lines)"
      end

      # Detect whether a view file is a Phlex view (Ruby DSL, not ERB)
      def phlex_view?(path, content)
        return false unless path.end_with?(".rb")
        # Check for Phlex class patterns: inherits from a View/Base class and defines view_template
        content.match?(/class\s+\S+\s*<\s*\S+/) && content.match?(/def\s+view_template\b/)
      end

      # Extract component render calls from Phlex Ruby DSL
      # Matches: render ComponentName.new(...), render(ComponentName.new(...))
      # Also matches: render Components::Nested::Name.new(...)
      def extract_phlex_component_renders(content)
        components = Set.new
        content.scan(/render[\s(]+([A-Z]\w+(?:::\w+)*)\.new/).each do |match|
          components << match[0]
        end
        components.to_a.sort
      end

      # Extract helper method calls from Phlex views
      # Phlex views use include to pull in helpers, and call them directly
      PHLEX_HELPER_METHODS = %w[
        link_to image_tag content_for button_to form_with form_for
        content_tag tag number_to_currency number_to_human
        time_ago_in_words distance_of_time_in_words
        truncate pluralize raw sanitize dom_id
      ].freeze

      def extract_phlex_helper_calls(content)
        helpers = []
        PHLEX_HELPER_METHODS.each do |method|
          helpers << method if content.match?(/\b#{method}\b/)
        end
        helpers
      end

      EXCLUDED_METHODS = %w[
        each map select reject first last size count any? empty? present? blank?
        new build create find where order limit nil? join class html_safe
        to_s to_i to_f inspect strip chomp downcase upcase capitalize
        humanize pluralize singularize truncate gsub sub scan match split
        freeze dup clone length bytes chars reverse uniq compact flatten
        flat_map zip sort sort_by min max sum group_by
        persisted? new_record? valid? errors reload save destroy update
        delete respond_to? is_a? kind_of? send try
        abs round ceil floor
        strftime iso8601 beginning_of_day end_of_day ago from_now
      ].freeze

      def extract_model_fields(content)
        fields = []
        # Only extract from @variable.field patterns (instance variable receivers)
        content.scan(/@\w+\.(\w+)/).each do |m|
          field = m[0]
          next if field.length < 3 || field.length > 40
          next if field.match?(/\A[0-9a-f]+\z/)
          next if field.match?(/\A[A-Z]/)
          next if EXCLUDED_METHODS.include?(field)
          next if field.start_with?("to_", "html_")
          next if field.end_with?("?", "!")
          fields << field
        end
        # Also extract from form helper symbols: f.text_field :name, f.select :status
        content.scan(/f\.\w+(?:_field|_area|_select)?\s+:(\w+)/).each do |m|
          fields << m[0] if m[0].length >= 2
        end
        fields.uniq.first(15)
      end

      def extract_helper_calls(content)
        helpers = []
        # Custom helper methods (render_*, format_*, *_path, *_url)
        content.scan(/\b(render_\w+|format_\w+)\b/).each { |m| helpers << m[0] }
        helpers.uniq
      end

      def extract_partial_refs(content)
        refs = []
        # render "partial_name" or render partial: "name"
        content.scan(/render\s+(?:partial:\s*)?["']([^"']+)["']/).each { |m| refs << m[0] }
        # render @collection
        content.scan(/render\s+@(\w+)/).each { |m| refs << m[0] }
        # Phlex: render ComponentName.new(...) or render(ComponentName.new(...))
        content.scan(/render[\s(]+([A-Z]\w+(?:::\w+)*)\.new/).each { |m| refs << m[0] }
        refs.uniq
      end

      def extract_stimulus_refs(content)
        refs = []
        # data-controller="name" or data-controller="name1 name2" (ERB/HTML)
        content.scan(/data-controller=["']([^"']+)["']/).each do |m|
          m[0].split.each { |c| refs << c }
        end
        # data: { controller: "name" } (ERB helpers / Phlex hash syntax)
        content.scan(/controller:\s*["']([^"']+)["']/).each do |m|
          m[0].split.each { |c| refs << c }
        end
        # Phlex keyword: data_controller: "name" (Phlex HTML attributes)
        content.scan(/data_controller:\s*["']([^"']+)["']/).each do |m|
          m[0].split.each { |c| refs << c }
        end
        refs.uniq
      end
    end
  end
end
