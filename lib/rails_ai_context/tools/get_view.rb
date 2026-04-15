# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetView < BaseTool
      tool_name "rails_get_view"
      description "Get view templates, partials, and their Stimulus/partial references. " \
        "Use when: editing ERB views, checking which partials a page renders, or finding Stimulus controller usage. " \
        "Filter with controller:\"cooks\" for all views, or path:\"cooks/index.html.erb\" for one file's content."

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Filter views by controller name (e.g. 'cooks', 'brand_profiles'). Lists all templates for that controller."
          },
          path: {
            type: "string",
            description: "Specific view path relative to app/views (e.g. 'cooks/index.html.erb'). Returns full content."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: file list with line counts. standard: file list with partials/stimulus refs (default). full: template content."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, path: nil, detail: "standard", server_context: nil)
        data = cached_context[:view_templates]

        # Fall back to reading from disk if introspector not in preset
        if data.nil? || data[:error]
          return read_from_disk(controller: controller, path: path, detail: detail)
        end

        templates = data[:templates] || {}
        partials = data[:partials] || {}

        # Specific path — return file content
        if path
          return read_view_file(path)
        end

        # Filter by controller (also checks partials for directories like "shared/")
        # Special case: "layouts" reads from app/views/layouts/ (excluded from normal listing)
        if controller&.downcase == "layouts"
          return list_layouts(detail)
        end

        if controller
          # Normalize: accept "CooksController", "cooks", "cooks_controller", "Bonus::CooksController"
          ctrl_lower = controller.underscore.delete_suffix("_controller")
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
            all_dirs = (templates.keys + partials.keys).map { |k| k.split("/").first }.uniq.sort
            suggestion = find_closest_match(ctrl_lower, all_dirs)
            hint = suggestion ? " Did you mean '#{suggestion}'?" : ""
            return text_response("No views for '#{controller}'.#{hint} Directories with views: #{all_dirs.join(', ')}")
          end

          templates = filtered_templates
          partials = filtered_partials
        end

        case detail
        when "summary"
          all_dirs = (templates.keys + partials.keys).map { |k| k.split("/").first }.uniq.sort
          lines = [ "# Views (#{templates.size} templates, #{partials.size} partials)", "" ]
          all_dirs.each do |ctrl|
            ctrl_templates = templates.select { |k, _| k.start_with?("#{ctrl}/") }
            ctrl_partials = partials.select { |k, _| k.start_with?("#{ctrl}/") }
            file_count = ctrl_templates.size + ctrl_partials.size
            # Skip redundant section header when filtered to a single controller
            lines << "## #{ctrl}/ (#{file_count} files)" unless controller && all_dirs.size == 1
            ctrl_templates.sort.each do |name, meta|
              parts = meta[:partials]&.any? ? " renders: #{meta[:partials].join(', ')}" : ""
              stim = meta[:stimulus]&.any? ? " stimulus: #{meta[:stimulus].join(', ')}" : ""
              comps = meta[:components]&.any? ? " components: #{meta[:components].join(', ')}" : ""
              phlex_tag = meta[:phlex] ? " [phlex]" : ""
              lines << "- #{name} (#{meta[:lines]} lines#{phlex_tag})#{parts}#{comps}#{stim}"
            end
            ctrl_partials.sort.each do |name, meta|
              lines << "- #{name} (#{meta[:lines]} lines)"
            end
            lines << ""
          end
          text_response(lines.join("\n"))

        when "standard"
          all_dirs = (templates.keys + partials.keys).map { |k| k.split("/").first }.uniq.sort
          lines = [ "# Views (#{templates.size} templates, #{partials.size} partials)", "" ]

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
              details = detail_parts.any? ? " — #{detail_parts.join(' | ')}" : ""
              lines << "- **#{name}** (#{meta[:lines]} lines#{phlex_tag})#{details}"
            end
            ctrl_partials.sort.each do |name, meta|
              fields = meta[:fields]&.any? ? " fields: #{meta[:fields].join(', ')}" : ""
              helpers = meta[:helpers]&.any? ? " helpers: #{meta[:helpers].join(', ')}" : ""
              locals = extract_partial_locals(name, templates)
              locals_str = locals&.any? ? " **locals:** #{locals.join(', ')}" : ""
              lines << "- #{name} (#{meta[:lines]} lines)#{fields}#{helpers}#{locals_str}"
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
            lines = [ "# Views — Full Detail", "", "_Specify a controller to see template content:_", "" ]
            all_dirs.each do |ctrl|
              count = templates.count { |k, _| k.start_with?("#{ctrl}/") } +
                      partials.count { |k, _| k.start_with?("#{ctrl}/") }
              lines << "- `controller:\"#{ctrl}\"` (#{count} files)"
            end
            lines << "" << "_Or use `path:\"controller/action.html.erb\"` for a specific file._"
            text_response(lines.join("\n"))
          end
        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end
      end

      private_class_method def self.list_layouts(detail)
        layouts_dir = Rails.root.join("app", "views", "layouts")
        return text_response("No app/views/layouts/ directory found.") unless Dir.exist?(layouts_dir)

        files = Dir.glob(File.join(layouts_dir, "*")).reject { |f| File.directory?(f) }.sort
        return text_response("No layout files found.") if files.empty?

        lines = [ "# Layouts (#{files.size} files)", "" ]
        files.each do |path|
          relative = "layouts/#{File.basename(path)}"
          if detail == "full"
            content = RailsAiContext::SafeFile.read(path) || "(error reading)"
            lines << "## #{relative}" << "```erb" << strip_svg(content) << "```" << ""
          else
            line_count = (RailsAiContext::SafeFile.read(path) || "").lines.size
            lines << "- #{relative} (#{line_count} lines)"
          end
        end
        text_response(lines.join("\n"))
      end

      private_class_method def self.read_view_file(path)
        # Reject path traversal attempts before any filesystem operation
        if path.include?("..") || path.start_with?("/")
          return text_response("Path not allowed: #{path}")
        end

        # Block sensitive files on the caller-supplied string before any
        # filesystem stat — closes the existence-oracle side channel.
        if sensitive_file?(path)
          return text_response("Access denied: #{path} is a sensitive file (secrets/keys/credentials).")
        end

        views_dir = Rails.root.join("app", "views")
        full_path = views_dir.join(path)

        unless File.exist?(full_path)
          dir = File.dirname(path)
          siblings = Dir.glob(File.join(views_dir, dir, "*")).map { |f| "#{dir}/#{File.basename(f)}" }.sort.first(10)
          hint = siblings.any? ? " Files in #{dir}/: #{siblings.join(', ')}" : ""
          return text_response("View not found: #{path}.#{hint}")
        end
        # Containment check with separator + post-realpath sensitive recheck.
        # Mirrors the v5.8.1 fix in vfs.rb / get_edit_context.rb. Without
        # `File::SEPARATOR`, `start_with?` matches sibling directories like
        # `app/views_backup/secret` against `app/views`. Without the
        # post-realpath sensitive recheck, a symlink at
        # `app/views/leak.key → ../../config/master.key` would slip through
        # and read the secret.
        real = nil
        begin
          real = File.realpath(full_path).to_s
          real_base = File.realpath(views_dir).to_s
          unless real == real_base || real.start_with?(real_base + File::SEPARATOR)
            return text_response("Path not allowed: #{path}")
          end
          relative_real = real.sub("#{real_base}/", "")
          if sensitive_file?(relative_real)
            return text_response("Access denied: #{path} resolves to a sensitive file (secrets/keys/credentials).")
          end
        rescue Errno::ENOENT
          return text_response("View not found: #{path}")
        end
        if File.size(real) > max_file_size
          return text_response("File too large: #{path} (#{File.size(real)} bytes, max: #{max_file_size})")
        end

        content = RailsAiContext::SafeFile.read(real)
        return text_response("Could not read file: #{path}") unless content
        content = compress_tailwind(strip_svg(content))
        text_response("# #{path}\n\n```erb\n#{content}\n```")
      end

      # Strip inline SVG blocks — they're visual noise that buries the signal AI needs.
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
        full_path = Rails.root.join("app", "views", relative_path)
        File.exist?(full_path) ? (RailsAiContext::SafeFile.read(full_path) || "(error reading file)") : "(file not found)"
      rescue => e
        $stderr.puts "[rails-ai-context] read_view_content failed: #{e.message}" if ENV["DEBUG"]
        "(error reading file)"
      end

      # Extract instance variables and Turbo wiring from a view template
      private_class_method def self.extract_view_metadata(relative_path)
        content = read_view_content(relative_path)
        return { ivars: [], turbo: [], components: [], helpers: [] } if content.nil? || content.include?("(file not found)")

        # Instance variables used in template
        ivars = content.scan(/@(\w+)/).flatten.uniq.reject { |v| %w[output_buffer virtual_path _request].include?(v) }.sort

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
        $stderr.puts "[rails-ai-context] extract_view_metadata failed: #{e.message}" if ENV["DEBUG"]
        { ivars: [], turbo: [], components: [], helpers: [] }
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
        $stderr.puts "[rails-ai-context] extract_partial_locals failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      private_class_method def self.read_from_disk(controller:, path:, detail:)
        views_dir = Rails.root.join("app", "views")
        return text_response("No app/views directory found.") unless Dir.exist?(views_dir)

        if path
          return read_view_file(path)
        end

        # List views from disk
        templates = Dir.glob(File.join(views_dir, "**", "*"))
          .reject { |f| File.directory?(f) || File.basename(f).start_with?("_") || f.include?("/layouts/") }
          .map { |f| f.sub("#{views_dir}/", "") }
          .sort

        if controller
          ctrl_lower = controller.underscore.delete_suffix("_controller")
          ctrl_lower_alt = controller.downcase.delete_suffix("controller")
          templates = templates.select { |t|
            t_down = t.downcase
            t_down.start_with?(ctrl_lower + "/") || t_down.start_with?(ctrl_lower_alt + "/")
          }
        end

        lines = [ "# Views (#{templates.size} templates)", "" ]
        templates.each { |t| lines << "- #{t}" }
        text_response(lines.join("\n"))
      end
    end
  end
end
