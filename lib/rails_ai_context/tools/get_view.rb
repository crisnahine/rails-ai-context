# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetView < BaseTool
      tool_name "rails_get_view"
      description "Get view templates, partials, and their Stimulus/partial references. " \
        "Use when: editing ERB views, checking which partials a page renders, or finding Stimulus controller usage. " \
        "Filter with controller:\"posts\" for all views, or path:\"posts/index.html.erb\" for one file's content."

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Filter views by controller name (e.g. 'posts', 'comments'). Lists all templates for that controller."
          },
          path: {
            type: "string",
            description: "Specific view path relative to app/views (e.g. 'posts/index.html.erb'). Returns full content."
          },
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: file list with line counts. standard: file list with partials/stimulus refs (default). full: template content.")
        }
      )

      guide_row(
        order: 9,
        mcp: "rails_get_view(controller:\"X\")",
        cli_args: "controller=X",
        summary: "Templates with ivars, Turbo wiring, Stimulus refs, partial locals"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, path: nil, detail: "standard", server_context: nil)
        data = cached_context[:view_templates]

        # Fall back to reading from disk if the introspector isn't in the
        # preset, failed, or - in static tier - never ran at all. The disk
        # read is real static analysis either way, so it beats rendering an
        # empty listing from a section that was simply never inspected.
        if data.nil? || data[:error] || data[:unavailable]
          return read_from_disk(controller: controller, path: path, detail: detail)
        end

        templates = data[:templates] || {}
        partials = data[:partials] || {}

        # Specific path - return file content
        if path
          return read_view_file(path)
        end

        # Filter by controller (also checks partials for directories like "shared/")
        # Special case: "layouts" reads from app/views/layouts/ (excluded from normal listing)
        if controller&.downcase == "layouts"
          return list_layouts(detail)
        end

        if controller
          # Normalize: accept "PostsController", "posts", "posts_controller", "Admin::PostsController"
          ctrl_lower = RailsAiContext::Payload.controller_route_key(cached_context, controller)
          ctrl_lower_alt = controller.downcase.delete_suffix("controller")
          filtered_templates = templates.select { |k, _|
            k_down = k.downcase
            k_down.start_with?(ctrl_lower + "/") || k_down.start_with?(ctrl_lower_alt + "/")
          }
          filtered_partials = partials.select { |k, _|
            k_down = k.downcase
            k_down.start_with?(ctrl_lower + "/") || k_down.start_with?(ctrl_lower_alt + "/")
          }

          if filtered_templates.empty? && filtered_partials.empty?
            # Gate on the UNFILTERED maps, not the filter miss: an API-only
            # app can still have real views (mailer templates, most
            # commonly), so a controller filter that simply doesn't match
            # anything must not be reported as "views don't exist here".
            if templates.empty? && partials.empty?
              note = api_only_note("app/views")
              return text_response(note) if note
            end

            all_dirs = (templates.keys + partials.keys).map { |k| k.split("/").first }.uniq.sort
            suggestion = find_closest_match(ctrl_lower, all_dirs)
            hint = suggestion ? " Did you mean '#{suggestion}'?" : ""
            dirs_note = all_dirs.any? ? " Directories with views: #{all_dirs.join(', ')}" : " No view directories found (API-only apps typically have none)."
            return empty_response("No views for '#{controller}'.#{hint}#{dirs_note}")
          end

          templates = filtered_templates
          partials = filtered_partials
        end

        # Unfiltered zero-template case: no controller given and the app
        # genuinely has no views anywhere (as opposed to a filter simply not
        # matching anything, handled above).
        if controller.nil? && templates.empty? && partials.empty?
          note = api_only_note("app/views")
          return text_response(note) if note
        end

        layouts = controller ? [] : layout_files

        case detail
        when "summary"
          all_dirs = (templates.keys + partials.keys).map { |k| k.split("/").first }.uniq.sort
          lines = views_header_lines(templates, partials, layouts)
          all_dirs.each do |ctrl|
            ctrl_templates = templates.select { |k, _| k.start_with?("#{ctrl}/") }
            ctrl_partials = partials.select { |k, _| k.start_with?("#{ctrl}/") }
            file_count = ctrl_templates.size + ctrl_partials.size
            # Skip redundant section header when filtered to a single controller
            lines << "## #{ctrl}/ (#{count_phrase(file_count, "file")})" unless controller && all_dirs.size == 1
            ctrl_templates.sort.each do |name, meta|
              parts = meta[:partials]&.any? ? " renders: #{meta[:partials].join(', ')}" : ""
              stim = meta[:stimulus]&.any? ? " stimulus: #{meta[:stimulus].join(', ')}" : ""
              comps = meta[:components]&.any? ? " components: #{meta[:components].join(', ')}" : ""
              phlex_tag = meta[:phlex] ? " [phlex]" : ""
              lines << "- #{name} (#{count_phrase(meta[:lines], "line")}#{phlex_tag})#{parts}#{comps}#{stim}"
            end
            ctrl_partials.sort.each do |name, meta|
              lines << "- #{name} (#{count_phrase(meta[:lines], "line")})"
            end
            lines << ""
          end
          text_response(lines.join("\n"))

        when "standard"
          all_dirs = (templates.keys + partials.keys).map { |k| k.split("/").first }.uniq.sort
          lines = views_header_lines(templates, partials, layouts)

          # Form builders and component usage from views introspector
          form_builders = data[:form_builders_detected]
          component_usage = data[:component_usage]
          if form_builders&.any?
            lines << "**Form builders:** #{form_builders.join(', ')}" << ""
          end
          if component_usage&.any?
            lines << "**ViewComponents:** #{component_usage.first(10).join(', ')}" << ""
          end

          all_dirs.each do |ctrl|
            ctrl_templates = templates.select { |k, _| k.start_with?("#{ctrl}/") }
            ctrl_partials = partials.select { |k, _| k.start_with?("#{ctrl}/") }
            next if ctrl_templates.empty? && ctrl_partials.empty?

            lines << "## #{ctrl}/" unless controller && all_dirs.size == 1
            ctrl_templates.sort.each do |name, meta|
              detail_parts = []
              extra = extract_view_metadata(name)

              if meta[:phlex]
                # Phlex views: show components, helpers, stimulus, ivars
                # Prefer introspector-level data, fall back to extract_view_metadata
                components = meta[:components]&.any? ? meta[:components] : extra[:components]
                helpers = meta[:helpers]&.any? ? meta[:helpers] : extra[:helpers]
                detail_parts << "ivars: #{extra[:ivars].join(', ')}" if extra[:ivars]&.any?
                detail_parts << "components: #{components.join(', ')}" if components&.any?
                detail_parts << "helpers: #{helpers.join(', ')}" if helpers&.any?
                detail_parts << "stimulus: #{meta[:stimulus].join(', ')}" if meta[:stimulus]&.any?
                detail_parts << "turbo: #{extra[:turbo].join(', ')}" if extra[:turbo]&.any?
              else
                # ERB/Haml/Slim views: existing behavior
                detail_parts << "renders: #{meta[:partials].join(', ')}" if meta[:partials]&.any?
                detail_parts << "stimulus: #{meta[:stimulus].join(', ')}" if meta[:stimulus]&.any?
                detail_parts << "ivars: #{extra[:ivars].join(', ')}" if extra[:ivars]&.any?
                detail_parts << "turbo: #{extra[:turbo].join(', ')}" if extra[:turbo]&.any?
              end

              phlex_tag = meta[:phlex] ? " [phlex]" : ""
              details = detail_parts.any? ? " - #{detail_parts.join(' | ')}" : ""
              lines << "- **#{name}** (#{count_phrase(meta[:lines], "line")}#{phlex_tag})#{details}"
            end
            ctrl_partials.sort.each do |name, meta|
              fields = meta[:fields]&.any? ? " fields: #{meta[:fields].join(', ')}" : ""
              helpers = meta[:helpers]&.any? ? " helpers: #{meta[:helpers].join(', ')}" : ""
              locals = extract_partial_locals(name, templates)
              locals_str = locals&.any? ? " **locals:** #{locals.join(', ')}" : ""
              lines << "- #{name} (#{count_phrase(meta[:lines], "line")})#{fields}#{helpers}#{locals_str}"
            end
            lines << ""
          end

          # Hydrate: inject schema hints for models inferred from view instance variables
          if RailsAiContext.configuration.hydration_enabled && controller
            all_ivars = []
            templates.each do |path, _meta|
              content = read_view_content(path)
              content.scan(/@(\w+)/).flatten.each { |v| all_ivars << v }
            end
            all_ivars.uniq!
            hydration = Hydrators::ViewHydrator.call(all_ivars, context: cached_context)
            hydration_text = Hydrators::HydrationFormatter.format(hydration)
            lines << hydration_text << "" unless hydration_text.empty?
          end

          text_response(lines.join("\n"))

        when "full"
          if controller
            lines = [ "# Views: #{controller}/", "" ]
            # Combine all content first for cross-template Tailwind compression
            all_content = []
            templates.sort.each do |name, _meta|
              all_content << [ name, strip_svg(read_view_content(name)) ]
            end
            partials.sort.each do |name, _meta|
              all_content << [ name, strip_svg(read_view_content(name)) ]
            end
            # Compress repeated Tailwind classes across all templates
            combined = all_content.map { |name, c| "## #{name}\n```erb\n#{c}\n```\n" }.join("\n")
            combined = compress_tailwind(combined)
            lines << combined
            text_response(lines.join("\n"))
          else
            # List available controllers when no controller specified
            all_dirs = (templates.keys + partials.keys).map { |k| k.split("/").first }.uniq.sort
            lines = [ "# Views - Full Detail", "", "_Specify a controller to see template content:_", "" ]
            all_dirs.each do |ctrl|
              count = templates.count { |k, _| k.start_with?("#{ctrl}/") } +
                      partials.count { |k, _| k.start_with?("#{ctrl}/") }
              lines << "- `controller:\"#{ctrl}\"` (#{count_phrase(count, "file")})"
            end
            lines << "" << "_Or use `path:\"controller/action.html.erb\"` for a specific file._"
            text_response(lines.join("\n"))
          end
        end
      end

      # Layouts sit outside the template and partial maps, so a heading naming
      # only those two numbers never added up to the files under app/views.
      private_class_method def self.views_header_lines(templates, partials, layouts)
        parts = [ count_phrase(templates.size, "template"), count_phrase(partials.size, "partial") ]
        parts << count_phrase(layouts.size, "layout") if layouts.any?

        lines = [ "# Views (#{parts.join(', ')})", "" ]
        lines << "_Layouts are listed by `controller:\"layouts\"`._" << "" if layouts.any?
        lines
      end

      # The template and partial maps exclude app/views/layouts, so the
      # directory is the only statement of what is in it.
      private_class_method def self.layout_files
        layouts_dir = rails_app.root.join("app", "views", "layouts")
        return [] unless Dir.exist?(layouts_dir)

        Dir.glob(File.join(layouts_dir, "*")).reject { |f| File.directory?(f) }.sort
      end

      private_class_method def self.list_layouts(detail)
        layouts_dir = rails_app.root.join("app", "views", "layouts")
        return text_response("No app/views/layouts/ directory found.") unless Dir.exist?(layouts_dir)

        files = layout_files
        return text_response("No layout files found.") if files.empty?

        views_dir = rails_app.root.join("app", "views")
        lines = [ "# Layouts (#{count_phrase(files.size, "file")})", "" ]
        files.each do |path|
          relative = "layouts/#{File.basename(path)}"
          located = RailsAiContext::SafePath.locate(relative, under: views_dir, root: rails_app.root)
          next unless located.ok?

          real = located.realpath
          if RailsAiContext::DetailLevel.full?(detail)
            content = RailsAiContext::SafeFile.read(real) || "(error reading)"
            lines << "## #{relative}" << "```erb" << strip_svg(content) << "```" << ""
          else
            content = RailsAiContext::SafeFile.read(real) || ""
            lines << "- #{relative} (#{count_phrase(content.lines.size, "line")})"
          end
        end
        text_response(lines.join("\n"))
      end

      private_class_method def self.read_view_file(path)
        content, result = RailsAiContext::ViewFile.read(rails_app.root.to_s, path)
        case result.refusal
        when :traversal, :outside then return error_response("Path not allowed: #{path}")
        when :sensitive then return error_response("Access denied: #{path} is a sensitive file (secrets/keys/credentials).")
        when :too_large then return text_response("File too large: #{path}")
        when :missing
          dir = File.dirname(path.to_s.delete_prefix("app/views/"))
          views_dir = rails_app.root.join("app", "views")
          siblings = Dir.glob(File.join(views_dir, dir, "*")).map { |f| "#{dir}/#{File.basename(f)}" }.sort.first(10)
          hint = siblings.any? ? " Files in #{dir}/: #{siblings.join(', ')}" : ""
          return empty_response("View not found: #{path}.#{hint}")
        end
        return text_response("Could not read file: #{path}") unless content

        # A file the caller named by path is shown either way; only a
        # template is fenced as erb, because fencing a JPEG's bytes as ERB
        # said it was one.
        unless RailsAiContext::ViewFile.template?(result.relative)
          return text_response("# #{result.relative}\n\n_No template handler renders this file._\n\n```\n#{content}\n```")
        end

        content = compress_tailwind(strip_svg(content))
        text_response("# #{result.relative}\n\n```erb\n#{content}\n```")
      end

      # Strip inline SVG blocks - they're visual noise that buries the signal AI needs.
      # Replaces <svg ...>...</svg> with a compact placeholder.
      private_class_method def self.strip_svg(content)
        content.gsub(/<svg\b[^>]*>.*?<\/svg>/m, "<!-- svg icon -->")
      end

      # Compress repeated long Tailwind class strings so the meaningful markup stays readable.
      # Replaces duplicate class="..." with a CSS variable reference after first occurrence.
      private_class_method def self.compress_tailwind(content)
        class_counts = Hash.new(0)
        # Count class strings longer than 60 chars
        content.scan(/class="([^"]{60,})"/).each { |m| class_counts[m[0]] += 1 }

        # Only compress classes that appear 3+ times
        repeated = class_counts.select { |_, count| count >= 3 }
        return content if repeated.empty?

        result = content.dup
        repeated.each_with_index do |(cls, _count), idx|
          label = "/* .cls-#{idx + 1} */"
          first = true
          result.gsub!("class=\"#{cls}\"") do
            if first
              first = false
              "class=\"#{cls}\" #{label}"
            else
              "class=\"...\" #{label}"
            end
          end
        end
        result
      end

      private_class_method def self.read_view_content(relative_path)
        return "(file not found)" if relative_path.nil? || relative_path.to_s.empty?

        content, result = RailsAiContext::ViewFile.read(rails_app.root.to_s, relative_path)
        case result.refusal
        when :sensitive then "(access denied)"
        when :traversal, :outside then "(path not allowed)"
        when :too_large then "(file too large)"
        when :missing then "(file not found)"
        else content || "(error reading file)"
        end
      end

      # Extract instance variables and Turbo wiring from a view template
      private_class_method def self.extract_view_metadata(relative_path)
        content = read_view_content(relative_path)
        return { ivars: [], turbo: [], components: [], helpers: [] } if content.nil? || content.include?("(file not found)")

        ivars = Introspectors::ViewTemplateIntrospector.ivars_in(content, path: relative_path)

        # Turbo Frame IDs and turbo_stream_from channels
        turbo = []
        content.scan(/turbo_frame_tag\s+["']([^"']+)["']/).each { |m| turbo << "frame:#{m[0]}" }
        content.scan(/turbo_frame_tag\s+:(\w+)/).each { |m| turbo << "frame:#{m[0]}" }
        content.scan(/turbo_stream_from\s+["']([^"']+)["']/).each { |m| turbo << "stream:#{m[0]}" }
        content.scan(/turbo_stream_from\s+([^,\s]+)/).each do |m|
          val = m[0].strip
          turbo << "stream:#{val}" unless val.start_with?('"') || val.start_with?("'") || turbo.any? { |t| t.include?(val) }
        end

        result = { ivars: ivars, turbo: turbo.uniq }

        # For Phlex views (.rb), extract component renders and helper calls
        if relative_path.end_with?(".rb") && phlex_view_content?(content)
          result[:components] = extract_phlex_components(content)
          result[:helpers] = extract_phlex_helpers(content)
        end

        result
      rescue => e
        RailsAiContext.debug_fail(e, { ivars: [], turbo: [], components: [], helpers: [] }, label: "extract_view_metadata")
      end

      # Detect if content is a Phlex view class
      private_class_method def self.phlex_view_content?(content)
        content.match?(/class\s+\S+\s*<\s*\S+/) && content.match?(/def\s+view_template\b/)
      end

      # Extract component render calls from Phlex Ruby DSL
      private_class_method def self.extract_phlex_components(content)
        components = Set.new
        content.scan(/render[\s(]+([A-Z]\w+(?:::\w+)*)\.new/).each do |match|
          components << match[0]
        end
        components.to_a.sort
      end

      # Extract helper method calls from Phlex views
      PHLEX_HELPERS = %w[
        link_to image_tag content_for button_to form_with form_for
        content_tag tag number_to_currency number_to_human
        time_ago_in_words distance_of_time_in_words
        truncate pluralize raw sanitize dom_id
      ].freeze

      private_class_method def self.extract_phlex_helpers(content)
        helpers = []
        PHLEX_HELPERS.each do |method|
          helpers << method if content.match?(/\b#{method}\b/)
        end
        helpers
      end

      # Scan templates that render a partial to extract locals keys
      private_class_method def self.extract_partial_locals(partial_name, templates)
        # Get the partial's short name for matching render calls
        base = File.basename(partial_name).sub(/\A_/, "").sub(/\..*/, "")
        locals = Set.new

        templates.each_value do |meta|
          next unless meta[:partials]&.any? { |p| p.include?(base) }
          content = read_view_content(meta[:path] || next)
          # Match: render "partial", key: val OR render partial: "partial", locals: { key: val }
          content.scan(/render\s+(?:partial:\s*)?["'][^"']*#{Regexp.escape(base)}["'][^%\n]*?(?:,|\blocals:\s*\{)\s*([^}%]+)/).each do |match|
            match[0].scan(/(\w+):/) { |k| locals << k[0] }
          end
        end

        locals.to_a.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_partial_locals")
      end

      private_class_method def self.read_from_disk(controller:, path:, detail:)
        views_dir = rails_app.root.join("app", "views")
        unless Dir.exist?(views_dir)
          note = api_only_note("app/views")
          return text_response(note) if note

          return text_response("No app/views directory found.")
        end

        if path
          return read_view_file(path)
        end

        # This listing prints the same `controller:"layouts"` pointer the
        # payload listing does, so it has to answer it the same way.
        return list_layouts(detail) if controller&.downcase == "layouts"

        # List views from disk
        files = Dir.glob(File.join(views_dir, "**", "*"))
          .reject { |f| File.directory?(f) || f.include?("/layouts/") }
          .select { |f| RailsAiContext::ViewFile.template?(f) }
          .map { |f| f.sub("#{views_dir}/", "") }
          .sort

        if controller
          ctrl_lower = RailsAiContext::Payload.controller_route_key(cached_context, controller)
          ctrl_lower_alt = controller.downcase.delete_suffix("controller")
          files = files.select { |t|
            t_down = t.downcase
            t_down.start_with?(ctrl_lower + "/") || t_down.start_with?(ctrl_lower_alt + "/")
          }
        end

        templates, partials = files.partition { |f| !File.basename(f).start_with?("_") }
        lines = views_header_lines(templates, partials, controller ? [] : layout_files)
        files.each { |f| lines << "- #{f}" }
        text_response(lines.join("\n"))
      end
    end
  end
end
