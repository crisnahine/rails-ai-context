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
          ui_patterns: extract_ui_patterns(all_content)
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
          templates[relative] = {
            lines: content.lines.count,
            partials: extract_partial_refs(content),
            stimulus: extract_stimulus_refs(content)
          }
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
        content = ""
        Dir.glob(File.join(views_dir, "**", "*.{erb,haml,slim}")).each do |path|
          next if File.directory?(path)
          content += (File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue "")
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

        # Extract element-aware patterns
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

        # Design tokens
        color_scheme = extract_color_scheme(all_content, class_groups)
        radius_convention = extract_radius_convention(components)
        form_layout = extract_form_layout(all_content)

        {
          color_scheme: color_scheme,
          radius: radius_convention,
          form_layout: form_layout,
          components: components
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
          classified[role] = { classes: c, count: count } if !classified[role] || count > classified[role][:count]
        end

        classified.each do |role, data|
          label = role == "default" ? "Button" : "Button (#{role})"
          components << { type: :button, label: label, classes: data[:classes] }
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

      def extract_color_scheme(_content, groups)
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
        content.scan(/(?:@?\w+)\.(\w+)/).each do |m|
          field = m[0]
          next if field.length < 3 || field.length > 40
          next if field.match?(/\A[0-9a-f]+\z/)
          next if field.match?(/\A[A-Z]/) # skip constant/class access
          next if EXCLUDED_METHODS.include?(field)
          next if field.start_with?("to_", "html_")
          next if field.end_with?("?", "!")
          fields << field
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
        refs.uniq
      end

      def extract_stimulus_refs(content)
        refs = []
        # data-controller="name" or data-controller="name1 name2"
        content.scan(/data-controller=["']([^"']+)["']/).each do |m|
          m[0].split.each { |c| refs << c }
        end
        # data: { controller: "name" }
        content.scan(/controller:\s*["']([^"']+)["']/).each do |m|
          m[0].split.each { |c| refs << c }
        end
        refs.uniq
      end
    end
  end
end
